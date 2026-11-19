# Signed Bark compact-window walk

Use a signed Bark build for the Mac’s native architecture with compact-window
engine support. The runner uses
PyObjC Cocoa, Quartz and ApplicationServices and the existing macOS Accessibility,
input-posting and Screen Recording permissions. Give it a fresh output directory.

```fish
python3 Tests/ChromiumCompact/walk.py --app /path/to/Bark.app --output /private/tmp/bark-compact-walk --verify-sdk
```

The runner opens a disposable profile and uses two loopback origins. A keyboard
action opens three popups asking for a 480 by 306 viewport, including one that
redirects to the second origin. Each popup must message its opener, receive input,
and close itself. Typing again must extend the original opener draft.

The runner checks that the Open in Space button's accessibility frame fits within
the 44-point header. It then sends a macOS open-URL event to the running
candidate's process ID. The external link must open in a mini window, and clicking
Open in Space must preserve its document and editable draft. The same compact
document must animate in its own window and advance after transfer. The previous
main document must report being hidden and stop receiving animation frames after a
250 ms transition allowance. After returning via the tab shortcut, it must keep
its original document and editable draft and resume animating. The run saves
window captures and fixture events and checks that Quit terminates the candidate.

Use `--disable-idle-unloading` with a fresh evidence directory to repeat the walk
with optional automatic tab unloading turned off. Leave the keyboard and pointer idle
while the runner holds the browser-test screen lock.
