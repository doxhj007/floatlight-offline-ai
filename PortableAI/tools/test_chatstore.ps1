$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$tempRoot = Join-Path $appRoot 'temp'
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$env:TEMP = $tempRoot
$env:TMP = $tempRoot
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $appRoot 'ChatStore.cs'))) -ReferencedAssemblies 'System.Web.Extensions.dll'
$storeRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot 'store-api-test'))
$appFull = [IO.Path]::GetFullPath($appRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if (-not $storeRoot.StartsWith($appFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test root.' }
if ([IO.Directory]::Exists($storeRoot)) { [IO.Directory]::Delete($storeRoot, $true) }
$imageRoot = Join-Path $tempRoot 'store-api-images'
$token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
$store = New-Object PortableChatStore -ArgumentList @(
    $storeRoot, $token, 18989, 'http://127.0.0.1:18888',
    (Join-Path $appRoot 'runtime-image\sd-server.exe'),
    (Join-Path $appRoot 'models\stable-diffusion-xl-1.0-turbo-Q4_0.gguf'),
    $imageRoot, 18991, 'cpu', '', 384, 1, 'test'
)
function Call-Store([string]$method, [string]$path, [string]$body = '') {
    $request = [Net.HttpWebRequest]::Create('http://127.0.0.1:18989' + $path)
    $request.Proxy = $null
    $request.Method = $method
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
    $request.Headers['Origin'] = 'http://127.0.0.1:18888'
    $request.Headers['Authorization'] = 'Bearer ' + $token
    if ($body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $request.ContentType = 'application/json'
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}
try {
    Write-Output 'Starting test store...'
    $store.Start()
    $id = [guid]::NewGuid().ToString('D')
    $now = [DateTimeOffset]::Now.ToString('o')
    $chat = @{schemaVersion=2;id=$id;title='API test';createdAt=$now;updatedAt=$now;revision=0;messages=@(
        @{id=[guid]::NewGuid().ToString('D');role='user';content='edited prompt';createdAt=$now;editedAt=$now}
    )} | ConvertTo-Json -Depth 8 -Compress
    Write-Output 'Testing save...'
    $saved = Call-Store 'POST' '/api/chats' $chat
    if (-not $saved.ok -or -not $saved.chat.messages[0].editedAt) { throw 'Save or editedAt failed.' }
    Write-Output 'Testing delete...'
    $deleted = Call-Store 'DELETE' ('/api/chats/' + $id)
    if (-not $deleted.ok) { throw 'Delete failed.' }
    Write-Output 'Testing state...'
    $state = Call-Store 'GET' '/api/state'
    if (@($state.chats).Count -ne 0) { throw 'Deleted chat remains in index.' }
    Write-Output 'ChatStore save/edit/delete API test passed.'
} finally {
    $store.Dispose()
    Start-Sleep -Milliseconds 200
    if ([IO.Directory]::Exists($storeRoot)) { [IO.Directory]::Delete($storeRoot, $true) }
    if ([IO.Directory]::Exists($imageRoot)) { [IO.Directory]::Delete($imageRoot, $true) }
}
