# Signed shipping address save

Run this optional UI walk on an idle Mac with the
[signed walk Python environment](../../CONTRIBUTING.md#run-the-signed-ui-walks),
a signed native Bark developer app, and its matching installed SDK.

```fish
set -l evidence (mktemp -d /private/tmp/bark-address-save.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumAddressSave/walk.py --verify-sdk --app build/Bark.app --output "$evidence/walk"
```

The walk types two distinct synthetic US shipping addresses and checks
the actual loopback form POSTs. Each includes the country, state, and ZIP
code. It accepts the first address in Bark’s **Save address?** bubble and
declines the second. After clean quit it reads the disposable Chromium
address database and confirms only the first address was saved. The walk
removes the profile. The output contains only synthetic evidence.
