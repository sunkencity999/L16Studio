#!/bin/bash
# Builds the on-camera L16 Studio app without Gradle: aapt2 -> javac -> d8 ->
# zipalign -> apksigner. Needs a JDK and the Android SDK (platform 23 and
# build-tools):
#
#   brew install openjdk@17
#   brew install --cask android-commandlinetools
#   sdkmanager "platforms;android-23" "build-tools;34.0.0"
#
#   ./build.sh            -> build/l16studio.apk
#   ./build.sh --install  -> also installs it on the camera attached over adb
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${ANDROID_HOME:=/opt/homebrew/share/android-commandlinetools}"
if [ -z "${JAVA_HOME:-}" ]; then
    for candidate in /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home /opt/homebrew/opt/openjdk@17; do
        [ -x "$candidate/bin/javac" ] && JAVA_HOME="$candidate" && break
    done
fi
[ -x "${JAVA_HOME:-}/bin/javac" ] || { echo "error: no JDK found; set JAVA_HOME" >&2; exit 1; }
export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"

TOOLS="$(ls -d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -1)"
PLATFORM="$ANDROID_HOME/platforms/android-23/android.jar"
[ -x "$TOOLS/aapt2" ] && [ -f "$PLATFORM" ] || { echo "error: Android SDK platform 23 / build-tools not found under $ANDROID_HOME" >&2; exit 1; }

OUT=build
rm -rf "$OUT" && mkdir -p "$OUT/res" "$OUT/gen" "$OUT/classes" "$OUT/dex"

echo "==> Resources"
"$TOOLS/aapt2" compile --dir res -o "$OUT/res/compiled.zip"
"$TOOLS/aapt2" link -o "$OUT/base.apk" -I "$PLATFORM" --manifest AndroidManifest.xml --java "$OUT/gen" "$OUT/res/compiled.zip"

echo "==> Java"
javac -source 8 -target 8 -Xlint:-options -nowarn -classpath "$PLATFORM" -d "$OUT/classes" \
    $(find src "$OUT/gen" -name '*.java')

echo "==> Dex"
"$TOOLS/d8" --min-api 23 --lib "$PLATFORM" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -j ../unsigned.apk classes.dex)

echo "==> Sign"
# A development key kept next to the project (not in git). Reusing the same
# key lets a new build install over the old one.
KEYSTORE="${L16_KEYSTORE:-$PWD/dev.keystore}"
if [ ! -f "$KEYSTORE" ]; then
    keytool -genkeypair -keystore "$KEYSTORE" -storepass l16studio -keypass l16studio -alias l16studio \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=L16 Studio development" >/dev/null 2>&1
fi
"$TOOLS/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:l16studio --key-pass pass:l16studio \
    --out "$OUT/l16studio.apk" "$OUT/aligned.apk"
echo "==> Built $OUT/l16studio.apk ($(du -h "$OUT/l16studio.apk" | cut -f1 | tr -d ' '))"

if [ "${1:-}" = "--install" ]; then
    adb install -r "$OUT/l16studio.apk"
fi
