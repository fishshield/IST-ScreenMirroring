[CmdletBinding()]
param(
    [string]$Serial = "",
    [ValidateRange(1024, 65535)]
    [int]$Port = 27183,
    [string]$Jar = "",
    [string]$RemoteJar = "/data/local/tmp/screencast-server.jar",
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

$adbCommand = Get-Command adb -ErrorAction Stop
$adbArgs = @()
if ($Serial) {
    $adbArgs += @("-s", $Serial)
}

if ($Stop) {
    & $adbCommand.Source @adbArgs shell "pkill -f com.example.screencast.server.Server"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "No running capture server was found (it may already be stopped)."
    }
    & $adbCommand.Source @adbArgs forward --remove "tcp:$Port" 2>$null
    Write-Host "Requested stop and removed tcp:$Port forwarding."
    exit 0
}

if ($Jar) {
    if (-not (Test-Path -LiteralPath $Jar -PathType Leaf)) {
        throw "Server jar not found: $Jar"
    }
    & $adbCommand.Source @adbArgs push $Jar $RemoteJar
    if ($LASTEXITCODE -ne 0) {
        throw "adb push failed."
    }
}

& $adbCommand.Source @adbArgs forward "tcp:$Port" "tcp:$Port"
if ($LASTEXITCODE -ne 0) {
    throw "adb forward failed."
}

Write-Host "Forwarding 127.0.0.1:$Port -> $RemoteJar"
Write-Host "Starting app_process as the shell user; press Ctrl+C to end the adb shell session."

& $adbCommand.Source @adbArgs shell "CLASSPATH=$RemoteJar app_process /system/bin com.example.screencast.server.Server --port=$Port"
exit $LASTEXITCODE
