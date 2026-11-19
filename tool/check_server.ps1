[CmdletBinding()]
param()

# JVM-only checks for the Android-independent server helpers
# (CaptureCoreCheck): Annex-B splitting, option parsing, letterbox geometry,
# input mapping updates and the wheel sign conversion. No device or Android
# runtime involved, but the server classes must be built first.

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $repoRoot "android-server"
$buildRoot = Join-Path $repoRoot "build\server"
$classesRoot = Join-Path $buildRoot "classes"
$testClassesRoot = Join-Path $buildRoot "test-classes"
$classPathSeparator = [System.IO.Path]::PathSeparator

if (-not (Test-Path -LiteralPath $classesRoot)) {
    throw "Server classes not found at $classesRoot. Run tool\build_server.ps1 first."
}

$sources = Get-ChildItem (Join-Path $serverRoot "src\test\java") -Recurse -Filter *.java |
    ForEach-Object { $_.FullName }
if (-not $sources) {
    throw "No Java check sources found under android-server\src\test\java"
}

if (Test-Path -LiteralPath $testClassesRoot) {
    Remove-Item -LiteralPath $testClassesRoot -Recurse -Force
}
New-Item -ItemType Directory -Force $testClassesRoot | Out-Null

Write-Host "Compiling JVM-only checks..."
& javac -cp $classesRoot -d $testClassesRoot $sources
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

Write-Host "Running JVM-only checks..."
& java -cp "$classesRoot$classPathSeparator$testClassesRoot" com.example.screencast.server.CaptureCoreCheck
if ($LASTEXITCODE -ne 0) { throw "CaptureCoreCheck failed" }
