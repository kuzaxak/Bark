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
synthetic profile and preferences domain throughout. It interrupts the first
process with SIGKILL after Bark has saved the starter tabs. The second launch
must resume at **Get Started** with the original space IDs and pending marker.
The walk skips import, checks that the setup explains where Nook iCloud spaces
and invitations stay and how to opt into sync in Bark, then chooses **Start Browsing Locally**. Completing setup and returning on
the third launch must both open the browser with the same starter spaces and
no Bark sync store. Verification mode keeps CloudKit disabled throughout.
The walk removes the test root and isolated preferences and preserves phase
records and app logs in the evidence directory.
