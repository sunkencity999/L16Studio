# Installs L16 Studio on a Light L16 camera plugged into this computer.
#
#   install.bat               install (or update) the app
#   install.bat -Replace      remove an existing copy first
#   install.bat -Uninstall    remove the app from the camera
#   install.bat -Yes          don't ask before installing on a non-L16 device
#
# The camera's own software is not modified: this installs one ordinary app.
param([switch]$Replace, [switch]$Uninstall, [switch]$Yes)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$apk = Join-Path $here "l16studio.apk"
$package = "dev.sunkencity.l16studio"

function Step($text) { Write-Host ""; Write-Host "==> $text" }
function Fail($text) { Write-Host ""; Write-Host "error: $text" -ForegroundColor Red; exit 1 }

if (-not $Uninstall -and -not (Test-Path $apk)) { Fail "l16studio.apk is missing; it should sit next to this script." }

# adb is Google's tool for talking to Android devices over USB. Use the
# computer's own copy if there is one; otherwise fetch Google's official
# build into this folder (nothing is installed system-wide).
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
    $local = Join-Path $here "platform-tools\adb.exe"
    if (-not (Test-Path $local)) {
        Step "Fetching Google's adb tool (one time)"
        $zip = Join-Path $here "platform-tools.zip"
        try {
            Invoke-WebRequest -Uri "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $here -Force
            Remove-Item $zip
        } catch {
            Fail "couldn't download adb. Check the internet connection, or install Android platform-tools yourself."
        }
    }
    if (-not (Test-Path $local)) { Fail "the adb download didn't unpack as expected." }
    $adb = $local
}

function Devices {
    $lines = & $adb devices 2>$null | Select-Object -Skip 1
    foreach ($line in $lines) {
        $parts = $line -split "\s+" | Where-Object { $_ }
        if ($parts.Count -ge 2) { [pscustomobject]@{ Serial = $parts[0]; State = $parts[1] } }
    }
}

Step "Looking for the camera"
& $adb start-server 2>$null | Out-Null
$serial = $null; $model = $null; $shown = ""; $waited = 0
while (-not $serial) {
    $list = @(Devices)
    $ready = @($list | Where-Object { $_.State -eq "device" })
    if ($ready.Count -gt 0) {
        foreach ($d in $ready) {
            $m = ((& $adb -s $d.Serial shell getprop ro.product.model) | Out-String).Trim()
            if ($m -eq "L16") { $serial = $d.Serial; $model = $m; break }
            if (-not $serial) { $serial = $d.Serial; $model = $m }
        }
        break
    }
    $state = if ($list | Where-Object { $_.State -eq "unauthorized" }) { "unauthorized" } else { "none" }
    if ($state -ne $shown) {
        $shown = $state
        Write-Host ""
        if ($state -eq "unauthorized") {
            Write-Host "The camera is connected but hasn't approved this computer yet."
            Write-Host "Look at the camera's screen: tick ""Always allow from this computer"" and tap OK."
        } else {
            Write-Host "No camera found yet. Check these, in order:"
            Write-Host "  1. Plug the L16 straight into this computer with a USB-C data cable"
            Write-Host "     (not through a hub; some hubs hide the camera)."
            Write-Host "  2. Wake the camera and unlock its screen."
            Write-Host "  3. Turn on USB debugging, once per camera:"
            Write-Host "       Settings > About > tap ""Build number"" seven times,"
            Write-Host "       then Settings > Developer options > switch on ""USB debugging""."
            Write-Host "  4. When the camera asks ""Allow USB debugging?"", tick"
            Write-Host "     ""Always allow from this computer"" and tap OK."
            Write-Host ""
            Write-Host "If it still doesn't appear, Windows may need a USB driver for the camera"
            Write-Host "(Google's ""USB Driver"" for Android devices usually works)."
            Write-Host ""
            Write-Host "Waiting (this carries on by itself once the camera appears; Ctrl-C to stop)..."
        }
    }
    Start-Sleep -Seconds 2
    $waited += 2
    if ($waited -ge 600) { Fail "no camera appeared within 10 minutes." }
}
Write-Host "Found: $model (serial $serial)"

if ($model -ne "L16") {
    Write-Host ""
    Write-Host "This device reports itself as ""$model"", not a Light L16."
    Write-Host "L16 Studio is built for the L16 and won't be useful anywhere else."
    if (-not $Yes) {
        $answer = Read-Host "Continue anyway? [y/N]"
        if ($answer -notmatch "^(y|yes)$") { Write-Host "Stopped. Nothing was changed."; exit 1 }
    }
}

function Installed {
    $out = (& $adb -s $serial shell pm list packages $package | Out-String)
    return $out -match "package:$([regex]::Escape($package))(\s|$)"
}

if ($Uninstall) {
    Step "Removing L16 Studio from the camera"
    if (Installed) { & $adb -s $serial uninstall $package | Out-Null; Write-Host "Removed. Your shots are untouched." }
    else { Write-Host "L16 Studio isn't installed on this camera." }
    exit 0
}

if ($Replace -and (Installed)) {
    Step "Removing the existing copy"
    & $adb -s $serial uninstall $package | Out-Null
}

Step "Installing L16 Studio"
$output = (& $adb -s $serial install -r $apk 2>&1 | Out-String)
if ($output -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match") {
    Fail "the camera already has a copy of L16 Studio from a different build. Run this again with -Replace to remove that copy first (your shots are not affected)."
}
if ($output -notmatch "Success") { Write-Host $output; Fail "the install didn't complete." }

& $adb -s $serial shell input keyevent KEYCODE_WAKEUP 2>$null | Out-Null
& $adb -s $serial shell am start -n "$package/.GalleryActivity" 2>$null | Out-Null

Step "Done"
Write-Host "L16 Studio is installed and open on the camera."
Write-Host ""
Write-Host "On the camera you'll find it in the app list as ""L16 Studio"":"
Write-Host "  - a gallery of your shots, with a full-screen viewer"
Write-Host "  - Edit: Auto and six looks, with sliders, saving a copy next to the shot"
Write-Host "  - Wi-Fi transfer: serve your shots to L16Studio on a Mac, or to any browser"
Write-Host "  - Camera: jumps to Light's own camera app, which still takes the pictures"
Write-Host ""
Write-Host "To remove it later: install.bat -Uninstall"
