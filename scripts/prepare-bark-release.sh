#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
# Prepares the two official Bark candidates and the universal Nook transition.
# Run on the trusted signing runner from the checkout with both official SDK pins.
set -euo pipefail
umask 077

if [[ $# != 4 ]]; then
  echo "Usage: $0 ARM64_ENGINE X86_64_ENGINE LEGACY_CHECKOUT NEW_ARTIFACT_DIRECTORY" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ARM_ENGINE="$(cd "$1" && pwd -P)"
INTEL_ENGINE="$(cd "$2" && pwd -P)"
LEGACY="$(cd "$3" && pwd -P)"
mkdir -p "$(dirname "$4")"
OUTPUT="$(cd "$(dirname "$4")" && pwd -P)/$(basename "$4")"
PYTHON="${BARK_WALK_PYTHON:-python3}"
BARK_PROFILE="${BARK_ICLOUD_PROFILE:-$HOME/Downloads/Bark_Developer_ID_CloudKit.provisionprofile}"
VERSION=2.0.0
BUILD=202611200002
TAG=bark-v2.0.0
LEGACY_REVISION=815c69d0f98e0ced5ea1eda90d86063f1423980d
RELEASES=https://github.com/kuzaxak/Bark/releases
FEED_BASE="$RELEASES/latest/download"
DOWNLOAD_BASE="$RELEASES/download/$TAG"

if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  echo "Choose a new artifact directory: $OUTPUT" >&2
  exit 1
fi

if [[ "$(git -C "$LEGACY" rev-parse HEAD)" != "$LEGACY_REVISION" ]] ||
   ! git -C "$LEGACY" diff --quiet HEAD --; then
  echo "The Nook transition must be a clean checkout of $LEGACY_REVISION." >&2
  exit 1
fi
if [[ -e "$LEGACY/build/release" || -L "$LEGACY/build/release" ]]; then
  echo "Use a fresh Nook transition checkout without previous release output." >&2
  exit 1
fi
test -f "$BARK_PROFILE"
: "${RUNNER_TEMP:?}" "${NOOK_PROVISIONING_PROFILE:?}" "${SPARKLE_SIGNING_KEY:?}"
sparkle_key="$SPARKLE_SIGNING_KEY"
unset SPARKLE_SIGNING_KEY

# Check both explicit inputs before accessing the signing credentials.
"$PYTHON" -B "$ROOT/scripts/bark-check.py" engine --require-official --arch arm64 --engine "$ARM_ENGINE"
"$PYTHON" -B "$ROOT/scripts/bark-check.py" engine --require-official --arch x86_64 --engine "$INTEL_ENGINE"

keychain_started=false
qualification_stage=
qualification_output=
if [[ -n "${BARK_QUALIFICATION_OUTPUT:-}" ]]; then
  qualification_output="$("$PYTHON" -B - "$ROOT" "$OUTPUT" "$BARK_QUALIFICATION_OUTPUT" <<'CHECK_OUTPUT'
from pathlib import Path
import sys

root, release, destination = (Path(value).resolve() for value in sys.argv[1:])
if destination.is_relative_to(root) or release.is_relative_to(destination) or destination.is_relative_to(release):
    sys.exit("Choose a qualification directory outside the checkout and release output.")
if destination.exists() or Path(sys.argv[-1]).is_symlink():
    sys.exit("Choose a new qualification directory.")
print(destination)
CHECK_OUTPUT
)"
fi

work="$(mktemp -d "$(dirname "$OUTPUT")/.bark-release.XXXXXXXX")"
cleanup() {
  if [[ "$keychain_started" == true ]]; then
    GITHUB_ENV= "$ROOT/scripts/ci-keychain.sh" cleanup || true
  fi
  rm -rf "$work"
  if [[ -n "$qualification_stage" ]]; then rm -rf "$qualification_stage"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$qualification_output" ]]; then
  mkdir -p "$(dirname "$qualification_output")"
  qualification_stage="$(mktemp -d "$(dirname "$qualification_output")/.bark-qualification.XXXXXXXX")"
fi

keychain_started=true
GITHUB_ENV= "$ROOT/scripts/ci-keychain.sh" setup
GITHUB_ENV= "$ROOT/scripts/ci-keychain.sh" notary
export SIGN_KEYCHAIN="$RUNNER_TEMP/nook-release.keychain-db"
export NOTARY_KEYCHAIN="$SIGN_KEYCHAIN"
export NOTARY_PROFILE=nook-notary
SIGN_IDENTITY="$(security find-identity -v -p codesigning "$SIGN_KEYCHAIN" |
  awk '/"Developer ID Application: / && !identity { identity = $2 } END { print identity }')"
: "${SIGN_IDENTITY:?The temporary release keychain has no Developer ID Application identity.}"
export SIGN_IDENTITY
unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD

mkdir "$work/artifacts"
for arch in arm64 x86_64; do
  if [[ "$arch" == arm64 ]]; then engine="$ARM_ENGINE"; else engine="$INTEL_ENGINE"; fi
  app="$work/$arch/Bark.app"
  "$PYTHON" -B "$ROOT/scripts/bark-check.py" build --require-official --arch "$arch" --engine "$engine" \
    --identity "$SIGN_IDENTITY" --icloud-profile "$BARK_PROFILE" --output "$app" \
    --release-version "$VERSION" --build-number "$BUILD" --feed-base-url "$FEED_BASE"
  printf '%s\n' "$sparkle_key" |
    "$PYTHON" -B "$ROOT/scripts/bark-check.py" package "$app" --require-official --arch "$arch" --engine "$engine" \
      --identity "$SIGN_IDENTITY" --notary-profile "$NOTARY_PROFILE" --download-base-url "$DOWNLOAD_BASE" \
      --ed-key-file - --output "$work/release-$arch"
  mv "$work/release-$arch/Bark-$VERSION-$BUILD-macos-$arch.dmg" "$work/release-$arch/bark-macos-$arch.xml" "$work/artifacts/"
  if [[ -n "$qualification_stage" ]]; then
    qualification="$qualification_stage/$arch"
    mkdir "$qualification"
    cp -R "$ROOT/Packages/BarkEngine/BarkEngine.xcframework/macos-arm64_x86_64/Headers/BarcChromium" "$qualification/headers"
    "$PYTHON" -B "$ROOT/scripts/bark-check.py" engine --require-official --arch "$arch" --engine "$engine" \
      --archive "$qualification/BarkSDK.tar.gz"
    "$PYTHON" -B "$ROOT/Tests/ChromiumUpdate/walk.py" --prepare-kit "$qualification/kit" \
      --candidate-app "$app" --arch "$arch" --identity "$SIGN_IDENTITY" --require-official --engine "$engine"
  fi
done

(
  cd "$LEGACY"
  SPARKLE_KEY="$sparkle_key" NOOK_RELEASE_TAG="$TAG" ./scripts/release.sh 1.5.5
)
legacy_app="$LEGACY/build/release/Nook.app"
legacy_image="$LEGACY/build/release/feed/Nook-1.5.5-universal.dmg"
/usr/bin/lipo "$legacy_app/Contents/MacOS/Nook" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict "$legacy_app"
/usr/bin/codesign --verify --strict "$legacy_image"
xcrun stapler validate "$legacy_app"
xcrun stapler validate "$legacy_image"
cp "$legacy_image" "$LEGACY/build/release/feed/appcast.xml" "$work/artifacts/"

"$PYTHON" -B - "$ROOT" "$work/artifacts" "$OUTPUT" "$qualification_stage" "$qualification_output" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
from bark_release import publish_new

if sys.argv[4]:
    publish_new(Path(sys.argv[4]), Path(sys.argv[5]))
publish_new(Path(sys.argv[2]), Path(sys.argv[3]))
PY
echo "Verified release packages are ready in $OUTPUT."
