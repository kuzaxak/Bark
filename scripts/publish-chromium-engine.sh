#!/bin/bash
# Publishes an engine build as the local binary artifact of the BarkEngine package: the framework, its
# signing tools, the engine's Info.plist, the public headers it was built from and a checksum list, plus
# copies of those headers and the list's SHA for the app to compile against. The app never links the
# framework: main opens it after registering the malloc zone, and staging copies it from here. The
# headers and the SHA are committed; the artifact stays local until uploads exist. Needs depot_tools on PATH.
set -euo pipefail
ARCH=
REPLACE=false
REQUIRE_OFFICIAL=false
WORK=
if [[ ${1:-} == --prepare ]]; then
  WORK=$2
  ARTIFACT=$3
  shift 3
fi
while [[ $# -gt 0 ]]; do
  case $1 in
    --arch)
      ARCH=${2:-}
      [[ $ARCH == x86_64 || $ARCH == arm64 ]] || { echo 'Expected --arch x86_64 or arm64' >&2; exit 2; }
      shift 2 ;;
    --replace) REPLACE=true; shift ;;
    --require-official) REQUIRE_OFFICIAL=true; shift ;;
    *) break ;;
  esac
done
if [[ $# != 2 ]]; then
  echo 'usage: bash scripts/publish-chromium-engine.sh [--arch x86_64|arm64] [--replace] [--require-official] <engine build directory> <BarkEngine package directory>' >&2
  exit 2
fi
BUILD="$1"
PACKAGE="$2"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCH=${ARCH:-$(python3 -B "$ROOT/scripts/chromium_sdk_layout.py" native-arch)}
refuse() { echo "$1" >&2; exit 1; }
OFFICIAL_RECEIPT="$BUILD/official-build.json"
if [[ $REQUIRE_OFFICIAL == true && ( ! -f "$OFFICIAL_RECEIPT" || -L "$OFFICIAL_RECEIPT" ) ]]; then
  refuse "No official Bark SDK build receipt: $OFFICIAL_RECEIPT. Build with --official and publish its -official output."
fi
if [[ -z $WORK ]]; then
  exec python3 -B "$ROOT/scripts/publish_chromium_sdk.py" "$PACKAGE" "$ARCH" "$REPLACE" "$BUILD" "$ROOT/scripts/publish-chromium-engine.sh" "$REQUIRE_OFFICIAL"
fi
BRIDGE="$ROOT/Runtime/Chromium/bark/bridge"
PUBLIC_HEADERS=(barc_bridge_api.h)
ENGINE_APP="$BUILD/Bark.app"
INTEGRATED_APP_INFO="$BUILD/gen/chrome/chrome_integrated_app_info_plist.plist"
FRAMEWORK_NAME='Bark Framework.framework'
FRAMEWORK="$ENGINE_APP/Contents/Frameworks/$FRAMEWORK_NAME"
[[ ! -e "$ARTIFACT" && ! -L "$ARTIFACT" ]] || refuse "SDK preparation directory already used: $ARTIFACT"
[[ -d "$FRAMEWORK" ]] || refuse 'Missing Bark framework'
[[ -d "$BUILD/Bark Packaging" ]] || refuse 'Missing Bark Packaging'
[[ -f "$INTEGRATED_APP_INFO" ]] || refuse 'Missing generated metadata for the integrated Bark app'
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INTEGRATED_APP_INFO")
BINARY="$FRAMEWORK/Versions/$VERSION/Bark Framework"
[[ -f "$BINARY" ]] || refuse 'Missing versioned engine executable'
[[ $(/usr/bin/lipo -archs "$BINARY") == "$ARCH" ]] || refuse "Engine must be exactly $ARCH: $BINARY"
python3 -B "$ROOT/scripts/check-chromium-architectures.py" --arch "$ARCH" \
  --engine-info "$INTEGRATED_APP_INFO" "$FRAMEWORK"
ENTRY=$(/usr/bin/sed -nE 's/^#define BARC_ENGINE_MAIN_SYMBOL "(.*)"$/\1/p' "$BRIDGE/barc_bridge_api.h")
TABLE=$(/usr/bin/sed -nE 's/^#define BARC_BRIDGE_SYMBOL "(.*)"$/\1/p' "$BRIDGE/barc_bridge_api.h")
EXPORTS=$(/usr/bin/nm -gjU "$BINARY")
/usr/bin/grep -x "_$ENTRY" <<<"$EXPORTS" > /dev/null || refuse "Engine does not export $ENTRY"
/usr/bin/grep -x "_$TABLE" <<<"$EXPORTS" > /dev/null || refuse "Engine does not export $TABLE"
/usr/bin/grep -x _barc_public_headers_sha256 <<<"$EXPORTS" > /dev/null || refuse 'Engine does not export barc_public_headers_sha256'
python3 -B - "$ROOT/Runtime/Chromium" "$BINARY" "$ARCH" <<'PYTHON' || exit 1
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from run_browser_tests import require_host_only_image
try:
    require_host_only_image(Path(sys.argv[2]), sys.argv[3])
except ValueError as error:
    sys.exit(str(error))
PYTHON
# The source tree can move on after a build, so siso's record of each input is the evidence of what the
# engine compiled. It keeps the digest from the last build that read the file.
BUILD_RECORD="$WORK/build-record.json"
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
# The app target owns outer artwork and specific display text. Keep all other
# localized values, scripting API declarations and resource bytes in parity.
if ! python3 -B - "$ENGINE_APP/Contents/Resources" "$ROOT/ChromiumApp/Resources" \
    "$INTEGRATED_APP_INFO" "$ROOT/ChromiumApp/Info.plist" "$ROOT/ChromiumApp/Additions.plist" <<'PYTHON'
from pathlib import Path
import plistlib
import subprocess
import sys

engine, app = map(Path, sys.argv[1:3])
engine_info, app_info, additions = map(Path, sys.argv[3:])
visible_names = {"CFBundleName", "CFBundleDisplayName", "CFBundleGetInfoString"}


def read_info(path):
    return plistlib.loads(path.read_bytes())


def artwork(info, resources, additional_documents=()):
    icons = [info.get("CFBundleIconFile")]
    icons += [entry.get("CFBundleTypeIconFile")
              for entry in [*info.get("CFBundleDocumentTypes", ()), *additional_documents]]
    names = {"Assets.car"} if "CFBundleIconName" in info else set()
    for icon in icons:
        if icon is None:
            continue
        if not isinstance(icon, str) or not icon or "/" in icon or icon in {".", ".."}:
            raise ValueError(f"Invalid bundle icon basename: {icon!r}")
        if not Path(icon).suffix and not (resources / icon).is_file():
            names.add(icon + ".icns")
        else:
            names.add(icon)
    return names


def read_strings(path):
    xml = subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", path])
    values = plistlib.loads(xml)
    if not isinstance(values, dict):
        raise ValueError(f"Expected a localized Info.plist dictionary: {path}")
    return values


def compare_strings(source, destination, locale):
    if source.read_bytes() == destination.read_bytes():
        return
    original, branded = read_strings(source), read_strings(destination)
    for key in sorted((original.keys() | branded.keys()) - visible_names):
        if (locale == "hr.lproj" and key == "Chromium Shortcut"
                and original.get(key) == "Prečac za Chrome"
                and branded.get(key) == "Prečac za Chromium"):
            continue
        if key not in original or key not in branded or original[key] != branded[key]:
            raise ValueError(f"Localized Info.plist value differs for {key}: {destination}")
    for key in visible_names & branded.keys():
        if not isinstance(branded[key], str) or not branded[key].strip():
            raise ValueError(f"Invalid localized app name for {key}: {destination}")


def compare_scripting(source, destination):
    original, branded = source.read_bytes(), destination.read_bytes()
    chrome = b'<suite name="Chromium Suite" code="CrSu" description="Common classes and commands for Chrome.">'
    bark = chrome.replace(b"for Chrome.", b"for Bark.")
    if original == branded or (original.count(chrome) == 1 and original.replace(chrome, bark) == branded):
        return
    raise ValueError(f"Outer scripting dictionary differs beyond the Chromium Suite description: {destination}")


def compare_directory(source, destination, *, outer_artwork=None, locale=None):
    names = {item.name for item in source.iterdir()}
    other_names = {item.name for item in destination.iterdir()}
    if outer_artwork is not None:
        source_icons, destination_icons = outer_artwork
        names -= source_icons
        other_names -= destination_icons
    mismatched = sorted(names ^ other_names)
    if mismatched:
        raise ValueError(f"Outer resources present only in one bundle at {destination}: {', '.join(mismatched)}")
    for name in sorted(names):
        left, right = source / name, destination / name
        if outer_artwork is not None and name.endswith(".lproj") and left.is_dir() and right.is_dir():
            compare_directory(left, right, locale=name)
        elif locale and name == "InfoPlist.strings" and left.is_file() and right.is_file():
            compare_strings(left, right, locale)
        elif outer_artwork is not None and name == "scripting.sdef" and left.is_file() and right.is_file():
            compare_scripting(left, right)
        else:
            subprocess.run(["/usr/bin/diff", "-r", left, right], stdout=sys.stderr, check=True)


try:
    added_info = read_info(additions).get("Info", {}) if additions.is_file() else {}
    compare_directory(engine, app, outer_artwork=(
        artwork(read_info(engine_info), engine),
        artwork(read_info(app_info), app, added_info.get("CFBundleDocumentTypes", ())),
    ))
except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
    sys.exit(str(error))
PYTHON
then
  refuse 'Engine outer resources differ from ChromiumApp/Resources: review the difference and update the app'
fi
if [[ -e "$OFFICIAL_RECEIPT" || -L "$OFFICIAL_RECEIPT" ]]; then
  python3 -B "$ROOT/Runtime/Chromium/official_provenance.py" "$BUILD" "$ARCH"
fi
/bin/mkdir -p "$ARTIFACT/Headers"
/usr/bin/ditto "$FRAMEWORK" "$ARTIFACT/$FRAMEWORK_NAME"
/usr/bin/ditto "$BUILD/Bark Packaging" "$ARTIFACT/Bark Packaging"
/bin/cp "$INTEGRATED_APP_INFO" "$ARTIFACT/engine-Info.plist"
if [[ -f "$OFFICIAL_RECEIPT" ]]; then
  /bin/cp "$OFFICIAL_RECEIPT" "$ARTIFACT/official-build.json"
fi
for header in "${PUBLIC_HEADERS[@]}"; do
  /bin/cp "$BRIDGE/$header" "$ARTIFACT/Headers/$header"
done
python3 "$ROOT/Runtime/Chromium/bark/app/barc_public_headers_sha256.py" "$ARTIFACT/Headers/barc_public_headers_sha256.h" "${PUBLIC_HEADERS[@]/#/$BRIDGE/}"
(cd "$ARTIFACT" && /usr/bin/find . -type f ! -name SHA256SUMS -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256 > SHA256SUMS)
# Python writes bytecode beside the signing tools, and any new file fails the checksums at the next staging.
/bin/chmod -R a-w "$ARTIFACT"
