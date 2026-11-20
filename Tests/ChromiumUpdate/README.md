# Installed Bark update walk

Use the architecture's pinned Bark SDK, Xcode, a Developer ID Application identity from your team and a Python interpreter with PyObjC, Accessibility and event-posting access. The packager verifies that your team signed both the staged rehearsal app and its disk image. Production releases require Bark’s release team. The display must be unlocked and idle. By default, the walk builds the checkout's unsigned Release shell with locked packages in temporary storage.

The [UI walk setup](../../CONTRIBUTING.md#run-the-signed-ui-walks) installs the pinned Python bindings.

```fish
set -l bark_arch (python3 scripts/chromium_sdk_layout.py native-arch)
python3 scripts/bark-check.py engine --arch "$bark_arch" --install --engine /path/to/matching/Engine
set -l evidence (mktemp -d /private/tmp/bark-update-evidence.XXXXXX)
python3 Tests/ChromiumUpdate/walk.py --output "$evidence/walk" \
  --identity 'Developer ID Application: …'
```

The walk removes its temporary Xcode output and unregisters the unsigned shell. For a warm developer rehearsal, pass `--derived-data` with existing unsigned Release products and locked Sparkle tools. The walk leaves those caller-supplied products in place.

The walk generates an ephemeral Sparkle key and uses an OS-assigned loopback port. It installs signed build 100 from its disk image into a private application directory. It verifies that conflicting startup arguments are refused, saves a synthetic draft through keyboard input, and uses Bark's **Check for Updates…** menu. Sparkle must reject the enclosure with a changed Ed25519 signature. The valid enclosure must replace the installed bundle, relaunch build 101 at that path and restore the draft from the same sealed profile. The test checks the relaunched executable path, verifies the post-update bundle and its complete embedded SDK against the pin, and compares the installed launcher, Swift shell and engine images with signed build 101. It then quits the app.

For official qualification on the receiving Mac, use the tracked source and its matching pin. Install the transferred native SDK archive, then run the walk with a local Developer ID Application identity.

```fish
"$BARK_WALK_PYTHON" -B scripts/bark-check.py engine --require-official --install --engine /path/to/BarkSDK.tar.gz
"$BARK_WALK_PYTHON" -B Tests/ChromiumUpdate/walk.py --require-official --output /private/tmp/bark-official-update-evidence \
  --identity 'Developer ID Application: …'
```

Official mode verifies the native SDK pin and provenance and refuses external DerivedData. Both signed builds and both disk image payloads must match the verified SDK.

To rehearse the shell from a signed Bark distribution, add `--candidate-app /path/to/Bark.app`. The walk verifies a private copy against the native pin, removes the copied provisioning profile if present, and signs both rehearsal versions using that shell and an isolated loopback feed. This mode resolves the locked Sparkle tooling without building Bark. It cannot be combined with `--derived-data`.

`candidate.json` records the architecture, exact SDK pin, and the original and replacement signed bundle CDHashes. It also records whether the shell came from the checkout, external DerivedData, or a signed candidate. Candidate mode records its verified source bundle CDHash. These fields identify the bundles and build input path. They do not establish a source revision. The `official` field is `true` after official verification and `null` in a developer walk. The installed update must match the verified replacement's CDHash.

The installed update observations are in `walk.json`. Its `sparkle_handoff` events record installer controls, console readiness, confirmed actions, and the original exit or state before failure cleanup. The walk allows up to five minutes after serving the valid disk image for Sparkle signature verification, extraction, and Gatekeeper preparation. Its separate 160-second quit deadline starts when Sparkle offers the install handoff or leaves extraction. A failure before cleanup stays a failure even if Sparkle relaunches later.

The two signed bundles omit browser and document handler declarations. Test apps, disk images, update keys, and synthetic profile data are temporary. The requested output contains verification logs and loopback requests. The walk builds both disk images with the release packager, using local Developer ID and ephemeral Sparkle signatures. It installs build 100 from its disk image and serves the build 101 disk image on loopback. It exercises the same packager as CI with a dedicated identity and feed. Production CI artifacts, notarization and live feed publishing are outside this walk.

## Automatic update settings

The Settings regression builds a small signed SwiftUI host with the real Bark updater and the Sparkle framework from the checkout's locked Xcode products. Run it on an unlocked, idle Mac with the same Accessibility-enabled Python used for the installed walk. Supply the path to `Sparkle.framework` from an existing Bark build or native check.

```fish
python3 Tests/ChromiumUpdate/controls.py --sparkle /path/to/Build/Products/Debug/Sparkle.framework
```

It checks for separate, accessible controls, exercises Sparkle's persisted preferences across app launches, and verifies that disabling checks also disables automatic downloads while preserving the download preference. It checks that an unstarted or rehearsal updater exposes neither control, and that a configuration forbidding automatic downloads exposes only the check control. The fixture uses unique bundle identifiers, disposable defaults, and a loopback feed with no server responses. It fails if Sparkle attempts a feed connection.

### Rehearse an installed update on a second Mac without a signing identity

On a signing Mac with Bark’s Developer ID Application identity, prepare the
kit from the exact ordinary signed Bark.app and its installed SDK. The
target architecture can differ from the signing Mac’s architecture.

```fish
python3 -B Tests/ChromiumUpdate/walk.py --prepare-kit "$kit" --arch arm64 \
    --candidate-app "$signed_app" --identity "$BARK_SIGN_IDENTITY" --require-official
```

Transfer the kit, the same ordinary signed app, and the matching pinned SDK
archive to the receiving Mac. The kit contains two signed rehearsal DMGs,
the loopback appcast and a manifest. The temporary Sparkle signing key and
provisioning profile stay off the receiving Mac. From the same tracked
source and pin, use the [signed-walk Python](../../CONTRIBUTING.md#run-the-signed-ui-walks)
for both commands. The walk requires Accessibility authorization and an idle desktop.

```fish
"$BARK_WALK_PYTHON" -B scripts/bark-check.py engine --require-official --install --engine "$archive"
"$BARK_WALK_PYTHON" -B Tests/ChromiumUpdate/walk.py --kit "$kit" \
    --candidate-app "$signed_app" --output "$evidence" --require-official
```

The receiver uses its native architecture, verifies the ordinary app and
SDK, and checks the kit’s signatures and shell against that app. It runs the
same changed-signature refusal and valid-update handoff with a disposable
profile. The loopback port is sealed into both rehearsal apps. If the port
is busy, free it before retrying or prepare a fresh kit with a different
port. Use a new evidence directory for each run. If a terminated run left
profile, defaults or cache state, the verifier refuses to reuse that state.
