param([string]$Destination = '')

$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
$manifestPath = Join-Path $packageRoot 'Floatlight-Full-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw '缺少 Floatlight-Full-manifest.json，请把安装器和所有分卷放在同一文件夹。'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Destination) { $Destination = Join-Path $packageRoot '浮光离线AI' }
$Destination = [IO.Path]::GetFullPath($Destination)
$temporary = $Destination + '.installing'
if (Test-Path -LiteralPath $Destination) { throw ('目标文件夹已经存在：' + $Destination) }
if (Test-Path -LiteralPath $temporary) { [IO.Directory]::Delete($temporary, $true) }
[IO.Directory]::CreateDirectory($temporary) | Out-Null

function Convert-ToHex([byte[]]$bytes) {
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

$parts = @($manifest.parts)
$files = @($manifest.files)
$buffer = New-Object byte[] (4MB)
$partIndex = -1
$partStream = $null
$partHasher = $null
$partRemaining = [int64]0

function Open-NextPart {
    if ($script:partStream) { throw '内部错误：上一个分卷尚未关闭。' }
    $script:partIndex++
    if ($script:partIndex -ge $script:parts.Count) { throw '分卷数量不足，无法继续还原。' }
    $partInfo = $script:parts[$script:partIndex]
    $partPath = Join-Path $script:packageRoot ([string]$partInfo.name)
    if (-not (Test-Path -LiteralPath $partPath -PathType Leaf)) { throw ('缺少分卷：' + $partInfo.name) }
    $actualSize = (Get-Item -LiteralPath $partPath).Length
    if ($actualSize -ne [int64]$partInfo.size) { throw ('分卷大小不正确：' + $partInfo.name) }
    Write-Host ('正在读取 ' + $partInfo.name + ' ...') -ForegroundColor Cyan
    $script:partStream = [IO.File]::OpenRead($partPath)
    $script:partHasher = [Security.Cryptography.SHA256]::Create()
    $script:partRemaining = [int64]$partInfo.size
}

function Close-CurrentPart {
    $partInfo = $script:parts[$script:partIndex]
    [void]$script:partHasher.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    $actual = Convert-ToHex $script:partHasher.Hash
    $script:partHasher.Dispose()
    $script:partStream.Dispose()
    $script:partHasher = $null
    $script:partStream = $null
    $script:partRemaining = 0
    if ($actual -ne ([string]$partInfo.sha256).ToLowerInvariant()) {
        throw ('分卷校验失败，请重新下载：' + $partInfo.name)
    }
}

try {
    Open-NextPart
    $fileNumber = 0
    foreach ($fileInfo in $files) {
        $fileNumber++
        $relative = ([string]$fileInfo.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $target = Join-Path $temporary $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $fileHasher = [Security.Cryptography.SHA256]::Create()
        $fileRemaining = [int64]$fileInfo.size
        try {
            while ($fileRemaining -gt 0) {
                if ($partRemaining -eq 0) { Close-CurrentPart; Open-NextPart }
                $wanted = [int][Math]::Min([int64]$buffer.Length, [Math]::Min($fileRemaining, $partRemaining))
                $read = $partStream.Read($buffer, 0, $wanted)
                if ($read -le 0) { throw '分卷意外结束。' }
                [void]$partHasher.TransformBlock($buffer, 0, $read, $buffer, 0)
                [void]$fileHasher.TransformBlock($buffer, 0, $read, $buffer, 0)
                $output.Write($buffer, 0, $read)
                $fileRemaining -= $read
                $partRemaining -= $read
            }
        } finally { $output.Dispose() }
        [void]$fileHasher.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $actualFileHash = Convert-ToHex $fileHasher.Hash
        $fileHasher.Dispose()
        if ($actualFileHash -ne ([string]$fileInfo.sha256).ToLowerInvariant()) {
            throw ('文件校验失败：' + $fileInfo.path)
        }
        Write-Progress -Activity '正在安装浮光完整离线 AI' -Status ([string]$fileInfo.path) -PercentComplete (($fileNumber / $files.Count) * 100)
    }
    if ($partRemaining -eq 0) { Close-CurrentPart }
    if ($partStream -or $partIndex -ne ($parts.Count - 1)) { throw '安装包中存在未使用的数据。' }
    [IO.Directory]::Move($temporary, $Destination)
    Write-Progress -Activity '正在安装浮光完整离线 AI' -Completed
    Write-Host ('安装完成：' + $Destination) -ForegroundColor Green
    Write-Host '双击“点击启动-浮光离线AI.cmd”即可直接使用，无需下载模型。' -ForegroundColor Green
} catch {
    if ($partStream) { $partStream.Dispose() }
    if ($partHasher) { $partHasher.Dispose() }
    Write-Error $_
    exit 1
}
