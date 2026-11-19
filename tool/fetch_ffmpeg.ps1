[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$destRoot = Join-Path $repoRoot "third_party\ffmpeg"
$destBin = Join-Path $destRoot "bin"
$toolsRoot = Join-Path $repoRoot "build\ffmpeg-tools"
$archive = Join-Path $repoRoot "build\ffmpeg-8.1.2-full_build-shared.7z"
$extractRoot = Join-Path $repoRoot "build\ffmpeg-extract"
$ffmpegUrl = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-full_build-shared.7z"
$sevenZipUrl = "https://www.7-zip.org/a/7zr.exe"

New-Item -ItemType Directory -Force $destBin, $toolsRoot | Out-Null

$required = @(
    "avcodec-62.dll",
    "avutil-60.dll",
    "swresample-6.dll"
)
$haveAll = $true
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $destBin $name))) {
        $haveAll = $false
    }
}
if ($haveAll -and -not $Force) {
    Write-Host "FFmpeg runtime already present in $destBin"
    exit 0
}

$sevenZip = Join-Path $toolsRoot "7zr.exe"
if (-not (Test-Path -LiteralPath $sevenZip)) {
    Write-Host "Downloading 7zr..."
    & curl.exe -L --fail --retry 3 -o $sevenZip $sevenZipUrl
    if ($LASTEXITCODE -ne 0) { throw "7zr download failed" }
}

if (-not (Test-Path -LiteralPath $archive)) {
    Write-Host "Downloading FFmpeg 8.1.2 shared build (about 59 MB)..."
    & curl.exe -L --fail --retry 3 -o $archive $ffmpegUrl
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg download failed" }
}

$shaFile = "$archive.sha256"
if (-not (Test-Path -LiteralPath $shaFile)) {
    & curl.exe -L --fail --retry 3 -o $shaFile "$ffmpegUrl.sha256"
}
if (Test-Path -LiteralPath $shaFile) {
    $expected = (Get-Content -LiteralPath $shaFile -TotalCount 1).Split()[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        throw "FFmpeg archive checksum mismatch."
    }
    Write-Host "FFmpeg archive checksum verified."
}

if (Test-Path -LiteralPath $extractRoot) {
    Remove-Item -LiteralPath $extractRoot -Recurse -Force
}
New-Item -ItemType Directory -Force $extractRoot | Out-Null
Write-Host "Extracting..."
& $sevenZip x $archive "-o$extractRoot" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "FFmpeg extraction failed" }

$packageRoot = Get-ChildItem -LiteralPath $extractRoot -Directory |
    Select-Object -First 1
if (-not $packageRoot) {
    throw "FFmpeg package root was not found."
}

$sourceBin = Join-Path $packageRoot.FullName "bin"
foreach ($name in $required) {
    $source = Join-Path $sourceBin $name
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Expected $name in the FFmpeg shared package."
    }
    Copy-Item -LiteralPath $source -Destination $destBin -Force
}
Copy-Item -LiteralPath (Join-Path $packageRoot.FullName "LICENSE") `
    -Destination (Join-Path $destRoot "LICENSE.txt") -Force
Copy-Item -LiteralPath (Join-Path $packageRoot.FullName "README.txt") `
    -Destination (Join-Path $destRoot "BUILD-README.txt") -Force

Write-Host "Installed FFmpeg decoder DLLs to $destBin"
Write-Host "Source: $ffmpegUrl"
