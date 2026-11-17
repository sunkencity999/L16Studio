#!/bin/bash
# Installs L16 Studio on a Light L16 camera plugged into this computer.
#
#   ./install.sh              install (or update) the app
#   ./install.sh --replace    remove an existing copy first (needed if it was
#                             installed from a different build of this package)
#   ./install.sh --uninstall  remove the app from the camera
#   ./install.sh --yes        don't ask before installing on a non-L16 device
#
# The camera's own software is not modified: this installs one ordinary app,
# which can be removed again with --uninstall or from the camera's Settings.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK="$HERE/l16studio.apk"
PACKAGE="dev.sunkencity.l16studio"
MODE="install"; ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --replace) MODE="replace" ;;
        --uninstall) MODE="uninstall" ;;
        --yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

[ "$MODE" = "uninstall" ] || [ -f "$APK" ] || fail "l16studio.apk is missing; it should sit next to this script."

# ---- adb ---------------------------------------------------------------
# adb is Google's tool for talking to Android devices over USB. Use the
# computer's own copy if there is one; otherwise fetch Google's official
# build into this folder (about 15 MB, nothing is installed system-wide).
find_adb() {
    if command -v adb >/dev/null 2>&1; then ADB="$(command -v adb)"; return; fi
    if [ -x "$HERE/platform-tools/adb" ]; then ADB="$HERE/platform-tools/adb"; return; fi
    local os
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *) fail "this script supports macOS and Linux; on Windows use install.bat." ;;
    esac
    step "Fetching Google's adb tool (one time)"
    command -v curl >/dev/null 2>&1 || fail "curl is needed to download adb. Install adb yourself (Android platform-tools) and run this again."
    command -v unzip >/dev/null 2>&1 || fail "unzip is needed to unpack adb. Install adb yourself (Android platform-tools) and run this again."
    local zip="$HERE/platform-tools.zip"
    curl -fL --progress-bar -o "$zip" "https://dl.google.com/android/repository/platform-tools-latest-$os.zip" \
        || fail "couldn't download adb. Check the internet connection, or install Android platform-tools yourself."
    unzip -q -o "$zip" -d "$HERE" && rm -f "$zip"
    [ -x "$HERE/platform-tools/adb" ] || fail "the adb download didn't unpack as expected."
    ADB="$HERE/platform-tools/adb"
}

# ---- the camera --------------------------------------------------------
# Prints "serial state" for every attached device.
devices() { "$ADB" devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1, $2 }'; }

wait_for_camera() {
    step "Looking for the camera"
    "$ADB" start-server >/dev/null 2>&1 || true
    local shown="" waited=0 state list
    while :; do
        list="$(devices)"
        if printf '%s\n' "$list" | grep -q ' device$'; then
            SERIAL=""
            # Prefer a device that says it is an L16.
            while read -r serial status; do
                [ "$status" = "device" ] || continue
                model="$("$ADB" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
                if [ "$model" = "L16" ]; then SERIAL="$serial"; MODEL="$model"; break; fi
                [ -n "$SERIAL" ] || { SERIAL="$serial"; MODEL="$model"; }
            done <<< "$list"
            return
        elif printf '%s\n' "$list" | grep -q ' unauthorized$'; then
            state="unauthorized"
        else
            state="none"
        fi
        if [ "$state" != "$shown" ]; then
            shown="$state"
            if [ "$state" = "unauthorized" ]; then
                say ""
                say "The camera is connected but hasn't approved this computer yet."
                say "Look at the camera's screen: tick \"Always allow from this computer\" and tap OK."
            else
                say ""
                say "No camera found yet. Check these, in order:"
                say "  1. Plug the L16 straight into this computer with a USB-C data cable"
                say "     (not through a hub; some hubs hide the camera)."
                say "  2. Wake the camera and unlock its screen."
                say "  3. Turn on USB debugging, once per camera:"
                say "       Settings > About > tap \"Build number\" seven times,"
                say "       then Settings > Developer options > switch on \"USB debugging\"."
                say "  4. When the camera asks \"Allow USB debugging?\", tick"
                say "     \"Always allow from this computer\" and tap OK."
                say ""
                say "Waiting (this will carry on by itself once the camera appears; Ctrl-C to stop)..."
            fi
        fi
        sleep 2
        waited=$((waited + 2))
        [ "$waited" -lt 600 ] || fail "no camera appeared within 10 minutes."
    done
}

find_adb
wait_for_camera
say "Found: ${MODEL:-unknown device} (serial $SERIAL)"

if [ "${MODEL:-}" != "L16" ]; then
    say ""
    say "This device reports itself as \"${MODEL:-unknown}\", not a Light L16."
    say "L16 Studio is built for the L16 and won't be useful anywhere else."
    if [ "$ASSUME_YES" -ne 1 ]; then
        printf 'Continue anyway? [y/N] '
        read -r answer || answer=""
        case "$answer" in y|Y|yes|YES) ;; *) say "Stopped. Nothing was changed."; exit 1 ;; esac
    fi
fi

adb_s() { "$ADB" -s "$SERIAL" "$@"; }
installed() { adb_s shell pm list packages "$PACKAGE" 2>/dev/null | tr -d '\r' | grep -qx "package:$PACKAGE"; }

# If the user allowed the app to turn the screen off ("Screen off"), Android
# won't uninstall it until the app gives that permission back. The app does
# that itself when asked; this is harmless if the permission was never given.
release_screen_permission() {
    adb_s shell am start -n "$PACKAGE/.SleepActivity" --ez deactivate true >/dev/null 2>&1 || true
    sleep 2
}

if [ "$MODE" = "uninstall" ]; then
    step "Removing L16 Studio from the camera"
    if installed; then
        release_screen_permission
        adb_s uninstall "$PACKAGE" >/dev/null && say "Removed. Your shots are untouched."
    else
        say "L16 Studio isn't installed on this camera."
    fi
    exit 0
fi

if [ "$MODE" = "replace" ] && installed; then
    step "Removing the existing copy"
    release_screen_permission
    adb_s uninstall "$PACKAGE" >/dev/null || true
fi

step "Installing L16 Studio"
if ! output="$(adb_s install -r "$APK" 2>&1)"; then
    if printf '%s' "$output" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE\|signatures do not match"; then
        fail "the camera already has a copy of L16 Studio from a different build.
       Run this again with --replace to remove that copy first (your shots are not affected)."
    fi
    printf '%s\n' "$output" >&2
    fail "the install didn't complete."
fi
printf '%s' "$output" | grep -q "Success" || { printf '%s\n' "$output" >&2; fail "the install didn't report success."; }

version="$(adb_s shell dumpsys package "$PACKAGE" 2>/dev/null | tr -d '\r' | sed -n 's/.*versionName=//p' | head -1)"
adb_s shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
adb_s shell am start -n "$PACKAGE/.GalleryActivity" >/dev/null 2>&1 || true

step "Done"
say "L16 Studio ${version:-} is installed and open on the camera."
say ""
say "On the camera you'll find it in the app list as \"L16 Studio\":"
say "  - a gallery of your shots, with a full-screen viewer"
say "  - Edit: Auto and six looks, with sliders, saving a copy next to the shot"
say "  - Wi-Fi transfer: serve your shots to L16Studio on a Mac, or to any browser"
say "  - Camera: jumps to Light's own camera app, which still takes the pictures"
say "  - Screen off: a button, and a second icon in the app list, that put the"
say "    camera to sleep (useful if the power button is worn out). The camera"
say "    asks you to allow it the first time."
say ""
say "To remove it later: run this script with --uninstall."
