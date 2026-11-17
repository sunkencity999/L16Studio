#!/bin/bash
# Builds L16Studio with the Swift toolchain and wraps it into L16Studio.app.
# No Xcode project needed; Xcode itself only has to be installed (SwiftUI's
# macros ship with it), not selected or set up.
#
#   scripts/build-app.sh            -> build/L16Studio.app
#   scripts/build-app.sh --install  -> also copies it to /Applications
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP="build/L16Studio.app"
VERSION="0.2.0"

# Command Line Tools alone can't compile SwiftUI; use Xcode's toolchain if it's there.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "==> Building (release)"
swift build -c release --product L16Studio
BIN="$(swift build -c release --show-bin-path)/L16Studio"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/L16Studio"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp L16Studio/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>L16Studio</string>
    <key>CFBundleDisplayName</key><string>L16 Studio</string>
    <key>CFBundleIdentifier</key><string>dev.sunkencity.L16Studio</string>
    <key>CFBundleExecutable</key><string>L16Studio</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Wi-Fi import talks plain HTTP to the camera on the local network. -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>NSLocalNetworkUsageDescription</key><string>L16 Studio looks for your Light L16 on the local network to import shots over Wi-Fi.</string>
    <key>NSBonjourServices</key><array><string>_l16studio._tcp</string></array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>dev.sunkencity.L16Studio.lri</string>
            <key>UTTypeDescription</key><string>Light L16 RAW Image</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key><array><string>lri</string></array>
            </dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Light L16 RAW Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key><array><string>dev.sunkencity.L16Studio.lri</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed; the app may need right-click > Open"
echo "==> Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/L16Studio.app
    cp -R "$APP" /Applications/L16Studio.app
    echo "==> Installed /Applications/L16Studio.app"
fi
