param(
    [switch]$ImageOnly,
    [switch]$Quality,
    [switch]$QualityOnly
)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$modelRoot = Join-Path $appRoot 'models'
$tempRoot = Join-Path $appRoot 'temp'
[IO.Directory]::CreateDirectory($modelRoot) | Out-Null
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$env:TEMP = $tempRoot
$env:TMP = $tempRoot
$curl = (Get-Command curl.exe -ErrorAction Stop).Source

$models = @(
    [pscustomobject]@{ Name='Gemma 3 4B Q4_K_M'; File='gemma-3-4b-it-q4_0.gguf'; Size=2489757856L; Sha='882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863'; Path='ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf'; Group='chat'; Alternates=@([pscustomobject]@{Size=3155051328L;Sha='76aed0a8285b83102f18b5d60e53c70d09eb4e9917a20ce8956bd546452b56e2'}) },
    [pscustomobject]@{ Name='Gemma 3 视觉投影 F16'; File='gemma-3-4b-it-mmproj-f16.gguf'; Size=851251104L; Sha='8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb'; Path='ggml-org/gemma-3-4b-it-GGUF/resolve/main/mmproj-model-f16.gguf'; Group='chat'; Alternates=@() },
    [pscustomobject]@{ Name='SD-Turbo Q4_0'; File='sd-turbo-q4_0.gguf'; Size=1847909248L; Sha='d069ef2b2d3d5c2465662d706c242a1016db56163c109bd7e3008a94cdd00359'; Path='samoudi/sd-turbo-gguf/resolve/main/sd_turbo_q4_0.gguf'; Group='image'; Alternates=@() },
    [pscustomobject]@{ Name='SDXL-Turbo Q4_0（高显存精细模式）'; File='stable-diffusion-xl-1.0-turbo-Q4_0.gguf'; Size=3940010720L; Sha='5282eec23430ca46de87de984521fbf04e3cf78fa4152b05610089bc71d8a535'; Path='gpustack/stable-diffusion-xl-1.0-turbo-GGUF/resolve/main/stable-diffusion-xl-1.0-turbo-Q4_0.gguf'; Group='quality'; Alternates=@() }
)

function Get-Sha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-Installed($model, [string]$target) {
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return $false }
    $size = (Get-Item -LiteralPath $target).Length
    $candidates = @([pscustomobject]@{Size=$model.Size;Sha=$model.Sha}) + @($model.Alternates)
    $candidate = @($candidates | Where-Object { [int64]$_.Size -eq $size } | Select-Object -First 1)
    if (-not $candidate.Count) { return $false }
    return (Get-Sha256 $target) -eq [string]$candidate[0].Sha
}

function Install-Model($model) {
    $target = Join-Path $modelRoot $model.File
    $part = $target + '.part'
    if (Test-Installed $model $target) {
        Write-Host ($model.Name + ' 已存在并校验通过。') -ForegroundColor Green
        return
    }
    $sources = @('https://hf-mirror.com/' + $model.Path, 'https://huggingface.co/' + $model.Path)
    $downloaded = $false
    foreach ($url in $sources) {
        Write-Host ('正在下载 ' + $model.Name + '：' + ([Uri]$url).Host) -ForegroundColor Cyan
        & $curl --location --fail --retry 4 --retry-all-errors --connect-timeout 20 --continue-at - --output $part $url
        if ($LASTEXITCODE -eq 0) { $downloaded = $true; break }
        Write-Host '当前下载源不可用，正在切换。' -ForegroundColor Yellow
    }
    if (-not $downloaded) { throw ($model.Name + ' 下载失败。') }
    $actualSize = (Get-Item -LiteralPath $part).Length
    if ($actualSize -ne [int64]$model.Size) { throw ('文件大小不正确：' + $actualSize) }
    Write-Host '正在校验 SHA-256…'
    $actualHash = Get-Sha256 $part
    if ($actualHash -ne [string]$model.Sha) { throw ('SHA-256 不匹配：' + $actualHash) }
    if (Test-Path -LiteralPath $target) { [IO.File]::Replace($part, $target, $null) } else { [IO.File]::Move($part, $target) }
    Write-Host ('完成：' + $target) -ForegroundColor Green
}

if ($QualityOnly) { $selected = @($models | Where-Object Group -eq 'quality') }
elseif ($ImageOnly) { $selected = @($models | Where-Object Group -eq 'image') }
else {
    $selected = @($models | Where-Object { $_.Group -in @('chat','image') })
    if ($Quality) { $selected += @($models | Where-Object Group -eq 'quality') }
}
foreach ($model in $selected) { Install-Model $model }
Write-Host '所选模型已经准备好。' -ForegroundColor Green
