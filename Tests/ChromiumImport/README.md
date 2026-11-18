# Arc and Chrome import checks

Run the focused model and fixture checks with `python3 Tests/ChromiumImport/check.py`.

The signed-app walk runs on an Intel Mac with PyObjC Cocoa, Quartz and
ApplicationServices and existing Accessibility, input posting and Screen
Recording access. Build the candidate with `scripts/bark-check.py build`.

```fish
python3 Tests/ChromiumImport/walk.py --app /path/to/Bark.app --output /private/tmp/import-chrome --session repeat
python3 Tests/ChromiumImport/walk.py --app /path/to/Bark.app --output /private/tmp/import-arc --session repeat --browser Arc
python3 Tests/ChromiumImport/walk.py --app /path/to/Bark.app --output /private/tmp/import-stop --session stop-shared
```

Each run creates a temporary verification profile, generates its Arc and
Chrome sources from the checked-in fixtures, and acquires the Chromium
test screen lock. Leave the pointer and keyboard idle during the walk.
The chosen output must be a new directory. It contains the checks,
app log and captures of the candidate’s own window.

The repeat session uses the import dialog in a running browser and checks
existing spaces and tabs, imported data, and the second import date. The
stop-shared session clicks the scrim during a large import, opens the same
running session in another window and stops it there.
