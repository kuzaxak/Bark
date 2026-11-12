#!/bin/bash
# Publishes an engine build as the local binary artifact of the BarkEngine package: the framework, its
# signing tools, the engine's Info.plist, the public headers it was built from and a checksum list, plus
# copies of those headers and the list's SHA for the app to compile against. The app never links the
# framework: main opens it after registering the malloc zone, and staging copies it from here. The
# headers and the SHA are committed; the artifact stays local until uploads exist. Needs depot_tools on PATH.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'usage: bash scripts/publish-chromium-engine.sh <engine build directory> <BarkEngine package directory>' >&2
  exit 2
fi
BUILD="$1"
PACKAGE="$2"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BRIDGE="$ROOT/Runtime/Chromium/bark/bridge"
refuse() { echo "$1" >&2; exit 1; }
PUBLIC_HEADERS=(barc_bridge_api.h)
ENGINE_APP="$BUILD/Bark.app"
FRAMEWORK_NAME='Bark Framework.framework'
FRAMEWORK="$ENGINE_APP/Contents/Frameworks/$FRAMEWORK_NAME"
SLICE="$PACKAGE/BarkEngine.xcframework/macos-x86_64"
ARTIFACT="$SLICE/Engine"
[[ ! -e "$ARTIFACT" ]] || refuse "Engine artifact already published, read-only: chmod -R u+w and remove it first: $ARTIFACT"
[[ -d "$FRAMEWORK" ]] || refuse 'Missing Bark framework'
[[ -d "$BUILD/Bark Packaging" ]] || refuse 'Missing Bark Packaging'
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ENGINE_APP/Contents/Info.plist")
BINARY="$FRAMEWORK/Versions/$VERSION/Bark Framework"
[[ -f "$BINARY" ]] || refuse 'Missing versioned engine executable'
[[ $(/usr/bin/lipo -archs "$BINARY") == x86_64 ]] || refuse "Engine must be exactly x86_64: $BINARY"
ENTRY=$(/usr/bin/sed -nE 's/^#define BARC_ENGINE_MAIN_SYMBOL "(.*)"$/\1/p' "$BRIDGE/barc_bridge_api.h")
TABLE=$(/usr/bin/sed -nE 's/^#define BARC_BRIDGE_SYMBOL "(.*)"$/\1/p' "$BRIDGE/barc_bridge_api.h")
EXPORTS=$(/usr/bin/nm -gjU "$BINARY")
/usr/bin/grep -x "_$ENTRY" <<<"$EXPORTS" > /dev/null || refuse "Engine does not export $ENTRY"
/usr/bin/grep -x "_$TABLE" <<<"$EXPORTS" > /dev/null || refuse "Engine does not export $TABLE"
/usr/bin/grep -x _barc_public_headers_sha256 <<<"$EXPORTS" > /dev/null || refuse 'Engine does not export barc_public_headers_sha256'
# The source tree can move on after a build, so siso's record of each input is the evidence of what the
# engine compiled. It keeps the digest from the last build that read the file.
BUILD_RECORD=$(/usr/bin/mktemp)
trap '/bin/rm -f "$BUILD_RECORD"' EXIT
siso fs export -C "$BUILD" > "$BUILD_RECORD" 2>/dev/null || refuse 'Cannot read the build record: siso fs export failed. Is depot_tools on PATH?'
python3 - "$BUILD_RECORD" "$(cd "$BUILD/../.." && pwd -P)" "$BINARY" "$BRIDGE" <<'PY' || exit 1
import hashlib, json, os, sys
record, source, binary, runtime = sys.argv[1:5]
entries = {entry.get('name'): entry for entry in json.load(open(record)).get('entries', [])}
linked = os.stat(binary).st_mtime_ns
directories = {'barc_bridge_api.h': 'bark/bridge'}
for name, directory in directories.items():
    entry = entries.get(f'{source}/{directory}/{name}', {})
    built_from = entry.get('digest', {}).get('hash')
    if not built_from:
        sys.exit(f'No build record of {name}: cannot tell what the engine was built from')
    if int(entry['id']['mod_time']) > linked:
        sys.exit(f'{name} changed after the engine was linked: rebuild the engine')
    if built_from != hashlib.sha256(open(f'{runtime}/{name}', 'rb').read()).hexdigest():
        sys.exit(f'Engine was built from another {name} than Runtime/Chromium/bark: rebuild it or update the recipe')
PY
/usr/bin/diff -r "$ENGINE_APP/Contents/Resources" "$ROOT/ChromiumApp/Resources" >&2 ||
  refuse 'Engine outer resources differ from ChromiumApp/Resources: review the difference and update the app'
/bin/mkdir -p "$ARTIFACT/Headers" "$SLICE/Headers/BarcChromium"
/usr/bin/ditto "$FRAMEWORK" "$ARTIFACT/$FRAMEWORK_NAME"
/usr/bin/ditto "$BUILD/Bark Packaging" "$ARTIFACT/Bark Packaging"
/bin/cp "$ENGINE_APP/Contents/Info.plist" "$ARTIFACT/engine-Info.plist"
for header in "${PUBLIC_HEADERS[@]}"; do
  /bin/cp "$BRIDGE/$header" "$ARTIFACT/Headers/$header"
  /bin/cp "$BRIDGE/$header" "$SLICE/Headers/BarcChromium/$header"
done
python3 "$ROOT/Runtime/Chromium/bark/app/barc_public_headers_sha256.py" "$ARTIFACT/Headers/barc_public_headers_sha256.h" "${PUBLIC_HEADERS[@]/#/$BRIDGE/}"
/bin/cp "$ARTIFACT/Headers/barc_public_headers_sha256.h" "$SLICE/Headers/BarcChromium/barc_public_headers_sha256.h"
(cd "$ARTIFACT" && /usr/bin/find . -type f ! -name SHA256SUMS -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256 > SHA256SUMS)
(cd "$ARTIFACT" && /usr/bin/shasum -a 256 SHA256SUMS | /usr/bin/cut -d' ' -f1) > "$SLICE/Headers/BarcChromium/engine-artifact.sha256"
# Python writes bytecode beside the signing tools, and any new file fails the checksums at the next staging.
/bin/chmod -R a-w "$ARTIFACT"
printf '%s\n' "Published engine $VERSION: $ARTIFACT" "Artifact SHA: $(cat "$SLICE/Headers/BarcChromium/engine-artifact.sha256")"
