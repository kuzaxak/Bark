# Chromium Settings

Run the headless settings checks with `python3 -B Tests/ChromiumSettings/check.py`.

The signed walk opens Settings in a disposable Bark profile. It checks that
Back and Forward have separate accessibility names and correct enabled
states. It enters Privacy, verifies the Passwords section, opens Profiles,
then uses the toolbar's accessibility actions to return to Privacy and go
forward to Profiles again.

Use the [signed walk environment](../../CONTRIBUTING.md#run-the-signed-ui-walks)
and leave the macOS desktop idle during the walk.

```fish
set -l evidence (mktemp -d /private/tmp/bark-settings-history.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumSettings/walk.py --app build/Bark.app --verify-sdk --output "$evidence/walk"
```
