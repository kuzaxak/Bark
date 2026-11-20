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

Use `--mode pointer` to check the physical palette, Peek, Split View, and
permission controls with the same document and persistence assertions.
This mode uses keyboard events for draft text, and clicks the location
denial only after macOS hit-testing confirms the visible control belongs
to the requesting site.

Use the storage walk to verify that two spaces in one profile share
same-origin cookies and local storage, while a second profile has its
own values. It renames the shared profile in Settings, relaunches with
the same disposable data, and checks both markers, the saved name, and
the original UUID-backed directories.

```fish
set -l evidence (mktemp -d /private/tmp/bark-profile-storage.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumProfilePages/storage_walk.py --app build/Bark.app --output "$evidence/walk" --verify-sdk
```

The quick links walk opens Settings → Profiles and selects a disposable
profile assigned to two spaces. It verifies each control selects the exact
Chromium URL in the original product window and that the first matching
space stays selected. It also checks the Location permission link and
cancels the Delete browsing data dialog.
The headless `profile-pages` check separately verifies startup recovery
window ownership and lifecycle.

```fish
set -l evidence (mktemp -d /private/tmp/bark-profile-quick-links.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumProfilePages/quick_links_walk.py --app build/Bark.app --output "$evidence/walk" --verify-sdk
```

### Profile-local site icons

Use the pinned SDK and a signed candidate built with the optional native favicon
callback. Run from the source snapshot that pins the candidate’s SDK. Use
`--verify-sdk` for a staged developer SDK, or `--require-official` only for an
official SDK with verified provenance.

```fish
set -l evidence (mktemp -d /private/tmp/bark-profile-favicons.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumProfilePages/favicon_walk.py --app build/Bark.app --output "$evidence/walk" --verify-sdk
```

A disposable Work profile and Personal profile open the same loopback URL. The
walk switches profiles through the sidebar and verifies the active document’s
profile label and URL through accessibility. It measures the two fixture colors
in screenshots of the real sidebar row and checks that navigation to a page
without an icon clears Work’s previous icon while Personal’s remains intact.
The evidence includes each rendered step, candidate verification, fixture
requests and clean quit.
