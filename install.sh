#!/bin/bash
# Builds L16Studio, installs it to /Applications, and installs a CLI launcher.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="L16Studio"
CLI_NAME="l16studio"
CLI_DIRS=("/opt/homebrew/bin" "/usr/local/bin" "$HOME/.local/bin")

echo "==> Checking prerequisites"

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: full Xcode isn't active (only Command Line Tools?)." >&2
    echo "  Install Xcode from the App Store, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  sudo xcodebuild -license accept" >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "==> Installing xcodegen (via Homebrew)"
        brew install xcodegen
    else
        echo "error: xcodegen not found and Homebrew isn't installed." >&2
        echo "  Install Homebrew (https://brew.sh) or xcodegen manually, then re-run." >&2
        exit 1
    fi
fi

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $APP_NAME (Release)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release build

BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "${APP_NAME}-*" -print -quit)/Build/Products/Release/$APP_NAME.app
if [ ! -d "$BUILT_APP" ]; then
    echo "error: couldn't find the built app at expected path: $BUILT_APP" >&2
    exit 1
fi

echo "==> Installing $APP_NAME.app to /Applications"
rm -rf "/Applications/$APP_NAME.app"
cp -R "$BUILT_APP" "/Applications/$APP_NAME.app"
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true

echo "==> Installing CLI launcher ('$CLI_NAME')"
CLI_INSTALLED=""
for dir in "${CLI_DIRS[@]}"; do
    if [ -d "$dir" ] && [ -w "$dir" ]; then
        cat > "$dir/$CLI_NAME" << SCRIPT
#!/bin/bash
# Launches L16Studio, optionally opening one or more .lri files passed as arguments.
# Targets the installed app by exact path rather than by name -- 'open -a
# "L16Studio"' can resolve to a stale Debug build if one is still registered
# with Launch Services from a local Xcode build, so this avoids that entirely.
if [ "\$#" -gt 0 ]; then
    exec open -a "/Applications/$APP_NAME.app" "\$@"
else
    exec open -a "/Applications/$APP_NAME.app"
fi
SCRIPT
        chmod +x "$dir/$CLI_NAME"
        CLI_INSTALLED="$dir/$CLI_NAME"
        break
    fi
done

if [ -z "$CLI_INSTALLED" ]; then
    echo "warning: couldn't find a writable directory on PATH for the CLI launcher." >&2
    echo "  Create one (e.g. mkdir -p ~/.local/bin, add it to PATH) and re-run this script." >&2
else
    echo "==> Installed CLI launcher: $CLI_INSTALLED"
fi

echo ""
echo "Done. Launch L16Studio from Spotlight/Finder, or from the terminal with:"
echo "  $CLI_NAME"
echo "  $CLI_NAME path/to/photo.lri"
