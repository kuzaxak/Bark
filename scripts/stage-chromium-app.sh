#!/bin/bash
# Stage an architecture-specific candidate: the app target's Bark.app with the published engine framework inside it, and
# the engine's Bark Packaging beside it. The app target owns its bundle identity and resources. Supplemental
# Info.plist keys and entitlements are declared in ChromiumApp/Additions.plist and merged here, into the staged Info.plist and the staged
# packaging's app-entitlements.plist.
# Sign the staged bundle through Chromium's signing flow before execution.
# With --check-signed, check a signed candidate instead: one blocker library, no unsigned Mach-O, and
# the engine's entitlements plus the declared additions, nothing else.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEFAULT_ADDITIONS="$REPO/ChromiumApp/Additions.plist"
PACKAGE="$REPO/Packages/BarkEngine"
LAYOUT="$REPO/scripts/chromium_sdk_layout.py"
if [[ ${1:-} == --arch ]]; then
  ARCH=${2:-}
  [[ $ARCH == x86_64 || $ARCH == arm64 ]] || { echo 'Expected --arch x86_64 or arm64' >&2; exit 2; }
  shift 2
else
  ARCH=$(python3 -B "$LAYOUT" native-arch)
fi
ENGINE_HEADERS=$(python3 -B "$LAYOUT" headers "$PACKAGE" "$ARCH")
refuse() { echo "$1" >&2; exit 1; }
require_architecture() {
  python3 -B "$REPO/scripts/check-chromium-architectures.py" --arch "$ARCH" --image "$1"
}
# Chromium's signing covers only the Mach-O files its config names, and codesign --verify --deep --strict
# still passes with an unsigned extra one, so the bundle is walked file by file.
check_bundle() {
  python3 - "$1" "$2" <<'PY' || exit 1
import os, subprocess, sys
bundle, mode = sys.argv[1:3]
MACH_O = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
files = [os.path.join(root, name) for root, _, names in os.walk(bundle) for name in names]
files = [path for path in files if not os.path.islink(path)]
copies = [os.path.relpath(path, bundle) for path in files if os.path.basename(path) == 'libnook_adblock.dylib']
problems = [] if len(copies) == 1 else [f'{bundle} holds {len(copies)} copies of libnook_adblock.dylib, not one: {copies}']
if mode == 'signed':
    for path in files:
        with open(path, 'rb') as handle:
            if handle.read(4) not in MACH_O:
                continue
        if subprocess.run(['/usr/bin/codesign', '--display', path], capture_output=True).returncode:
            problems.append(f'Unsigned Mach-O: {os.path.relpath(path, bundle)}')
sys.exit('\n'.join(problems) or None)
PY
}
check_engine() {
  local artifact="$1" headers="$2" listed present digest header pin
  [[ -d "$artifact/Bark Framework.framework" ]] || refuse 'Missing Bark framework'
  [[ -f "$artifact/Bark Packaging/app-entitlements.plist" ]] || refuse "Missing the engine's app entitlements: $artifact"
  digest=$(/usr/bin/shasum -a 256 "$artifact/SHA256SUMS" | /usr/bin/cut -d' ' -f1) ||
    refuse "Missing engine artifact manifest: $artifact"
  if [[ $headers == "$ENGINE_HEADERS" ]]; then
    pin=$(python3 -B "$LAYOUT" digest "$PACKAGE" "$ARCH") || exit 1
  else
    pin=$(python3 -B "$LAYOUT" digest "$PACKAGE" "$ARCH" "$headers") ||
      refuse 'App was built against another engine artifact'
  fi
  [[ $pin == "$digest" ]] ||
    refuse 'App was built against another engine artifact'
  listed=$(/usr/bin/awk '{ sub(/^[0-9a-f]+  /, ""); print }' "$artifact/SHA256SUMS" | /usr/bin/sort)
  present=$(cd "$artifact" && /usr/bin/find . -type f ! -name SHA256SUMS | /usr/bin/sort)
  { [[ -n "$listed" && "$listed" == "$present" ]] && (cd "$artifact" && /usr/bin/shasum -a 256 --check --quiet SHA256SUMS >/dev/null 2>&1); } ||
    refuse "Engine artifact does not match its SHA256SUMS: $artifact"
  for header in barc_bridge_api.h barc_public_headers_sha256.h; do
    /usr/bin/cmp -s "$artifact/Headers/$header" "$headers/$header" ||
      refuse "App was compiled against another $header than the engine's: $artifact/Headers/$header"
  done
  python3 -B "$REPO/scripts/check-chromium-architectures.py" --arch "$ARCH" \
    --engine-info "$artifact/engine-Info.plist" "$artifact/Bark Framework.framework"
  check_bundle "$artifact/Bark Framework.framework" unsigned
}
# Keep product metadata independent while checking the engine's runtime keys during staging.
check_outer_metadata() {
  python3 - "$@" <<'PYTHON' || exit 1
import plistlib
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
resources = bundle / 'Contents/Resources'
with (bundle / 'Contents/Info.plist').open('rb') as handle:
    app = plistlib.load(handle)

with open(sys.argv[2], 'rb') as handle:
    engine = plistlib.load(handle)
engine_version = engine['CFBundleShortVersionString']
app_engine_version = app.get('BarkChromiumVersion', app.get('CFBundleShortVersionString'))
if app_engine_version != engine_version:
    sys.exit(f'App engine version {app_engine_version!r} must match the pinned engine {engine_version!r}')

if len(sys.argv) == 4 and sys.argv[3] == 'source':
    app_owned = {
        'CFBundleDisplayName', 'CFBundleName', 'CFBundleGetInfoString',
        'CFBundleIconFile', 'CFBundleIconName',
        'CFBundleShortVersionString', 'CFBundleVersion', 'BarkChromiumVersion',
        'CFBundleDocumentTypes', 'CFBundleURLTypes', 'NSUserActivityTypes',
        'UTImportedTypeDeclarations', 'UTExportedTypeDeclarations',
    }
    xcode = {'BuildMachineOSBuild', 'CFBundleSupportedPlatforms'}
    differing = sorted(
        key for key in app.keys() | engine.keys()
        if key not in app_owned | xcode and not key.startswith('DT')
        and app.get(key) != engine.get(key)
    )
    if differing:
        sys.exit('ChromiumApp/Info.plist differs from the engine runtime metadata: ' + ', '.join(differing))

def require_resource(name, key, *, icns_fallback=False):
    if not isinstance(name, str) or not name or name in ('.', '..') or '/' in name:
        sys.exit(f'Invalid outer resource name in {key}: {name!r}')
    candidates = [resources / name]
    if icns_fallback and not Path(name).suffix:
        candidates.append(resources / f'{name}.icns')
    if not any(path.is_file() and path.resolve().is_relative_to(resources.resolve()) for path in candidates):
        sys.exit(f'Missing outer resource declared by {key}: {name}')

if 'CFBundleIconFile' in app:
    require_resource(app['CFBundleIconFile'], 'CFBundleIconFile', icns_fallback=True)
if 'CFBundleIconName' in app:
    require_resource('Assets.car', 'CFBundleIconName')
for document_type in app.get('CFBundleDocumentTypes', []):
    if 'CFBundleTypeIconFile' in document_type:
        require_resource(document_type['CFBundleTypeIconFile'], 'CFBundleTypeIconFile', icns_fallback=True)
if 'OSAScriptingDefinition' in app:
    require_resource(app['OSAScriptingDefinition'], 'OSAScriptingDefinition')
if not (resources / 'en.lproj/InfoPlist.strings').is_file():
    sys.exit('Missing outer resource: en.lproj/InfoPlist.strings')
PYTHON
}
# Supplemental Info entries are merged with the app's plist. Entitlement additions are
# validated against the engine's signing configuration.
additions() {
  python3 - "$@" <<'PY' || exit 1
import os, plistlib, subprocess, sys
mode, path = sys.argv[1:3]
def load(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'rb') as handle:
            return plistlib.load(handle)
    except Exception as error:
        sys.exit(f'Cannot read {path}: {error}')
listed = load(path)
other = sorted(set(listed) - {'Info', 'Entitlements'})
if other:
    sys.exit('ChromiumApp/Additions.plist holds other than Info and Entitlements: ' + ', '.join(other))
info, entitlements = listed.get('Info', {}), listed.get('Entitlements', {})
def merged(base, added):
    return {**base, **{key: base.get(key, []) + value if isinstance(value, list) else value for key, value in added.items()}}
if mode == 'validate':
    app_info, engine_entitlements = load(sys.argv[3]), load(sys.argv[4])
    for key, value in info.items():
        if key in app_info and not (isinstance(value, list) and isinstance(app_info[key], list)):
            sys.exit(f"ChromiumApp/Additions.plist would replace the app's Info.plist key: {key}")
        if isinstance(value, list) and any(entry in app_info.get(key, []) for entry in value):
            sys.exit(f"ChromiumApp/Additions.plist lists an entry already in the app's {key}")
    for key in entitlements:
        if key in engine_entitlements:
            sys.exit(f"ChromiumApp/Additions.plist would replace the engine's entitlement: {key}")
elif mode == 'apply':
    for target, added in ((sys.argv[3], info), (sys.argv[4], entitlements)):
        raw = open(target, 'rb').read() if os.path.exists(target) else b''
        try:
            result = merged(plistlib.loads(raw) if raw else {}, added)
        except Exception as error:
            sys.exit(f'Cannot merge ChromiumApp/Additions.plist into {target}: {error}')
        with open(target, 'wb') as handle:
            plistlib.dump(result, handle, fmt=plistlib.FMT_BINARY if raw.startswith(b'bplist') else plistlib.FMT_XML)
elif mode == 'signed':
    app, engine_entitlements = sys.argv[3], load(sys.argv[4])
    signed_info = load(os.path.join(app, 'Contents/Info.plist'))
    executable = os.path.join(app, 'Contents/MacOS', signed_info.get('CFBundleExecutable', ''))
    shown = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', executable], capture_output=True).stdout
    signed = plistlib.loads(shown) if shown.strip() else {}
    expected = merged(engine_entitlements, entitlements)
    problems = []
    for key, value in info.items():
        present = signed_info.get(key)
        if not (isinstance(present, list) and all(entry in present for entry in value) if isinstance(value, list) else present == value):
            problems.append(f'The signed Info.plist lacks the listed Info.plist addition: {key}')
    for key in sorted(expected):
        if signed.get(key) != expected[key]:
            problems.append(('The signed app lacks the listed entitlement: ' if key in entitlements else "The signed app lacks the engine's entitlement: ") + key)
    problems += [f"Entitlement outside the engine's and the declared additions: {key}" for key in sorted(set(signed) - set(expected))]
    sys.exit('\n'.join(problems) or None)
PY
}
if [[ $# == 2 && $1 == --check-engine ]]; then
  check_engine "$2" "$ENGINE_HEADERS"
  printf 'Verified engine against the checkout pin: %s\n' "$2"
  exit 0
fi
if [[ $# -ge 2 && $# -le 4 && $1 == --check-signed ]]; then
  ADDITIONS="${3:-$DEFAULT_ADDITIONS}"
  engine=${4:-$(python3 -B "$LAYOUT" local-engine "$PACKAGE" "$ARCH")}
  ENGINE_ENTITLEMENTS="$engine/Bark Packaging/app-entitlements.plist"
  [[ -f "$ADDITIONS" ]] || refuse "Missing the app's additions: $ADDITIONS"
  [[ -f "$ENGINE_ENTITLEMENTS" ]] || refuse "Missing the engine's app entitlements: $ENGINE_ENTITLEMENTS"
  require_architecture "$2/Contents/MacOS/Bark"
  require_architecture "$2/Contents/Frameworks/NookNativeShell.framework/Versions/A/NookNativeShell"
  python3 -B "$REPO/scripts/check-chromium-architectures.py" --arch "$ARCH" \
    --engine-info "$engine/engine-Info.plist" "$2/Contents/Frameworks/Bark Framework.framework"
  check_outer_metadata "$2" "$engine/engine-Info.plist"
  check_bundle "$2" signed
  additions signed "$ADDITIONS" "$2" "$ENGINE_ENTITLEMENTS"
  echo "One libnook_adblock.dylib, every Mach-O signed, and the engine's entitlements plus the declared additions: $2"
  exit 0
fi
if [[ $# != 4 && $# != 5 ]]; then
  echo 'usage: bash scripts/stage-chromium-app.sh [--arch x86_64|arm64] <app-target Bark.app> <engine artifact directory> <native-products-directory> <new-output.app> [<Additions.plist>]' >&2
  echo '       bash scripts/stage-chromium-app.sh [--arch x86_64|arm64] --check-engine <engine artifact directory>' >&2
  echo '       bash scripts/stage-chromium-app.sh [--arch x86_64|arm64] --check-signed <signed Bark.app> [<Additions.plist> [<engine artifact directory>]]' >&2
  exit 2
fi
APP="$1"
ARTIFACT="$2"
PRODUCTS="$3"
OUTPUT="$4"
ADDITIONS="${5:-$DEFAULT_ADDITIONS}"
PACKAGING="$(dirname "$OUTPUT")/Bark Packaging"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
zone_names() { /usr/bin/strings -a "$1" | /usr/bin/grep -xE '[A-Za-z]*Delegating[A-Za-z]*Zone[A-Za-z]*' | /usr/bin/sort -u || true; }
ENGINE_FRAMEWORK_NAME='Bark Framework.framework'
ENGINE_FRAMEWORK="$ARTIFACT/$ENGINE_FRAMEWORK_NAME"
ENGINE_INFO="$ARTIFACT/engine-Info.plist"
APP_INFO="$APP/Contents/Info.plist"
APP_MAIN="$APP/Contents/MacOS/Bark"
NATIVE_FRAMEWORK="$PRODUCTS/NookNativeShell.framework"
NATIVE="$NATIVE_FRAMEWORK/Versions/A/NookNativeShell"
[[ ! -e "$OUTPUT" ]] || refuse 'Output already exists; refusing replacement'
[[ ! -e "$PACKAGING" ]] || refuse 'Packaging output already exists; refusing replacement'
[[ -f "$ADDITIONS" ]] || refuse "Missing the app's additions: $ADDITIONS"

check_engine "$ARTIFACT" "$PRODUCTS/include/BarcChromium"
ENGINE_ENTITLEMENTS="$ARTIFACT/Bark Packaging/app-entitlements.plist"

[[ -f "$APP_MAIN" && $(plist "$APP_INFO" CFBundleExecutable) == Bark ]] || refuse 'Missing app target executable'
[[ ! -e "$APP/Contents/_CodeSignature" ]] || refuse 'App already has a code signature: build it with CODE_SIGNING_ALLOWED=NO'
[[ $(plist "$APP_INFO" CFBundleIdentifier) == ee.qdo.bark ]] || refuse 'App bundle identifier must be exactly ee.qdo.bark'
[[ $(plist "$APP_INFO" NSPrincipalClass) == BrowserCrApplication ]] ||
  refuse 'App principal class must be BrowserCrApplication: Chromium owns NSApplication'
check_outer_metadata "$APP" "$ENGINE_INFO" source
additions validate "$ADDITIONS" "$APP_INFO" "$ENGINE_ENTITLEMENTS"

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
require_architecture "$APP_MAIN"
require_architecture "$NATIVE"
require_architecture "$ENGINE_BINARY"
/usr/bin/otool -hv "$NATIVE" | /usr/bin/grep -q DYLIB || refuse 'Native shell must be a dylib, not an executable'
# A framework that does not recognize main's zone falls into its later, racy registration without an error.
MAIN_ZONE=$(zone_names "$APP_MAIN")
[[ -n "$MAIN_ZONE" && "$MAIN_ZONE" == "$(zone_names "$ENGINE_BINARY")" ]] ||
  refuse 'App executable and framework must use the same malloc zone name'
ENGINE_EXPORTS=$(/usr/bin/nm -gjU "$ENGINE_BINARY")
# main resolves the entry and the table and hands both to the shell, which names neither.
for symbol in barc_engine_main barc_bridge; do
  NAMED=$(/usr/bin/strings -a "$APP_MAIN" | /usr/bin/grep -oE "${symbol}_v[0-9]+" | /usr/bin/sort -u || true)
  [[ -n "$NAMED" && "$NAMED" != *$'\n'* ]] || refuse "App executable must name exactly one versioned ${symbol}: $APP_MAIN"
  /usr/bin/grep -x "_$NAMED" <<<"$ENGINE_EXPORTS" > /dev/null ||
    refuse "Engine does not export $NAMED, which the app resolves: built for another bridge version"
done
! /usr/bin/strings -a "$NATIVE" | /usr/bin/grep -qE 'barc_(engine_main|bridge)_v[0-9]+' ||
  refuse "Native shell names an engine symbol: only main resolves the engine: $NATIVE"
trap '/bin/rm -rf "$OUTPUT" "$PACKAGING"' EXIT
/usr/bin/ditto "$APP" "$OUTPUT"
/bin/mkdir -p "$OUTPUT/Contents/Frameworks"
# Xcode/SPM dependencies and resources retain their existing names. Refuse
# collisions rather than replacing engine-owned files or guessing precedence.
for framework in "$ENGINE_FRAMEWORK" "$PRODUCTS/"*.framework "$PRODUCTS/PackageFrameworks/"*.framework; do
  [[ -d "$framework" ]] || continue
  name=$(basename "$framework")
  [[ ! -e "$OUTPUT/Contents/Frameworks/$name" ]] || refuse "Framework collision: $name"
  /usr/bin/ditto "$framework" "$OUTPUT/Contents/Frameworks/$name"
  # The engine artifact is read-only and signing rewrites what is staged from it.
  /bin/chmod -R u+w "$OUTPUT/Contents/Frameworks/$name"
done
# Native catalogs and Metal libraries live inside NookNativeShell.framework.
for resource in "$PRODUCTS/"*.bundle; do
  [[ -e "$resource" ]] || continue
  name=$(basename "$resource")
  [[ ! -e "$OUTPUT/Contents/Resources/$name" ]] || refuse "Resource collision: $name"
  /usr/bin/ditto "$resource" "$OUTPUT/Contents/Resources/$name"
done
/usr/bin/ditto "$ARTIFACT/Bark Packaging" "$PACKAGING"
/bin/chmod -R u+w "$PACKAGING"
additions apply "$ADDITIONS" "$OUTPUT/Contents/Info.plist" "$PACKAGING/app-entitlements.plist"
check_outer_metadata "$OUTPUT" "$ENGINE_INFO"
trap - EXIT
printf '%s\n' "Staged unsigned candidate: $OUTPUT" "Staged its packaging: $PACKAGING" 'Chromium signing is required before launch; no signing was performed.'
