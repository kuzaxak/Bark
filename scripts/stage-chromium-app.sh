#!/bin/bash
# Stage an Intel candidate: the app target's Bark.app with the published engine framework inside it.
# Sign the staged bundle through Chromium's signing flow before execution.
set -euo pipefail
if [[ $# != 4 ]]; then
  echo 'usage: bash scripts/stage-chromium-app.sh <app-target Bark.app> <engine artifact directory> <native-products-directory> <new-output.app>' >&2
  exit 2
fi
APP="$1"
ARTIFACT="$2"
PRODUCTS="$3"
OUTPUT="$4"
refuse() { echo "$1" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
archs_are_x86_64() { [[ $(/usr/bin/lipo -archs "$1" 2>/dev/null || true) == x86_64 ]] || refuse "Binary must be exactly x86_64: $1"; }
zone_names() { /usr/bin/strings -a "$1" | /usr/bin/grep -xE '[A-Za-z]*Delegating[A-Za-z]*Zone[A-Za-z]*' | /usr/bin/sort -u || true; }
ENGINE_FRAMEWORK_NAME='Bark Framework.framework'
ENGINE_FRAMEWORK="$ARTIFACT/$ENGINE_FRAMEWORK_NAME"
ENGINE_INFO="$ARTIFACT/engine-Info.plist"
ENGINE_PIN="$PRODUCTS/include/BarcChromium/engine-artifact.sha256"
APP_INFO="$APP/Contents/Info.plist"
APP_MAIN="$APP/Contents/MacOS/Bark"
APP_RESOURCES="$APP/Contents/Resources"
NATIVE_FRAMEWORK="$PRODUCTS/NookNativeShell.framework"
NATIVE="$NATIVE_FRAMEWORK/Versions/A/NookNativeShell"
[[ ! -e "$OUTPUT" ]] || refuse 'Output already exists; refusing replacement'

[[ -d "$ENGINE_FRAMEWORK" ]] || refuse 'Missing Bark framework'
LISTED=$(/usr/bin/awk '{ sub(/^[0-9a-f]+  /, ""); print }' "$ARTIFACT/SHA256SUMS" 2>/dev/null | /usr/bin/sort || true)
PRESENT=$(cd "$ARTIFACT" && /usr/bin/find . -type f ! -name SHA256SUMS | /usr/bin/sort)
{ [[ -n "$LISTED" && "$LISTED" == "$PRESENT" ]] && (cd "$ARTIFACT" && /usr/bin/shasum -a 256 --check --quiet SHA256SUMS >/dev/null 2>&1); } ||
  refuse "Engine artifact does not match its SHA256SUMS: $ARTIFACT"
ARTIFACT_SHA=$(cd "$ARTIFACT" && /usr/bin/shasum -a 256 SHA256SUMS | /usr/bin/cut -d' ' -f1)
[[ -f "$ENGINE_PIN" && $(<"$ENGINE_PIN") == "$ARTIFACT_SHA" ]] || refuse 'App was built against another engine artifact'
# The bridge's structs cross without a size argument, so a layout change with no version bump only shows here.
for header in barc_bridge_api.h barc_runtime_startup_api.h barc_page_tweaks.h; do
  /usr/bin/cmp -s "$ARTIFACT/Headers/$header" "$PRODUCTS/include/BarcChromium/$header" ||
    refuse "App was compiled against another $header than the engine's: $ARTIFACT/Headers/$header"
done

[[ -f "$APP_MAIN" && $(plist "$APP_INFO" CFBundleExecutable) == Bark ]] || refuse 'Missing app target executable'
[[ ! -e "$APP/Contents/_CodeSignature" ]] || refuse 'App already has a code signature: build it with CODE_SIGNING_ALLOWED=NO'
[[ $(plist "$APP_INFO" CFBundleIdentifier) == ee.qdo.bark ]] || refuse 'App bundle identifier must be exactly ee.qdo.bark'
[[ $(plist "$APP_INFO" NSPrincipalClass) == BrowserCrApplication ]] ||
  refuse 'App principal class must be BrowserCrApplication: Chromium owns NSApplication'
python3 - "$APP_INFO" "$ENGINE_INFO" <<'PY' || exit 1
import plistlib, sys
app, engine = (plistlib.load(open(path, 'rb')) for path in sys.argv[1:3])
ignored = lambda key: key.startswith('DT') or key in ('BuildMachineOSBuild', 'CFBundleSupportedPlatforms')
differing = sorted(key for key in app.keys() | engine.keys() if not ignored(key) and app.get(key) != engine.get(key))
if differing:
    sys.exit('ChromiumApp/Info.plist differs from the engine: ' + ', '.join(differing))
PY
for resource in app.icns Assets.car scripting.sdef en.lproj/InfoPlist.strings; do
  [[ -f "$APP_RESOURCES/$resource" ]] || refuse "Missing outer resource: $resource"
done

[[ -f "$NATIVE" ]] || refuse 'Missing versioned native shell framework executable'
[[ -f "$NATIVE_FRAMEWORK/Versions/A/Resources/Assets.car" ]] || refuse 'Missing framework-owned native asset catalog'
[[ -f "$NATIVE_FRAMEWORK/Versions/A/Resources/default.metallib" ]] || refuse 'Missing framework-owned native Metal library'
NATIVE_INFO="$NATIVE_FRAMEWORK/Versions/A/Resources/Info.plist"
[[ -f "$NATIVE_INFO" ]] || refuse 'Missing native framework Info.plist'
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$NATIVE_INFO") == FMWK &&
   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$NATIVE_INFO") == NookNativeShell &&
   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NATIVE_INFO") == ee.qdo.nook.NativeShell ]] ||
  refuse 'Unexpected native framework identity'
APP_STRINGS=$(/usr/bin/strings -a "$APP_MAIN")
[[ "$APP_STRINGS" == *"NookNativeShell.framework/Versions/A/NookNativeShell"* && "$APP_STRINGS" == *"barc_native_main"* ]] ||
  refuse 'App executable lacks the required native bootstrap'
ENGINE_VERSION=$(plist "$ENGINE_INFO" CFBundleShortVersionString)
[[ "$APP_STRINGS" == *"$ENGINE_FRAMEWORK_NAME/Versions/$ENGINE_VERSION/Bark Framework"* ]] ||
  refuse 'App executable was built for another engine version'
ENGINE_BINARY="$ENGINE_FRAMEWORK/Versions/$ENGINE_VERSION/Bark Framework"
[[ -f "$ENGINE_BINARY" ]] || refuse "Missing versioned engine executable: $ENGINE_BINARY"
[[ $(/usr/bin/readlink "$ENGINE_FRAMEWORK/Versions/Current") == "$ENGINE_VERSION" ]] ||
  refuse "Versions/Current must point to $ENGINE_VERSION"
[[ $(plist "$ENGINE_FRAMEWORK/Versions/$ENGINE_VERSION/Resources/Info.plist" CFBundleShortVersionString) == "$ENGINE_VERSION" ]] ||
  refuse "Framework CFBundleShortVersionString must match the app's $ENGINE_VERSION"
# The zone registration in main must run before any other library can start a thread.
[[ $(/usr/bin/otool -L "$APP_MAIN" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}') == /usr/lib/libSystem.B.dylib ]] ||
  refuse 'App executable must link only libSystem'
archs_are_x86_64 "$APP_MAIN"
archs_are_x86_64 "$NATIVE"
archs_are_x86_64 "$ENGINE_BINARY"
/usr/bin/otool -hv "$NATIVE" | /usr/bin/grep -q DYLIB || refuse 'Native shell must be a dylib, not an executable'
# A framework that does not recognize main's zone falls into its later, racy registration without an error.
MAIN_ZONE=$(zone_names "$APP_MAIN")
[[ -n "$MAIN_ZONE" && "$MAIN_ZONE" == "$(zone_names "$ENGINE_BINARY")" ]] ||
  refuse 'App executable and framework must use the same malloc zone name'
ENGINE_EXPORTS=$(/usr/bin/nm -gjU "$ENGINE_BINARY")
for binary in "$APP_MAIN" "$NATIVE"; do
  ENTRY=$(/usr/bin/strings -a "$binary" | /usr/bin/grep -oE 'barc_engine_main_v[0-9]+' | /usr/bin/sort -u || true)
  [[ -n "$ENTRY" && "$ENTRY" != *$'\n'* ]] || refuse "Binary must name exactly one versioned engine entry: $binary"
  /usr/bin/grep -x "_$ENTRY" <<<"$ENGINE_EXPORTS" > /dev/null ||
    refuse "Engine does not export $ENTRY, which this binary enters: built for another bridge version: $binary"
done
/usr/bin/ditto "$APP" "$OUTPUT"
/bin/mkdir -p "$OUTPUT/Contents/Frameworks"
# Xcode/SPM dependencies and resources retain their existing names. Refuse
# collisions rather than replacing engine-owned files or guessing precedence.
for framework in "$ENGINE_FRAMEWORK" "$PRODUCTS/"*.framework "$PRODUCTS/PackageFrameworks/"*.framework; do
  [[ -d "$framework" ]] || continue
  name=$(basename "$framework")
  [[ ! -e "$OUTPUT/Contents/Frameworks/$name" ]] || { /bin/rm -rf "$OUTPUT"; refuse "Framework collision: $name"; }
  /usr/bin/ditto "$framework" "$OUTPUT/Contents/Frameworks/$name"
  # The engine artifact is read-only and signing rewrites what is staged from it.
  /bin/chmod -R u+w "$OUTPUT/Contents/Frameworks/$name"
done
# Native catalogs and Metal libraries live inside NookNativeShell.framework.
for resource in "$PRODUCTS/"*.bundle; do
  [[ -e "$resource" ]] || continue
  name=$(basename "$resource")
  [[ ! -e "$OUTPUT/Contents/Resources/$name" ]] || { /bin/rm -rf "$OUTPUT"; refuse "Resource collision: $name"; }
  /usr/bin/ditto "$resource" "$OUTPUT/Contents/Resources/$name"
done
printf '%s\n' "Staged unsigned candidate: $OUTPUT" 'Chromium signing is required before launch; no signing was performed.'
