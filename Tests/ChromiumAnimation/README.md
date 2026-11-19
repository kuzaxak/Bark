# Parked document animation

Run against an idle signed Bark candidate with the [signed-walk Python environment](../../CONTRIBUTING.md#run-the-signed-ui-walks).

```fish
set -l evidence (mktemp -d /private/tmp/bark-animation.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumAnimation/walk.py --app build/Bark.app --output "$evidence/parked" --verify-sdk
```

The walk types a synthetic draft, parks its document, and keeps another tab
visible for at least 1.5 seconds. Both documents continuously request animation
frames. The parked document reports zero callbacks after a 250 ms transition
allowance and resumes on return with the same draft and document identity.
The visible alternate must continue advancing on both sides of the hold.

Add `--split` to promote a disposable Peek sibling into a split and require
both visible panes to advance while the source stays parked. The walk exercises
tab selection in a single unoccluded window and leaves its observations in
`animation.json` and `events.json`.

After checking draft recovery, the walk parks the source again. The loopback
server releases a navigation response only after that document reports it is
hidden. The replacement must start hidden with a new document ID. The walk
keeps a visible sibling animating for at least 1.5 seconds, verifies the hidden
replacement recorded zero late callbacks, and then selects it and confirms it
animates.

The walk then Command-clicks a link to create a separate background document.
It must also start hidden, record zero late callbacks while the opener keeps
animating, and start animating when selected.
