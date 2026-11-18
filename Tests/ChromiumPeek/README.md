# Signed Bark Peek walk

Use a signed Bark candidate for the Mac’s native architecture, built against a
Peek-enabled engine. Use a Python installation with the PyObjC Cocoa, Quartz and
ApplicationServices modules and existing Accessibility, input posting and
Screen Recording access.

```fish
python3 Tests/ChromiumPeek/walk.py --app /path/to/Bark.app --output /private/tmp/peek-walk
python3 Tests/ChromiumPeek/keyboard_walk.py --app /path/to/Bark.app --output /private/tmp/peek-keys
```

The output directory must be new. The walk creates and removes its own
verification profile and preference domain, serves its pages over loopback
and holds the Chromium browser test screen lock while using the app. Leave
the input devices idle until it finishes. The script stops if the lock is
lost, the candidate loses focus or the pointer moves unexpectedly.

The walk verifies trusted Shift-click, Escape back to the same source and
promotion of the same Peek document into a split. It checks document IDs,
draft values and which document received the next key. It confirms Quit and
records browser-side events, the app log and captures of the candidate window.

The keyboard walk focuses the link with Tab and opens Peek with Shift+Return.
It checks that Escape restores the source link and draft, reopens the link,
and presses the default Add Split View shortcut (Control+Shift+=). The target
must keep its document and draft and receive the next typed character.
