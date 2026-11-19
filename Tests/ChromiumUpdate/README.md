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
python3 scripts/bark-check.py engine --require-official --install --engine /path/to/BarkSDK.tar.gz
python3 Tests/ChromiumUpdate/walk.py --require-official --output /private/tmp/bark-official-update-evidence \
  --identity 'Developer ID Application: …'
```

The walk verifies the native SDK's pin and official provenance before building the local shell with the locked packages. Its temporary DerivedData is removed on exit. Official mode refuses external DerivedData. Both signed builds and both disk image payloads must match that SDK. For either mode, `candidate.json` records the architecture, exact SDK pin, original and replacement signed bundle CDHashes, and whether the shell was built from the checkout's files or supplied via external DerivedData. These fields identify signed bundles and the build input path. They do not establish a source revision. The `official` field is `true` after official verification and `null` in a developer walk. The installed update must match the verified replacement's CDHash. The installed update observations are in `walk.json`. Its `sparkle_handoff` events record installer controls, console readiness, confirmed actions, and the original exit or state before failure cleanup. The walk allows up to five minutes after serving the valid disk image for Sparkle signature verification, extraction, and Gatekeeper preparation. Its separate 160-second quit deadline starts when Sparkle offers the install handoff or leaves extraction. A failure before cleanup stays a failure even if Sparkle relaunches later.

The two signed bundles omit browser and document handler declarations. Test apps, disk images, update keys, and synthetic profile data are temporary. The requested output contains verification logs and loopback requests. The walk builds both disk images with the release packager, using local Developer ID and ephemeral Sparkle signatures. It installs build 100 from its disk image and serves the build 101 disk image on loopback. It exercises the same packager as CI with a dedicated identity and feed. Production CI artifacts, notarization and live feed publishing are outside this walk.
