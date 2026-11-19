# Signed large-session restore walk

Run with the same signed-walk Python, Accessibility, event-posting and Screen
Recording permissions as the startup timing walk. Use a native signed Bark
candidate and a fresh evidence directory outside its bundle.

```fish
"$BARK_WALK_PYTHON" -B Tests/ChromiumStartup/lazy_restore.py \
    --app build/Bark.app --verify-sdk --output /private/tmp/bark-lazy-default
"$BARK_WALK_PYTHON" -B Tests/ChromiumStartup/lazy_restore.py \
    --app build/Bark.app --verify-sdk --last-tab-only --output /private/tmp/bark-lazy-last-only
```

Each run seeds 50 distinct tabs across two spaces in a disposable profile.
The saved selection is tab 23. A held loopback resource keeps that document
loading until its draft receives trusted input. The server must see no other
saved page request before then.

The default mode expects 16 requested and ready documents in the active
space, including the foreground document. Last Tab Only expects one. In both
modes, Cmd+9 must request only cold tab 25 and route subsequent trusted input
to its draft. The walk records loopback document requests, renderer document
IDs, and the exact mounted accessibility web area before and after selection.
Use a signed app with the numeric TabResources catalog log. The runner
starts a debug log stream before launch, takes counts only from the
disposable app’s PID, and records the engine catalog separately. It
expects one engine tab while the foreground loads, then 16 by default
or one in Last Tab Only, then exactly one more after cold selection.
The catalog count covers admitted regular tabs, including those outside
the mounted web area. The native page lifecycle tests separately cover
warmer admission and cancellation.
