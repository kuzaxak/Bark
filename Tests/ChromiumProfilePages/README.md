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

The integrated milestone uses the same synthetic inboxes to open a real
link in Peek with **Shift+Return**, promote the live thread to Split View,
dismiss its site permission with **Escape**, and quit and relaunch the
same profile. After restart it checks saved Office selection, the
active split item, all three drafts, and trusted input to both restored
profiles. JavaScript document IDs may change on relaunch.

```fish
set -l evidence (mktemp -d /private/tmp/bark-profile-milestone.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumProfilePages/milestone_walk.py --app build/Bark.app --output "$evidence/walk"
```

The default run requires native focus to reach the selected renderer by
keyboard. For diagnosis, `--allow-pointer-focus` can restore focus with a
guarded click whose trusted receiver is checked. Such a run records the
fallback and cannot qualify keyboard-only focus.
