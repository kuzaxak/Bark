#!/bin/bash
# Stage an Intel candidate: the app target's Bark.app with the engine framework inside it.
# Sign the staged bundle through Chromium's signing flow before execution.
set -euo pipefail
if [[ $# != 4 ]]; then
  echo 'usage: bash scripts/stage-chromium-app.sh <app-target Bark.app> <engine Bark.app> <native-products-directory> <new-output.app>' >&2
  exit 2
fi
APP="$1"
ENGINE="$2"
PRODUCTS="$3"
OUTPUT="$4"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
ENGINE_FRAMEWORK_NAME='Bark Framework.framework'
ENGINE_FRAMEWORK="$ENGINE/Contents/Frameworks/$ENGINE_FRAMEWORK_NAME"
APP_INFO="$APP/Contents/Info.plist"
APP_MAIN="$APP/Contents/MacOS/Bark"
NATIVE_FRAMEWORK="$PRODUCTS/NookNativeShell.framework"
NATIVE="$NATIVE_FRAMEWORK/Versions/A/NookNativeShell"
[[ ! -e "$OUTPUT" ]] || { echo 'Output already exists; refusing replacement' >&2; exit 1; }
[[ -d "$ENGINE_FRAMEWORK" ]] || { echo 'Missing Bark framework' >&2; exit 1; }
[[ -f "$APP_MAIN" && $(plist "$APP_INFO" CFBundleExecutable) == Bark ]] || { echo 'Missing app target executable' >&2; exit 1; }
# ee.qdo.nook is the identity of the shipping WebKit app.
[[ $(plist "$APP_INFO" CFBundleIdentifier) != ee.qdo.nook ]] || { echo 'App must not carry the bundle identifier ee.qdo.nook' >&2; exit 1; }
[[ $(plist "$APP_INFO" CFBundleIdentifier) == "$(plist "$ENGINE/Contents/Info.plist" CFBundleIdentifier)" ]] || {
  echo 'App and engine bundle identifiers differ' >&2; exit 1;
}
[[ $(plist "$APP_INFO" NSPrincipalClass) == BrowserCrApplication ]] || {
  echo 'App principal class must be BrowserCrApplication: Chromium owns NSApplication' >&2; exit 1;
}
[[ -f "$NATIVE" ]] || { echo 'Missing versioned native shell framework executable' >&2; exit 1; }
[[ -f "$NATIVE_FRAMEWORK/Versions/A/Resources/Assets.car" ]] || { echo 'Missing framework-owned native asset catalog' >&2; exit 1; }
[[ -f "$NATIVE_FRAMEWORK/Versions/A/Resources/default.metallib" ]] || { echo 'Missing framework-owned native Metal library' >&2; exit 1; }
NATIVE_INFO="$NATIVE_FRAMEWORK/Versions/A/Resources/Info.plist"
[[ -f "$NATIVE_INFO" ]] || { echo 'Missing native framework Info.plist' >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$NATIVE_INFO") == FMWK &&
   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$NATIVE_INFO") == NookNativeShell &&
   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NATIVE_INFO") == ee.qdo.nook.NativeShell ]] || {
  echo 'Unexpected native framework identity' >&2; exit 1;
}
[[ ! -e "$ENGINE/Contents/Frameworks/NookNativeShell.dylib" ]] || { echo 'Engine contains obsolete bare native library' >&2; exit 1; }
APP_STRINGS=$(/usr/bin/strings "$APP_MAIN")
[[ "$APP_STRINGS" == *"NookNativeShell.framework/Versions/A/NookNativeShell"* && "$APP_STRINGS" == *"barc_native_main"* ]] || {
  echo 'App executable lacks the required native bootstrap' >&2; exit 1;
}
ENGINE_VERSION=$(plist "$ENGINE/Contents/Info.plist" CFBundleShortVersionString)
[[ "$APP_STRINGS" == *"$ENGINE_FRAMEWORK_NAME/Versions/$ENGINE_VERSION/Bark Framework"* ]] || {
  echo 'App executable was built for another engine version' >&2; exit 1;
}
# The zone registration in main must run before any other library can start a thread.
[[ $(/usr/bin/otool -L "$APP_MAIN" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}') == /usr/lib/libSystem.B.dylib ]] || {
  echo 'App executable must link only libSystem' >&2; exit 1;
}
/usr/bin/lipo "$APP_MAIN" -verify_arch x86_64
/usr/bin/lipo "$NATIVE" -verify_arch x86_64
/usr/bin/otool -hv "$NATIVE" | /usr/bin/grep -q DYLIB || { echo 'Native shell must be a dylib, not an executable' >&2; exit 1; }
/usr/bin/lipo "$ENGINE_FRAMEWORK/Bark Framework" -verify_arch x86_64
/usr/bin/ditto "$APP" "$OUTPUT"
/bin/mkdir -p "$OUTPUT/Contents/Frameworks" "$OUTPUT/Contents/Resources"
# Xcode/SPM dependencies and resources retain their existing names. Refuse
# collisions rather than replacing engine-owned files or guessing precedence.
for framework in "$ENGINE_FRAMEWORK" "$PRODUCTS/"*.framework "$PRODUCTS/PackageFrameworks/"*.framework; do
  [[ -d "$framework" ]] || continue
  name=$(basename "$framework")
  [[ ! -e "$OUTPUT/Contents/Frameworks/$name" ]] || { echo "Framework collision: $name" >&2; exit 1; }
  /usr/bin/ditto "$framework" "$OUTPUT/Contents/Frameworks/$name"
done
# Native catalogs and Metal libraries live inside NookNativeShell.framework.
# Never overwrite Chromium's catalog with loose native build products.
for resource in "$ENGINE/Contents/Resources/"* "$PRODUCTS/"*.bundle; do
  [[ -e "$resource" ]] || continue
  name=$(basename "$resource")
  [[ ! -e "$OUTPUT/Contents/Resources/$name" ]] || { echo "Resource collision: $name" >&2; exit 1; }
  /usr/bin/ditto "$resource" "$OUTPUT/Contents/Resources/$name"
done
printf '%s\n' "Staged unsigned candidate: $OUTPUT" 'Chromium signing is required before launch; no signing was performed.'
