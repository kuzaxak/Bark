# Signed Bark Peek walk

Run on an Intel Mac with a signed Bark candidate built against a Peek-enabled
engine. Use a Python installation with the PyObjC Cocoa, Quartz and
ApplicationServices modules and existing Accessibility, input posting and
Screen Recording access.

```fish
python3 Tests/ChromiumPeek/walk.py --app /path/to/Bark.app --output /private/tmp/peek-walk
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
