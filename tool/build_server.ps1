[CmdletBinding()]
param(
    [string]$AndroidSdk = "",
    [string]$BuildToolsVersion = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $repoRoot "android-server"
$sourceRoot = Join-Path $serverRoot "src\main\java"
$buildRoot = Join-Path $repoRoot "build\server"
$assetRoot = Join-Path $repoRoot "assets\server"

function Find-AndroidSdk {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) {
            throw "Android SDK not found: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    foreach ($candidate in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA "Android\Sdk"))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "Android SDK not found. Pass -AndroidSdk or set ANDROID_HOME."
}

$sdk = Find-AndroidSdk -Explicit $AndroidSdk
$buildToolsRoot = Join-Path $sdk "build-tools"
if (-not (Test-Path -LiteralPath $buildToolsRoot)) {
    throw "Android build-tools not found under $buildToolsRoot"
}

if ($BuildToolsVersion) {
    $buildTools = Join-Path $buildToolsRoot $BuildToolsVersion
    if (-not (Test-Path -LiteralPath (Join-Path $buildTools "d8.bat"))) {
        throw "d8.bat not found in $buildTools"
    }
} else {
    $buildTools = Get-ChildItem $buildToolsRoot -Directory |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$d8 = Join-Path $buildTools "d8.bat"
$androidJar = Get-ChildItem (Join-Path $sdk "platforms") -Recurse -Filter android.jar |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $androidJar) {
    throw "android.jar not found under $sdk\platforms"
}

$sources = Get-ChildItem $sourceRoot -Recurse -Filter *.java | ForEach-Object { $_.FullName }
if (-not $sources) {
    throw "No Java sources found under $sourceRoot"
}

if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $buildRoot "classes"), (Join-Path $buildRoot "dex"), $assetRoot | Out-Null

Write-Host "Compiling server classes..."
& javac --release 8 -cp $androidJar -d (Join-Path $buildRoot "classes") $sources
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

$classesJar = Join-Path $buildRoot "server-classes.jar"
Write-Host "Packaging class jar..."
& jar --create --file $classesJar -C (Join-Path $buildRoot "classes") .
if ($LASTEXITCODE -ne 0) { throw "jar (classes) failed" }

Write-Host "Dexing with $d8..."
& $d8 --min-api 24 --lib $androidJar --output (Join-Path $buildRoot "dex") $classesJar
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

$serverJar = Join-Path $assetRoot "screencast-server.jar"
Write-Host "Packaging app_process jar..."
& jar --create --file $serverJar -C (Join-Path $buildRoot "dex") classes.dex
if ($LASTEXITCODE -ne 0) { throw "jar (dex) failed" }

# The Android controller app bundles its own copy of the jar; keep it in sync or
# the APK silently ships the previous server build.
$appAssetRoot = Join-Path $repoRoot "android-app\app\src\main\assets"
if (Test-Path -LiteralPath $appAssetRoot) {
    $appJar = Join-Path $appAssetRoot "screencast-server.jar"
    Copy-Item -LiteralPath $serverJar -Destination $appJar -Force
    Write-Host "Synced $appJar"
}

Write-Host "Built $serverJar"
Write-Host "Verify with: jar tf `"$serverJar`""
