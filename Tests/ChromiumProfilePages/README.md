# Chromium profile pages

The [contributor profile-pages check](../../CONTRIBUTING.md) runs the
headless profile utility-window ownership regression.

On an idle Mac, use the [signed walk environment](../../CONTRIBUTING.md#run-the-signed-ui-walks)
and a signed native Bark app for the two-profile UI check.

```fish
set -l evidence (mktemp -d /private/tmp/bark-shared-inbox.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumProfilePages/walk.py --app build/Bark.app --output "$evidence/walk"
```

The walk opens the same loopback URL and title in separate synthetic Work
and Personal profiles. It follows the two named palette destinations and
checks trusted keyboard input and separate drafts in the original live
documents. Work requests site location permission. The walk switches to
Personal while Work's prompt is pending, verifies Personal can still edit
its own draft, then returns to Work and denies the request. Only Work's
requesting document may receive the denial. The walk never grants location
access or opens a real profile. Screenshots and event traces stay in the
requested output directory.
