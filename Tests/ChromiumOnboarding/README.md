# Chromium onboarding checks

Run the headless marker regression from the repository root.

```fish
python3 Tests/ChromiumOnboarding/check.py
```

On a Mac with an idle desktop, use the [signed walk Python environment](../../CONTRIBUTING.md#run-the-signed-ui-walks) and a signed native Bark developer candidate.

```fish
set -l evidence (mktemp -d /private/tmp/bark-onboarding-walk.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumOnboarding/walk.py --app build/Bark.app --output "$evidence/onboarding"
```

The walk starts with an empty private verification root and uses the same
synthetic profile and preferences domain for both launches. It observes the
actual welcome window, waits for Bark to persist starter tabs, and interrupts
the first process with SIGKILL. On relaunch the welcome window must return, the
starter space IDs must match, and **Get Started** must advance to the stage
with **Skip**. The marker must remain pending. The walk stops before choosing
an import or finishing setup. It removes the test root and isolated preferences
and leaves the phase record and both app logs in the output directory.
