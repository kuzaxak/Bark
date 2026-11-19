# Signed large-session restore walk

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
