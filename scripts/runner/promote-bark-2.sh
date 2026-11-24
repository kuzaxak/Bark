#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
# Promote the exact paired SDK metadata already used to build the signed apps.
set -euo pipefail
if [[ $# != 2 ]]; then echo 'Usage: promote-bark-2.sh OFFICIAL_HEADERS RELEASE_DIRECTORY' >&2; exit 2; fi
generated=$1
assets=$2
: "${SOURCE_COMMIT:?}" "${DEFAULT_BRANCH:?}" "${BARK_RELEASE_VERSION:?}" "${BARK_BUILD_NUMBER:?}"
version=$BARK_RELEASE_VERSION
tag=bark-v$version
git check-ref-format "refs/heads/$DEFAULT_BRANCH"
test "$(git rev-parse HEAD)" = "$SOURCE_COMMIT"
headers=Packages/BarkEngine/BarkEngine.xcframework/macos-arm64_x86_64/Headers/BarcChromium
for arch in x86_64 arm64; do
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
  test "$final" = "$SOURCE_COMMIT" || test "$(git rev-parse "$final^")" = "$SOURCE_COMMIT"
  git diff --cached --quiet "$final" --
  git merge-base --is-ancestor "$final" FETCH_HEAD
  git checkout --detach "$final"
  push_refs=()
else
  test "$(git rev-parse FETCH_HEAD)" = "$SOURCE_COMMIT"
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  if ! git diff --cached --quiet; then
    git commit -m "Pin the Chromium $(cut -d. -f1 Runtime/Chromium/CHROMIUM_VERSION) SDKs for Bark $version" \
      -m 'Use the manifests from both notarized native releases so the published source verifies the same frameworks users receive.'
  fi
  final=$(git rev-parse HEAD)
  git tag -a "$tag" -m "Bark $version"
fi
previous=$(git tag --list --sort=-version:refname 'bark-v*' |
  awk -v tag="$tag" '!found && /^bark-v[0-9]+\.[0-9]+\.[0-9]+$/ && $0 != tag { print; found = 1 }')

notes=$RUNNER_TEMP/bark-release-notes.md
awk -v version="$version" '/^## / { on = ($2 == version); next } on' CHANGELOG.md > "$notes"
# Nook 1.5.4 follows appcast.xml on every Latest release to the transition image published with bark-v2.0.0.
gh release download bark-v2.0.0 --repo "$GITHUB_REPOSITORY" --dir "$assets" \
  --pattern appcast.xml --pattern Nook-1.5.5-universal.dmg
python="${BARK_WALK_PYTHON:-$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python}"
args=(--version "$version" --build "$BARK_BUILD_NUMBER" --commit "$final" --previous-latest "$previous"
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
