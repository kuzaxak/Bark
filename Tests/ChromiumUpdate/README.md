# Installed Bark update walk

Use the architecture's pinned Bark SDK, Xcode, a local Developer ID Application identity and a Python interpreter with PyObjC and Accessibility access. The display must be unlocked and idle. Run the Release build with the checked-in Swift package lock before starting the walk. You can reuse those unsigned build products on subsequent runs.

The [UI walk setup](../../CONTRIBUTING.md#run-the-signed-ui-walks) installs the pinned Python bindings.

```fish
set -l bark_arch (python3 scripts/chromium_sdk_layout.py native-arch)
python3 scripts/bark-check.py engine --arch "$bark_arch" --install --engine /path/to/matching/Engine
set -l derived (mktemp -d /private/tmp/bark-update-build.XXXXXX)
xcodebuild -project Nook.xcodeproj -scheme NookNativeShell -configuration Release -destination generic/platform=macOS \
  -derivedDataPath "$derived" -onlyUsePackageVersionsFromResolvedFile ARCHS="$bark_arch" CODE_SIGNING_ALLOWED=NO \
  'OTHER_SWIFT_FLAGS=$(inherited) -j3' -jobs 1 build
set -l lsregister /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
"$lsregister" -u "$derived/Build/Products/Release/Bark.app"
python3 Tests/ChromiumUpdate/walk.py --derived-data "$derived" --output /private/tmp/bark-update-evidence \
  --identity 'Developer ID Application: …'
```

The walk generates an ephemeral Sparkle key and uses an OS-assigned loopback port. It installs signed build 100 from its disk image into a private application directory. It verifies that conflicting startup arguments are refused, saves a synthetic draft through keyboard input, and uses Bark's **Check for Updates…** menu. Sparkle must reject the enclosure with a changed Ed25519 signature. The valid enclosure must replace the installed bundle, relaunch build 101 at that path and restore the draft from the same sealed profile. The test checks the relaunched executable path, verifies the post-update bundle signature and compares the installed launcher, Swift shell and engine images with signed build 101. It then quits the app.

The two signed bundles omit browser and document handler declarations. Test apps, disk images, update keys, and synthetic profile data are temporary. The requested output contains verification logs and loopback requests. The local disk images use Developer ID signing and Sparkle signatures. Production notarization and feed publishing are outside this walk.
