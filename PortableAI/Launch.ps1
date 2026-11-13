param(
    [ValidateSet('Auto','GPU','CPU')][string]$Engine = 'Auto',
    [switch]$SelfTest,
    [switch]$StopOnly,
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$taskRoot = $PSScriptRoot
$statePath = Join-Path $taskRoot 'logs\running.json'
$serverProcess = $null
$browserProcess = $null
$browserTrackingEnabled = $false
$job = $null
$chatStore = $null
$exitCode = 0
$port = 18888
$chatPort = 18889
$browserDebugPort = 18890
$imagePort = 18891
$baseUrl = 'http://127.0.0.1:' + $port
$modelAlias = 'PortableAI-Gemma3-4B-Vision'
$chatRoot = Join-Path ([IO.Path]::GetPathRoot($taskRoot)) 'AI聊天记录'
$imageRoot = Join-Path ([IO.Path]::GetPathRoot($taskRoot)) 'AI生成图片'
$configPath = Join-Path $taskRoot 'web\storage-config.js'
$imageExe = Join-Path $taskRoot 'runtime-image\sd-server.exe'
$imageModelFast = Join-Path $taskRoot 'models\sd-turbo-q4_0.gguf'
$imageModelQuality = Join-Path $taskRoot 'models\stable-diffusion-xl-1.0-turbo-Q4_0.gguf'

# Some terminal hosts supply both PATH and Path; Windows PowerShell 5.1
# cannot create a child process with that duplicate. Normalize this process only.
$pathKeys = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -ieq 'Path' })
if ($pathKeys.Count -gt 1) {
    $inheritedPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
    foreach ($key in $pathKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    [Environment]::SetEnvironmentVariable('Path', $inheritedPath, 'Process')
}

# All application-owned writable locations stay beside this script.
$originalLocalAppData = $env:LOCALAPPDATA
foreach ($sub in @('temp','cache','cache\gpu','logs','browser-data','profile-local','profile-roaming')) {
    [IO.Directory]::CreateDirectory((Join-Path $taskRoot $sub)) | Out-Null
}
$env:TEMP = Join-Path $taskRoot 'temp'
$env:TMP = $env:TEMP
$env:XDG_CACHE_HOME = Join-Path $taskRoot 'cache'
$env:LLAMA_CACHE = Join-Path $taskRoot 'cache'
$env:CUDA_CACHE_PATH = Join-Path $taskRoot 'cache\gpu'
$env:CUDA_CACHE_DISABLE = '1'
$env:__GL_SHADER_DISK_CACHE = '0'
$env:__GL_SHADER_DISK_CACHE_PATH = Join-Path $taskRoot 'cache\gpu'
$env:LOCALAPPDATA = Join-Path $taskRoot 'profile-local'
$env:APPDATA = Join-Path $taskRoot 'profile-roaming'
$env:LLAMA_ARG_OFFLINE = '1'
$env:LLAMA_ARG_REASONING = 'off'

function Restore-SplitRuntimeFiles {
    $manifestPath = Join-Path $taskRoot 'runtime-parts.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    $items = @(Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    foreach ($item in $items) {
        $target = Join-Path $taskRoot ([string]$item.path)
        if (Test-Path -LiteralPath $target -PathType Leaf) { continue }
        $targetDirectory = [IO.Path]::GetDirectoryName($target)
        [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
        $temporary = $target + '.assembling'
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
        Write-Host ('首次运行：正在还原 ' + [IO.Path]::GetFileName($target) + ' ...') -ForegroundColor Cyan
        $output = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            foreach ($relativePart in @($item.parts)) {
                $part = Join-Path $taskRoot ([string]$relativePart)
                if (-not (Test-Path -LiteralPath $part -PathType Leaf)) { throw ('缺少运行库分片：' + $part) }
                $input = [IO.File]::OpenRead($part)
                try { $input.CopyTo($output) } finally { $input.Dispose() }
            }
        } finally { $output.Dispose() }
        $actualHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne ([string]$item.sha256).ToLowerInvariant()) {
            [IO.File]::Delete($temporary)
            throw ('运行库分片校验失败：' + $target)
        }
        [IO.File]::Move($temporary, $target)
    }
}

Restore-SplitRuntimeFiles

# Choose a practical profile automatically. Small/medium GPUs use the lighter
# one-step image model so Gemma and image generation can share limited VRAM.
$gpuName = ''
$gpuVramMB = 0
try {
    $nvidia = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($nvidia) {
        $gpuLine = & $nvidia.Source --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if ($gpuLine -match '^(.+),\s*(\d+)\s*$') { $gpuName = $matches[1].Trim(); $gpuVramMB = [int]$matches[2] }
    }
} catch { }
if ($gpuVramMB -eq 0) {
    try {
        $controller = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote Display|Intel.*(UHD|Iris|Graphics)' } | Sort-Object AdapterRAM -Descending | Select-Object -First 1
        if ($controller) { $gpuName = [string]$controller.Name; $gpuVramMB = [int]([Math]::Round(([double]$controller.AdapterRAM / 1MB))) }
    } catch { }
}
if ($Engine -eq 'Auto') { $Engine = if ($gpuVramMB -ge 3072) { 'GPU' } else { 'CPU' } }
$qualityImageInstalled = Test-Path -LiteralPath $imageModelQuality -PathType Leaf
if ($Engine -eq 'GPU' -and $gpuVramMB -ge 10240 -and $qualityImageInstalled) {
    $imageModel = $imageModelQuality; $imageWidth = 512; $imageSteps = 4; $imageBackend = 'te=cpu,vae=vulkan0,diffusion=vulkan0'; $imageVram = 'vulkan0=5.5'; $imageName = 'SDXL-Turbo 精细模式'; $hardwareProfile = '高性能独显'
} elseif ($Engine -eq 'GPU') {
    $imageModel = $imageModelFast; $imageWidth = 512; $imageSteps = 4; $imageBackend = 'te=cpu,vae=vulkan0,diffusion=vulkan0'; $imageVram = 'vulkan0=2.4'; $imageName = 'SD-Turbo 极速模式'; $hardwareProfile = $(if($gpuVramMB -ge 10240){'高性能独显（极速模型）'}else{'独显均衡'})
} else {
    $imageModel = $imageModelFast; $imageWidth = 384; $imageSteps = 4; $imageBackend = 'cpu'; $imageVram = ''; $imageName = 'SD-Turbo 轻薄本模式'; $hardwareProfile = '轻薄本 CPU'
}

function Quote-Arg([string]$value) {
    if ($value -notmatch '[\s"]' -and $value.Length -gt 0) { return $value }
    return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Request-Local([string]$path, [string]$body = '', [int]$timeoutMs = 3000) {
    $request = [Net.HttpWebRequest]::Create($baseUrl + $path)
    $request.Proxy = $null
    $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $request.Timeout = $timeoutMs
    $request.ReadWriteTimeout = $timeoutMs
    if ($body) {
        $request.Method = 'POST'
        $request.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    try { $response = $request.GetResponse() }
    catch [Net.WebException] { if ($_.Exception.Response) { $_.Exception.Response.Dispose() }; throw }
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}

function Request-Store([string]$path, [string]$body = '', [int]$timeoutMs = 5000) {
    $request = [Net.HttpWebRequest]::Create(('http://127.0.0.1:' + $chatPort + $path))
    $request.Proxy = $null
    $request.Timeout = $timeoutMs
    $request.ReadWriteTimeout = $timeoutMs
    $request.Headers['Origin'] = $baseUrl
    $request.Headers['Authorization'] = 'Bearer ' + $chatToken
    if ($body) {
        $request.Method = 'POST'
        $request.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}

function Get-OurServer {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $process = Get-Process -Id ([int]$state.pid) -ErrorAction Stop
        $expectedPaths = @((Join-Path $taskRoot 'runtime-gpu\llama-server.exe'), (Join-Path $taskRoot 'runtime-cpu\llama-server.exe'))
        if ($process.Path -in $expectedPaths -and $process.StartTime.ToUniversalTime().Ticks.ToString() -eq $state.startedUtcTicks) { return $process }
    } catch { }
    return $null
}

function Get-ChatWindows {
    $profile = Join-Path $taskRoot 'browser-data'
    try { return @(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('chrome.exe','msedge.exe') -and $_.CommandLine -like ('*--user-data-dir=' + $profile + '*') -and $_.CommandLine -notmatch '--type=' }) } catch { return @() }
}

function Get-ChatDebugPages {
    try {
        $request = [Net.HttpWebRequest]::Create('http://127.0.0.1:' + $browserDebugPort + '/json/list')
        $request.Proxy = $null; $request.Timeout = 800; $request.ReadWriteTimeout = 800
        $response = $request.GetResponse()
        try {
            $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
            try { return @($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
        } finally { $response.Dispose() }
    } catch { return @() }
}

function Get-ChatBrowserProcess {
    try {
        $connection = Get-NetTCPConnection -State Listen -LocalPort $browserDebugPort -ErrorAction Stop | Select-Object -First 1
        if ($connection) { return Get-Process -Id ([int]$connection.OwningProcess) -ErrorAction SilentlyContinue }
    } catch { }
    return $null
}

function Test-ChatWindowAlive {
    if (@(Get-ChatDebugPages | Where-Object { [string]$_.url -like ($baseUrl + '/*') }).Count) { return $true }
    return @(Get-ChatWindows).Count -gt 0
}

function Stop-ChatWindows {
    foreach ($window in @(Get-ChatWindows)) { Stop-Process -Id ([int]$window.ProcessId) -Force -ErrorAction SilentlyContinue }
    $debugProcess = Get-ChatBrowserProcess
    if ($debugProcess) { Stop-Process -Id $debugProcess.Id -Force -ErrorAction SilentlyContinue }
}

function Open-Chat {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $originalLocalAppData 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    $browser = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $browser) { Write-Host ('没有找到浏览器，请手动打开：' + $baseUrl); return }
    $browserArgs = @(
        '--user-data-dir=' + (Join-Path $taskRoot 'browser-data')
        '--disk-cache-dir=' + (Join-Path $taskRoot 'cache\browser')
        '--no-first-run'
        '--no-default-browser-check'
        '--disable-sync'
        '--disable-background-networking'
        '--disable-component-update'
        '--disable-background-mode'
        '--disable-breakpad'
        '--remote-debugging-address=127.0.0.1'
        '--remote-debugging-port=' + $browserDebugPort
        '--app=' + $baseUrl + '/portable-chat.html'
    )
    Stop-ChatWindows
    try { $started = Start-Process -FilePath $browser -ArgumentList (($browserArgs | ForEach-Object { Quote-Arg $_ }) -join ' ') -WorkingDirectory $taskRoot -PassThru }
    catch { Write-Host ('浏览器窗口无法自动打开，请手动访问 ' + $baseUrl + '。原因：' + $_.Exception.Message); return $null }
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        Start-Sleep -Milliseconds 250
        $debugProcess = Get-ChatBrowserProcess
        if ($debugProcess -and (Test-ChatWindowAlive)) { $script:browserTrackingEnabled = $true; return $debugProcess }
        $window = @(Get-ChatWindows | Select-Object -First 1)
        if ($window.Count) { $script:browserTrackingEnabled = $true; return Get-Process -Id ([int]$window[0].ProcessId) -ErrorAction SilentlyContinue }
    }
    try { $started.Refresh(); if (-not $started.HasExited) { Write-Host '浏览器窗口已打开；窗口跟踪不可用，退出时请按 Q 或使用停止脚本。'; return $started } } catch { }
    Write-Host '浏览器已打开，但无法稳定跟踪窗口；关闭时请双击“停止离线AI.cmd”。'
    return $null
}

try {
    $previous = Get-OurServer
    if ($previous -and -not $StopOnly -and -not $SelfTest) {
        Write-Host '检测到浮光模型已经启动，正在直接连接，不再重复加载…'
        $reuseTimer = [Diagnostics.Stopwatch]::StartNew()
        $reuseReady = $false
        $reuseMessage = -10
        while ($reuseTimer.Elapsed.TotalSeconds -lt 600) {
            $previous.Refresh()
            if ($previous.HasExited) { break }
            try {
                $health = Request-Local '/health' '' 5000 | ConvertFrom-Json
                if ($health.status -eq 'ok') { $reuseReady = $true; break }
            } catch { }
            if ($reuseTimer.Elapsed.TotalSeconds -ge $reuseMessage + 10) {
                $reuseMessage = [int]$reuseTimer.Elapsed.TotalSeconds
                Write-Host ('原模型仍在加载… ' + $reuseMessage + ' 秒，请不要重复点击启动器。')
            }
            Start-Sleep -Milliseconds 600
        }
        if ($reuseReady) {
            Write-Host '模型已就绪，正在直接打开界面。'
            if (-not $NoBrowser) {
                $browserProcess = Open-Chat
                Write-Host '关闭浮光窗口、按 Q 或关闭此窗口都会停止全部离线 AI。'
                $consoleKeysAvailable = -not [Console]::IsInputRedirected
                $browserMissingTicks = 0
                while (-not $previous.HasExited) {
                    if ($browserTrackingEnabled) {
                        if (Test-ChatWindowAlive) { $browserMissingTicks = 0 } else { $browserMissingTicks++; if ($browserMissingTicks -ge 10) { break } }
                    }
                    if ($consoleKeysAvailable) { try { if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { break } } catch { $consoleKeysAvailable = $false } }
                    Start-Sleep -Milliseconds 400; $previous.Refresh()
                }
                if (-not $previous.HasExited) { Stop-Process -Id $previous.Id -Force -ErrorAction SilentlyContinue }
                if ($browserProcess -and -not $browserProcess.HasExited) { Stop-Process -Id $browserProcess.Id -Force -ErrorAction SilentlyContinue }
            }
            exit 0
        }
        Write-Host '原模型没有正常就绪，将自动重新启动。'
    }
    if ($previous) {
        Write-Host '正在关闭上一次运行的离线 AI…'
        Stop-Process -Id $previous.Id -Force
        if (-not $previous.WaitForExit(15000)) { throw '上一次运行的模型未能正常关闭。' }
    }
    Get-Process -Name 'sd-cli','sd-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like (Join-Path $taskRoot 'runtime-image\*') } | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($StopOnly) { Stop-ChatWindows; Write-Host '离线 AI 和浮光窗口都已停止。'; exit 0 }

    # Never mistake another app or an old model for this launch.
    $probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
    try { $probe.Start() } catch { throw ('Port ' + $port + ' 被其他程序占用。请关闭旧的 AI 窗口后重试。') } finally { $probe.Stop() }
    $runtimeName = if ($Engine -eq 'CPU') { 'runtime-cpu' } else { 'runtime-gpu' }
    $runtime = Join-Path $taskRoot $runtimeName
    $server = Join-Path $runtime 'llama-server.exe'
    $modelPath = Join-Path $taskRoot 'models\gemma-3-4b-it-q4_0.gguf'
    $mmprojPath = Join-Path $taskRoot 'models\gemma-3-4b-it-mmproj-f16.gguf'
    foreach ($file in @($server, $modelPath, $mmprojPath, $imageExe, $imageModel)) {
        if (-not (Test-Path -LiteralPath $file)) { throw ('缺少文件：' + $file) }
    }

    # A kernel job closes the server even if the user closes this console.
    # Compiler temporary files follow TEMP/TMP on the USB drive.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class PortableAIJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime, JobTime; public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet; public uint ActiveProcesses;
        public UIntPtr Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits Basic; public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int type, IntPtr info, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr handle;
    public PortableAIJob() {
        handle = CreateJobObject(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) throw new Win32Exception();
        var limits = new ExtendedLimits(); limits.Basic.Flags = 0x2000;
        int size = Marshal.SizeOf(limits); IntPtr ptr = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(limits, ptr, false);
            if (!SetInformationJobObject(handle, 9, ptr, (uint)size)) { int error = Marshal.GetLastWin32Error(); Dispose(); throw new Win32Exception(error); }
        } finally { Marshal.FreeHGlobal(ptr); }
    }
    public void Add(IntPtr process) { if (!AssignProcessToJobObject(handle, process)) throw new Win32Exception(); }
    public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
}
'@
    # The save API only listens on localhost. Its secret and every saved chat stay on this USB drive.
    $storeSource = Join-Path $taskRoot 'ChatStore.cs'
    if (-not (Test-Path -LiteralPath $storeSource)) { throw ('缺少文件：' + $storeSource) }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($storeSource)) -ReferencedAssemblies 'System.Web.Extensions.dll'
    $secretPath = Join-Path $taskRoot 'storage-secret.txt'
    $chatToken = ''
    if (Test-Path -LiteralPath $secretPath) { $chatToken = [IO.File]::ReadAllText($secretPath).Trim() }
    if ($chatToken -notmatch '^[A-F0-9]{64}$') {
        $tokenBytes = New-Object byte[] 32
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $random.GetBytes($tokenBytes) } finally { $random.Dispose() }
        $chatToken = [BitConverter]::ToString($tokenBytes).Replace('-', '')
        [IO.File]::WriteAllText($secretPath, $chatToken, (New-Object Text.UTF8Encoding($false)))
    }
    [IO.Directory]::CreateDirectory($chatRoot) | Out-Null
    [IO.Directory]::CreateDirectory($imageRoot) | Out-Null
    $chatStore = New-Object PortableChatStore -ArgumentList @($chatRoot, $chatToken, $chatPort, $baseUrl, $imageExe, $imageModel, $imageRoot, $imagePort, $imageBackend, $imageVram, $imageWidth, $imageSteps, $imageName)
    $chatStore.Start()
    $context = if ($Engine -eq 'CPU') { '4096' } else { '8192' }
    $config = @{storageUrl=('http://127.0.0.1:' + $chatPort);token=$chatToken;storageRoot=$chatRoot;imageRoot=$imageRoot;model=$modelAlias;contextSize=[int]$context;vision=$true;imageGeneration=$true;engine=$Engine;hardwareProfile=$hardwareProfile;gpuName=$gpuName;gpuVramMB=$gpuVramMB;imageModel=$imageName;imageSize=$imageWidth;imageSteps=$imageSteps} | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($configPath, ('window.PORTABLE_AI_CONFIG = ' + $config + ';'), (New-Object Text.UTF8Encoding($false)))

    $job = New-Object PortableAIJob
    $threads = [Math]::Min(8, [Environment]::ProcessorCount)
    $serverArgs = @('--model', $modelPath, '--mmproj', $mmprojPath, '--alias', $modelAlias, '--host', '127.0.0.1', '--port', "$port",
        '--ctx-size', $context, '--parallel', '1', '--batch-size', '512', '--ubatch-size', '512',
        '--threads', "$threads", '--poll', '0', '--offline', '--no-webui-mcp-proxy',
        '--path', (Join-Path $taskRoot 'web'), '--reasoning', 'off',
        '--temp', '0.65', '--top-p', '0.9', '--top-k', '40', '--min-p', '0',
        '--image-min-tokens', '64', '--image-max-tokens', '256')
    if ($Engine -eq 'CPU') { $serverArgs += @('--n-gpu-layers', '0', '--no-mmproj-offload') }
    else { $serverArgs += @('--fit', 'on', '--fit-target', '2560', '--fit-ctx', '4096') }
    $logPrefix = Join-Path $taskRoot ('logs\Gemma3-4B-' + $Engine + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Host ('正在从 U 盘加载 Gemma 3 4B 识图模型 (' + $Engine + ')…')
    Write-Host '请保留这个窗口。加载完成后可按 Q 或关闭窗口来停止 AI。'
    Write-Host ('日志：' + $logPrefix + '.err.log')
    $serverProcess = Start-Process -FilePath $server -ArgumentList (($serverArgs | ForEach-Object { Quote-Arg $_ }) -join ' ') -WorkingDirectory $runtime -WindowStyle Hidden -PassThru -RedirectStandardOutput ($logPrefix + '.out.log') -RedirectStandardError ($logPrefix + '.err.log')
    $job.Add($serverProcess.Handle)
    @{pid=$serverProcess.Id; startedUtcTicks=$serverProcess.StartTime.ToUniversalTime().Ticks.ToString(); model='Gemma3-4B-Vision'; engine=$Engine; profile=$hardwareProfile; imageModel=$imageName; executable=$server} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastMessage = -10
    $ready = $false
    while ($timer.Elapsed.TotalSeconds -lt 600) {
        $serverProcess.Refresh()
        if ($serverProcess.HasExited) { throw ('模型进程意外退出，请查看日志：' + $logPrefix + '.err.log') }
        try {
            $health = Request-Local '/health' | ConvertFrom-Json
            if ($health.status -eq 'ok') { $ready = $true; break }
        } catch { }
        if ($timer.Elapsed.TotalSeconds -ge $lastMessage + 10) {
            $lastMessage = [int]$timer.Elapsed.TotalSeconds
            Write-Host ('正在加载… ' + $lastMessage + ' 秒（U 盘读取可能需要几分钟）')
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw 'Model loading timed out. See the log in PortableAI\logs.' }
    $loadSeconds = [Math]::Round($timer.Elapsed.TotalSeconds,1)
    $models = Request-Local '/v1/models' '' 60000 | ConvertFrom-Json
    if (@($models.data | Where-Object { $_.id -eq $modelAlias }).Count -ne 1) { throw '模型身份检查失败。' }
    Write-Host ('加载完成：' + $modelAlias + ' | ' + $baseUrl)
    Write-Host ('硬件配置：' + $hardwareProfile + $(if($gpuName){' | '+$gpuName}else{''}))
    Write-Host ('生图配置：' + $imageName + ' | ' + $imageWidth + '×' + $imageWidth + ' | ' + $imageSteps + ' 步')
    Write-Host ('聊天记录：' + $chatRoot + '（按日期分类）')
    Write-Host ('生成图片：' + $imageRoot + '（按日期分类）')
    if ($SelfTest) {
        $html = Request-Local '/portable-chat.html' '' 10000
        $javascript = Request-Local '/app.js' '' 10000
        $legacyScript = Request-Local '/legacy-import.js' '' 10000
        $stylesheet = Request-Local '/style.css' '' 10000
        $browserConfig = Request-Local '/storage-config.js' '' 10000
        if ($html -notmatch '浮光' -or $html -notmatch 'imageInput' -or $html -notmatch 'editStrip' -or $html -notmatch 'dialogBackdrop' -or $javascript -notmatch 'generateImage' -or $javascript -notmatch 'modelMessages' -or $legacyScript -notmatch 'importLegacyChats' -or $stylesheet -notmatch '\.chat-scroll' -or $browserConfig -notmatch [Regex]::Escape($chatToken)) { throw '中文多模态界面文件检查失败。' }
        $storeState = Request-Store '/api/state' | ConvertFrom-Json
        if (-not $storeState.ok -or $storeState.storageRoot -ne $chatRoot -or -not $storeState.imageReady) { throw 'U 盘存档或生图服务检查失败。' }
        Write-Host '中文界面、滚动布局和 U 盘存档检查通过，正在测试模型回答…'
        $payload = @{model=$modelAlias;messages=@(@{role='user';content='Reply with just the number: What is 12 plus 30?'});max_tokens=48;temperature=0;stream=$false} | ConvertTo-Json -Depth 8 -Compress
        $answer = Request-Local '/v1/chat/completions' $payload 180000 | ConvertFrom-Json
        $content = [string]$answer.choices[0].message.content
        if ($content -notmatch '\b42\b') { throw ('模型回答检查失败：' + $content) }
        Write-Host ('文字回答通过，正在用 ' + $imageName + ' 生成首张测试图片…')
        $imagePayload = @{prompt='a clean minimal illustration of one blue ceramic cup on a warm beige table, soft studio light';originalPrompt='蓝色杯子';steps=$imageSteps;width=$imageWidth;height=$imageWidth;seed=20261113} | ConvertTo-Json -Compress
        $imageResult = Request-Store '/api/images' $imagePayload 900000 | ConvertFrom-Json
        if (-not $imageResult.ok -or [string]$imageResult.dataUrl -notmatch '^data:image/png;base64,') { throw '离线生图检查失败。' }
        Write-Host ('首张生图通过：' + $imageResult.elapsedSeconds + ' 秒；正在验证模型常驻后的第二张速度…')
        $warmImagePayload = @{prompt='a professional studio photo of one green glass bottle on a plain white table, centered composition, soft light';originalPrompt='绿色玻璃瓶';steps=$imageSteps;width=$imageWidth;height=$imageWidth;seed=99} | ConvertTo-Json -Compress
        $warmImageResult = Request-Store '/api/images' $warmImagePayload 900000 | ConvertFrom-Json
        if (-not $warmImageResult.ok -or [string]$warmImageResult.dataUrl -notmatch '^data:image/png;base64,') { throw '常驻模型第二次生图检查失败。' }
        Write-Host '生图通过，正在把生成图片交给 Gemma 做识图检查…'
        $visionPayload = @{model=$modelAlias;messages=@(@{role='user';content=@(@{type='text';text='请用一句简短中文描述这张图片。'},@{type='image_url';image_url=@{url=[string]$imageResult.dataUrl}})});max_tokens=96;temperature=0;stream=$false} | ConvertTo-Json -Depth 12 -Compress
        $visionAnswer = Request-Local '/v1/chat/completions' $visionPayload 300000 | ConvertFrom-Json
        $visionContent = [string]$visionAnswer.choices[0].message.content
        if ([string]::IsNullOrWhiteSpace($visionContent)) { throw '图片识别检查没有返回文字。' }
        $result = @{model='Gemma3-4B-Vision';engine=$Engine;hardwareProfile=$hardwareProfile;imageModel=$imageName;modelIdentity=$modelAlias;health='ok';chineseUI='ok';scrollLayout='ok';usbChatStorage='ok';imageGeneration='ok';vision='ok';reply=$content;visionReply=$visionContent;generatedImage=$imageResult.path;imageSeconds=$imageResult.elapsedSeconds;warmImageSeconds=$warmImageResult.elapsedSeconds;loadSeconds=$loadSeconds;usage=$answer.usage;timings=$answer.timings;testedAt=(Get-Date -Format 'o')}
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $taskRoot ('logs\test-Gemma3-4B-' + $Engine + '.json')) -Encoding UTF8
        Write-Host ('全部实测通过。识图回答：' + $visionContent)
    } else {
        if (-not $NoBrowser) { $browserProcess = Open-Chat; if ($browserProcess) { try { $job.Add($browserProcess.Handle) } catch { Write-Host '浏览器使用独立进程，已启用页面关闭联动。' } } }
        Write-Host 'AI 正在运行。关闭浮光窗口、按 Q 或关闭这个窗口即可停止全部后台。'
        $consoleKeysAvailable = -not [Console]::IsInputRedirected
        $imageJobPid = 0
        $browserMissingTicks = 0
        while (-not $serverProcess.HasExited) {
            $imageProcess = $chatStore.ImageProcess
            if ($imageProcess -and -not $imageProcess.HasExited -and $imageProcess.Id -ne $imageJobPid) { try { $job.Add($imageProcess.Handle); $imageJobPid = $imageProcess.Id } catch { } }
            if ($browserTrackingEnabled) {
                if (Test-ChatWindowAlive) { $browserMissingTicks = 0 } else { $browserMissingTicks++; if ($browserMissingTicks -ge 10) { break } }
            }
            if ($consoleKeysAvailable) {
                try {
                    if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { break }
                } catch { $consoleKeysAvailable = $false }
            }
            Start-Sleep -Milliseconds 500
            $serverProcess.Refresh()
        }
    }
} catch {
    $exitCode = 1
    Write-Host ('错误：' + $_.Exception.Message) -ForegroundColor Red
    if ($logPrefix -and (Test-Path -LiteralPath ($logPrefix + '.err.log'))) { Get-Content -LiteralPath ($logPrefix + '.err.log') -Tail 20 | Write-Host }
} finally {
    if ($browserProcess -and -not $browserProcess.HasExited) { Stop-Process -Id $browserProcess.Id -Force -ErrorAction SilentlyContinue }
    if (-not $NoBrowser -or $StopOnly) { Stop-ChatWindows }
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue; $serverProcess.WaitForExit(10000) | Out-Null }
    if ($job) { $job.Dispose() }
    if ($chatStore) { $chatStore.Dispose() }
    if ($serverProcess -and (Test-Path -LiteralPath $statePath)) {
        try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json; if ([int]$state.pid -eq $serverProcess.Id) { Remove-Item -LiteralPath $statePath -Force } } catch { }
    }
}
exit $exitCode
