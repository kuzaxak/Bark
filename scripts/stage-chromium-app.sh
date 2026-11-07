#!/bin/bash
# Stage an Intel candidate around the stock allocator-safe Chromium executable.
# Sign the staged bundle through Chromium's signing flow before execution.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo 'usage: bash scripts/stage-chromium-app.sh <Chromium.app> <native-products-directory> <new-output.app>' >&2
  exit 2
fi
ENGINE="$1"
PRODUCTS="$2"
OUTPUT="$3"
NATIVE_FRAMEWORK="$PRODUCTS/NookNativeShell.framework"
NATIVE="$NATIVE_FRAMEWORK/Versions/A/NookNativeShell"
[[ ! -e "$OUTPUT" ]] || { echo 'Output already exists; refusing replacement' >&2; exit 1; }
[[ -d "$ENGINE/Contents/Frameworks/Chromium Framework.framework" ]] || { echo 'Missing Chromium framework' >&2; exit 1; }
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
ENGINE_EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ENGINE/Contents/Info.plist")
# An old stock launcher would ignore the app's isolation arguments. Reject it
# rather than staging a library it would never invoke. Runtime qualification
# still requires the reviewed engine source/artifact provenance.
BOOTSTRAP_STRINGS=$(/usr/bin/strings "$ENGINE/Contents/MacOS/$ENGINE_EXEC")
[[ "$BOOTSTRAP_STRINGS" == *"NookNativeShell.framework/Versions/A/NookNativeShell"* && "$BOOTSTRAP_STRINGS" == *"barc_native_main"* ]] || {
  echo 'Engine executable lacks the required native bootstrap' >&2; exit 1;
}
/usr/bin/lipo "$NATIVE" -verify_arch x86_64
/usr/bin/otool -hv "$NATIVE" | /usr/bin/grep -q DYLIB || { echo 'Native shell must be a dylib, not an executable' >&2; exit 1; }
/usr/bin/lipo "$ENGINE/Contents/Frameworks/Chromium Framework.framework/Chromium Framework" -verify_arch x86_64
# Preserve stock executable, helper bootstraps, framework versions and metadata.
/usr/bin/ditto "$ENGINE" "$OUTPUT"
# Xcode/SPM dependencies and resources retain their existing names. Refuse
# collisions rather than replacing engine-owned files or guessing precedence.
for framework in "$PRODUCTS/"*.framework "$PRODUCTS/PackageFrameworks/"*.framework; do
  [[ -d "$framework" ]] || continue
  name=$(basename "$framework")
  [[ ! -e "$OUTPUT/Contents/Frameworks/$name" ]] || { echo "Framework collision: $name" >&2; exit 1; }
  /usr/bin/ditto "$framework" "$OUTPUT/Contents/Frameworks/$name"
done
# Native catalogs and Metal libraries live inside NookNativeShell.framework.
# Never overwrite Chromium's catalog with loose native build products.
for resource in "$PRODUCTS/"*.bundle; do
  [[ -e "$resource" ]] || continue
  name=$(basename "$resource")
  [[ ! -e "$OUTPUT/Contents/Resources/$name" ]] || { echo "Resource collision: $name" >&2; exit 1; }
  /usr/bin/ditto "$resource" "$OUTPUT/Contents/Resources/$name"
done
printf '%s\n' "Staged unsigned candidate: $OUTPUT" 'Chromium signing is required before launch; no signing was performed.'
