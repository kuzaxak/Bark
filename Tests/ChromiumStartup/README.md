# Chromium startup checks

Run the headless startup and storage regression from the repository root.

```fish
python3 -B Tests/ChromiumStartup/check.py
```

The check compiles the app's startup source and uses a mock startup bridge.
Each run owns a private scratch directory. It checks that normal startup
prepares and reopens the same app and engine paths with their existing bytes
intact, that verification uses separate storage and adds the mock-keychain
switch, and that malformed or redirected storage paths are refused.

## Signed large-session restore walk

Use the signed-walk Python environment from the contributor guide and a native
signed Bark app. The runner uses Accessibility, event posting and Screen
Recording on an idle desktop. [Signed UI walk setup](../../CONTRIBUTING.md#run-the-signed-ui-walks)

```fish
set -l evidence (mktemp -d /private/tmp/bark-lazy.XXXXXXXX)
python -B Tests/ChromiumStartup/lazy_restore.py \
    --app build/Bark.app --verify-sdk --output "$evidence/default"
python -B Tests/ChromiumStartup/lazy_restore.py \
    --app build/Bark.app --verify-sdk --last-tab-only --output "$evidence/last-only"
python -B Tests/ChromiumStartup/lazy_restore.py \
    --app build/Bark.app --verify-sdk --check-space-switch --output "$evidence/space-switch"
```

Each run seeds 50 distinct tabs across two spaces in a disposable profile.
The default and Last Tab Only runs save tab 23 as the active selection. A held loopback resource keeps that document
loading until its draft receives trusted input. The server must see no other
saved page request before then.

The default mode expects 16 requested and ready documents in the active
space, including the foreground document. Last Tab Only expects one. In both
modes, Cmd+9 must request only cold tab 25 and route subsequent trusted input
to its draft. The walk records loopback document requests, renderer document
IDs, and the exact mounted accessibility web area before and after selection.
The result includes elapsed time from launch and cold selection to each
document's ready beacon and trusted input. Input timings include the
walker's accessibility and pointer checks.
Use a signed app with the numeric TabResources catalog log. The runner
starts a debug log stream before launch, takes counts only from the
disposable app’s PID, and records the engine catalog separately. It
expects one engine tab while the foreground loads, then 16 by default
or one in Last Tab Only, then exactly one more after cold selection.
The catalog count covers admitted regular tabs, including those outside
the mounted web area. The native page lifecycle tests separately cover
warmer admission and cancellation.

The space-switch run shares one profile across spaces with 3 and 47 tabs.
It first restores tab 02 and waits for all three initial pages to settle.
It then clicks Parked space in the native sidebar. Only the saved selection,
tab 04, may load or receive input. The engine count must go from 1 to 3 to 4,
and the remaining 46 destination URLs must receive no document requests.

## Verify a transferred release candidate

Use the full Bark source revision and the official SDK archive for the
candidate’s architecture. Supply the DMG and native qualification receipt
from the same candidate run. Use the [signed-walk Python](../../CONTRIBUTING.md#run-the-signed-ui-walks)
for both commands.

```fish
"$BARK_WALK_PYTHON" -B scripts/bark-check.py engine --arch "$arch" --require-official \
    --engine "$sdk_archive" --install
and "$BARK_WALK_PYTHON" -B Tests/ChromiumStartup/qualify.py check-release-receipt \
    --arch "$arch" --image "$image" --receipt "$receipt"
```

If you also have the signed staging app, add `--app "$app"` to compare it
with the image. The check mounts the DMG read-only and copies Bark to a
temporary directory. It checks the image signature, Gatekeeper assessments
and the installed app’s signature and identity. It compares the embedded
framework with the official SDK and remeasures the DMG, installed app and
embedded Chromium framework against the byte counts in the receipt.
The startup measurements and installed update identities come from the
native walk recorded in the receipt. The verifier can run without opening Bark.
