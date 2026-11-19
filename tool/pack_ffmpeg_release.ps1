# Packs the FFmpeg shared DLLs into the zip that is attached to a GitHub
# Release. Publishing the binaries as a Release asset keeps the repository
# small, and the GPLv3 obligations stay scoped to the FFmpeg build itself.
#
#   powershell -ExecutionPolicy Bypass -File tool\pack_ffmpeg_release.ps1
#
# Then create a Release tagged `ffmpeg-8.1.2` in your repository and upload
# `dist\ffmpeg-8.1.2-shared-win64.zip`. `tool\fetch_ffmpeg.ps1` finds that URL
# through the `origin` remote automatically and falls back to the upstream
# 7z package when the asset is missing.

[CmdletBinding()]
param(
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$ffmpegRoot = Join-Path $repoRoot "third_party\ffmpeg"
$binDirectory = Join-Path $ffmpegRoot "bin"
if (-not (Test-Path -LiteralPath $binDirectory)) {
    throw "Run tool\fetch_ffmpeg.ps1 first: $binDirectory is missing."
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot "dist"
}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null

$required = @(
    "avcodec-62.dll",
    "avutil-60.dll",
    "swresample-6.dll"
)
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $binDirectory $name))) {
        throw "Missing $name; run tool\fetch_ffmpeg.ps1 first."
    }
}

$staging = Join-Path $env:TEMP ("screencast-ffmpeg-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $staging | Out-Null
try {
    foreach ($name in $required) {
        Copy-Item -LiteralPath (Join-Path $binDirectory $name) `
            -Destination (Join-Path $staging $name)
    }
    Copy-Item -LiteralPath (Join-Path $ffmpegRoot "LICENSE.txt") `
        -Destination (Join-Path $staging "LICENSE.txt")
    Copy-Item -LiteralPath (Join-Path $ffmpegRoot "BUILD-README.txt") `
        -Destination (Join-Path $staging "BUILD-README.txt")
    Copy-Item -LiteralPath (Join-Path $ffmpegRoot "SHA256SUMS") `
        -Destination (Join-Path $staging "SHA256SUMS")

    $zipPath = Join-Path $OutputDirectory "ffmpeg-8.1.2-shared-win64.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zipPath -CompressionLevel Optimal

    $sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Created $zipPath ($sizeMb MB)"
    Write-Host "SHA256: $hash"
    Write-Host ""
    Write-Host "Next: create a GitHub Release tagged 'ffmpeg-8.1.2' and upload this zip."
    Write-Host "fetch_ffmpeg.ps1 derives the asset URL from the 'origin' remote;"
    Write-Host "or run it with -ReleaseUrl <url>."
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
