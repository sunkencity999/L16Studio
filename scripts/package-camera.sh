#!/bin/bash
# Builds the on-camera app and packs it, with the installers, into a zip that
# can be handed to anyone with an L16:
#
#   scripts/package-camera.sh  ->  build/L16Studio-camera-<version>.zip
#
# The APK is signed with camera-app/dev.keystore (created on first build, not
# in git). Keep that file: an update only installs over an earlier copy if it
# is signed with the same key.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

camera-app/build.sh
VERSION="$(sed -n 's/.*android:versionName="\([^"]*\)".*/\1/p' camera-app/AndroidManifest.xml | head -1)"
[ -n "$VERSION" ] || { echo "error: no versionName found in the manifest" >&2; exit 1; }
NAME="L16Studio-camera-$VERSION"
STAGE="build/$NAME"

rm -rf "$STAGE" "build/$NAME.zip"
mkdir -p "$STAGE"
cp camera-app/build/l16studio.apk "$STAGE/l16studio.apk"
cp deploy/install.sh deploy/install.command deploy/install.ps1 deploy/install.bat deploy/README.txt "$STAGE/"
cp LICENSE "$STAGE/LICENSE.txt"
chmod +x "$STAGE/install.sh" "$STAGE/install.command"

# -X leaves out macOS-only extra attributes; execute bits are kept.
(cd build && zip -q -r -X "$NAME.zip" "$NAME")
echo "==> Packed build/$NAME.zip ($(du -h "build/$NAME.zip" | cut -f1 | tr -d ' '))"
unzip -l "build/$NAME.zip" | sed -n '4,$p' | sed '$d' | sed '$d' | awk '{print "    " $4 "  (" $1 " bytes)"}'
