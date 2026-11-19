[CmdletBinding()]
param(
    [switch]$Force,
    # Optional Release asset URL. When omitted, the script uses
    # $env:SCREENCAST_FFMPEG_RELEASE, then a URL derived from the `origin`
    # remote (…/releases/download/ffmpeg-8.1.2/…zip), and finally the upstream
    # gyan.dev 7z package.
    [string]$ReleaseUrl = ""
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
$releaseAssetName = "ffmpeg-8.1.2-shared-win64.zip"

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

function Resolve-ReleaseUrl {
    if ($ReleaseUrl) { return $ReleaseUrl }
    if ($env:SCREENCAST_FFMPEG_RELEASE) { return $env:SCREENCAST_FFMPEG_RELEASE }
    try {
        $remote = (& git -C $repoRoot remote get-url origin 2>$null)
    } catch {
        return $null
    }
    if (-not $remote) { return $null }
    # git@github.com:owner/repo.git or https://github.com/owner/repo(.git)
    if ($remote -match 'github\.com[:/](?<slug>[^/]+/[^/]+?)(?:\.git)?$') {
        $slug = $matches['slug']
        return "https://github.com/$slug/releases/download/ffmpeg-8.1.2/$releaseAssetName"
    }
    return $null
}

function Assert-Checksums {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $sums = Join-Path $Directory "SHA256SUMS"
    if (-not (Test-Path -LiteralPath $sums)) {
        Write-Warning "No SHA256SUMS in the package; skipping checksum verification."
        return
    }
    foreach ($line in Get-Content -LiteralPath $sums) {
        if ($line -match '^(?<hash>[0-9a-fA-F]{64})\s+(?<name>\S+)$') {
            $file = Join-Path $Directory $matches['name']
            if (-not (Test-Path -LiteralPath $file)) {
                throw "Package is missing $($matches['name'])."
            }
            $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $matches['hash'].ToLowerInvariant()) {
                throw "Checksum mismatch for $($matches['name'])."
            }
        }
    }
    Write-Host "FFmpeg DLL checksums verified."
}

function Install-FromDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)
    Assert-Checksums $Directory
    foreach ($name in $required) {
        Copy-Item -LiteralPath (Join-Path $Directory $name) -Destination $destBin -Force
    }
    foreach ($extra in @("LICENSE.txt", "BUILD-README.txt")) {
        $source = Join-Path $Directory $extra
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $destRoot -Force
        }
    }
}

$installed = $false
$url = Resolve-ReleaseUrl
if ($url) {
    try {
        Write-Host "Downloading FFmpeg DLLs from the Release asset..."
        $releaseZip = Join-Path $repoRoot "build\$releaseAssetName"
        & curl.exe -L --fail --retry 3 -o $releaseZip $url
        if ($LASTEXITCODE -ne 0) { throw "download failed" }
        $releaseExtract = Join-Path $repoRoot "build\ffmpeg-release"
        if (Test-Path -LiteralPath $releaseExtract) {
            Remove-Item -LiteralPath $releaseExtract -Recurse -Force
        }
        Expand-Archive -LiteralPath $releaseZip -DestinationPath $releaseExtract -Force
        Install-FromDirectory $releaseExtract
        $installed = $true
        Write-Host "Installed FFmpeg decoder DLLs from $url"
    } catch {
        Write-Warning "Release asset unavailable ($($_.Exception.Message)); using upstream."
    }
}

if (-not $installed) {
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
    $staged = Join-Path $repoRoot "build\ffmpeg-staged"
    if (Test-Path -LiteralPath $staged) {
        Remove-Item -LiteralPath $staged -Recurse -Force
    }
    New-Item -ItemType Directory -Force $staged | Out-Null
    foreach ($name in $required) {
        $source = Join-Path $sourceBin $name
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Expected $name in the FFmpeg shared package."
        }
        Copy-Item -LiteralPath $source -Destination $staged -Force
    }
    Copy-Item -LiteralPath (Join-Path $destRoot "SHA256SUMS") -Destination $staged -Force `
        -ErrorAction SilentlyContinue
    Install-FromDirectory $staged
    Write-Host "Installed FFmpeg decoder DLLs from $ffmpegUrl"
}

Write-Host "FFmpeg runtime ready in $destBin"
