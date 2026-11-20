#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
# Promote the exact paired SDK metadata already used to build and qualify the signed apps.
set -euo pipefail
if [[ $# != 2 ]]; then echo 'Usage: promote-bark-2.sh QUALIFIED_HEADERS RELEASE_DIRECTORY' >&2; exit 2; fi
generated=$1
assets=$2
tag=bark-v2.0.0
: "${SOURCE_COMMIT:?}" "${DEFAULT_BRANCH:?}"
git check-ref-format "refs/heads/$DEFAULT_BRANCH"
test "$(git rev-parse HEAD)" = "$SOURCE_COMMIT"
headers=Packages/BarkEngine/BarkEngine.xcframework/macos-arm64_x86_64/Headers/BarcChromium
for arch in x86_64 arm64; do
  test -s "$assets/qualification-$arch.json"
  test -s "$assets/migration-$arch.json"
  test -s "$generated/engine-artifact-$arch.official.json"
  grep -Fq "$(cat Runtime/Chromium/CHROMIUM_VERSION)" "$generated/barc_engine_version_$arch.h"
done
test "$(gh api --method GET "repos/$GITHUB_REPOSITORY/actions/workflows/macos-build.yml/runs" \
  -f head_sha="$SOURCE_COMMIT" -f branch="$DEFAULT_BRANCH" -f event=push -F per_page=1 \
  --jq '.workflow_runs[0].conclusion')" = success || {
  echo "The default-branch macOS checks for $SOURCE_COMMIT must pass before release." >&2
  exit 1
}
cp "$generated/"*.h "$generated/"*.sha256 "$generated/"*.official.json "$headers/"
git add -- "$headers"
git fetch origin "refs/heads/$DEFAULT_BRANCH" --tags
push_refs=("HEAD:refs/heads/$DEFAULT_BRANCH" "refs/tags/$tag")
if git show-ref --verify --quiet "refs/tags/$tag"; then
  # A retry after a successful push must use the same recorded SDK pair.
  final=$(git rev-parse "$tag^{commit}")
  test "$(git rev-parse "$final^")" = "$SOURCE_COMMIT"
  git diff --cached --quiet "$final" --
  git merge-base --is-ancestor "$final" FETCH_HEAD
  git checkout --detach "$final"
  push_refs=()
else
  test "$(git rev-parse FETCH_HEAD)" = "$SOURCE_COMMIT"
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git commit -m 'Pin the qualified Chromium 158 SDKs for Bark 2.0.0' \
    -m 'Use the manifests from both notarized native releases so the published source verifies the same frameworks users receive.'
  final=$(git rev-parse HEAD)
  git tag -a "$tag" -m 'Bark 2.0.0'
fi

notes=$RUNNER_TEMP/bark-2-release-notes.md
sed -n '/^### Moving from Nook to Bark on macOS$/,/^### Added$/{/^### Added$/!p;}' CHANGELOG.md > "$notes"
python="${BARK_WALK_PYTHON:-$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python}"
args=(--version 2.0.0 --build 202611200002 --commit "$final" --previous-latest v1.5.4
      --directory "$assets" --transition-image "$assets/Nook-1.5.5-universal.dmg" --notes "$notes")
"$python" -B scripts/publish_bark_release.py "${args[@]}"
if [[ ${#push_refs[@]} != 0 ]]; then git push --atomic origin "${push_refs[@]}"; fi
"$python" -B scripts/publish_bark_release.py "${args[@]}" --publish
for feed in appcast.xml bark-macos-x86_64.xml bark-macos-arm64.xml; do
  curl -fsSL --retry 3 "https://github.com/kuzaxak/Bark/releases/latest/download/$feed" -o "$RUNNER_TEMP/$feed"
  cmp "$assets/$feed" "$RUNNER_TEMP/$feed"
done
# Installed Nook releases use the original repository URL.
curl -fsSL --retry 3 https://github.com/kuzaxak/Nook/releases/latest/download/appcast.xml -o "$RUNNER_TEMP/nook-legacy-appcast.xml"
cmp "$assets/appcast.xml" "$RUNNER_TEMP/nook-legacy-appcast.xml"
