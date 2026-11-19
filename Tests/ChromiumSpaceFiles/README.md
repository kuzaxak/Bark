# Chromium space-file checks

Run the local file router and model tests from the repository root.

```fish
python3 -B Tests/ChromiumSpaceFiles/check.py
swift test --package-path Packages/NookTabsCore --filter SpaceFileTests
```

With a signed native Bark candidate and the [signed-walk Python environment](../../CONTRIBUTING.md#run-the-signed-ui-walks), run the manual import test on an idle desktop.

```fish
set -l evidence (mktemp -d /private/tmp/bark-space-file-walk.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumSpaceFiles/walk.py --app build/Bark.app --output "$evidence/import" --verify-sdk
```

The walk uses the native **Settings → Spaces → Import Space** picker and a
disposable legacy export containing synthetic cloud data. It verifies new IDs,
placement in the chosen profile, retained pinned hierarchy, unchanged source
and legacy sync files, and no new Bark sync store. Verification mode disables
CloudKit. The walk leaves the signed candidate identity, import result, screenshot
and app log in the evidence directory.
