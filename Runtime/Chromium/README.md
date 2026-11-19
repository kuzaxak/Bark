# Chromium browser-layer build

This integration uses Chromium's `chrome/` browser layer, including normal
profiles, extension services and WebUI. CEF did not qualify for the required
native surface ownership. The browser bridge must build inside this source
revision; Chromium C++ classes are not a stable external embedding ABI.

Pinned inputs:

| Input | Revision |
| --- | --- |
| Chromium 156.0.8078.80 | `fb096c0011f9d50f0a264a9376420cdea9c421e3` |
| depot_tools | `500126d6e351e4f0834b70f71b454ce5c3733c54` |

`DEPS` at the Chromium revision owns dependency/toolchain pins. Do not update
individual dependencies independently. The initial host is Intel macOS 15.8.1,
Xcode 26.3 (17C529), SDK 26.2. The signed Intel developer build passed
installation from a disk image and a Sparkle update with a disposable profile.
Official builds require SDK 26.5. Native Apple Silicon and notarized release
qualification remain open. See the [installed update walk](../../Tests/ChromiumUpdate/README.md).

Keep upstream's engine compilation deployment default, `13.0`, distinct from
`mac_min_system_version = "15.5"` (the packaged `LSMinimumSystemVersion`) and the
native app's 15.5 deployment target. Raising the engine compilation floor to
15.5 makes pinned upstream SCNetworkReachability calls fail deprecation warnings
as errors (deprecated since 14.4). Retain Chromium's supported compilation
configuration and all warning/security defaults; the product still requires
macOS 15.5. This distinction is explicit in pinned `build/config/mac/mac_sdk.gni`.

The candidate enables the open codec libraries for H.264/AAC using
`proprietary_codecs = true` and `ffmpeg_branding = "Chrome"`, while Chromium
product branding remains unbranded. Inherited macOS HEVC/HLS options still need
real playback, hardware and distribution qualification. No CDM is included.
Wait for any active compile to finish before changing build arguments.
`args-arm64.gn`
keeps the same candidate settings with only `target_cpu` changed to `arm64`.
GN-only checks use separate `out/Barc-media-args-check` and
`out/Barc-arm64-args-check` directories; configuration generation does not
establish an ARM build or native execution.

## Checkout and build

Use the checked-in recipe from the Bark repository root on macOS. It takes an
explicit gclient checkout root, containing `src/`, and works inside or outside
the Bark repository. Its default depot_tools path is the `depot_tools` sibling
of that root. Pass `--depot-tools PATH` to use a different directory. The source
commits are pinned in `PINS.json`. Chromium's `DEPS` pins the downloaded inputs.

Use Python 3.9 or newer, Git, the selected Xcode SDK, and Rust/Cargo with the
`x86_64-apple-darwin` target for Intel or `aarch64-apple-darwin` for ARM. Cargo uses the checked-in lockfile and the
selected local Rust compiler. The build prints its version. Allow several hours
and at least 150 GB of available space. Use at most eight jobs. Keep the sandbox
enabled.

```fish
set barc_repo "$PWD"
set engine_checkout "$HOME/Library/Caches/BarkSDK/chromium/checkout"
set recipe "$barc_repo/Runtime/Chromium/build_engine.py"

python3 "$recipe" prepare --checkout "$engine_checkout" --jobs 8
python3 "$recipe" check --checkout "$engine_checkout"
python3 "$recipe" build --checkout "$engine_checkout" --jobs 8
```

The build selects the Mac’s native CPU, including when Python runs under Rosetta.
Use `build --arch x64` or `build --arch arm64` to cross-compile. The recipe selects
the corresponding GN arguments and Rust target. GN links and packages Cargo's dylib
from `src/out/BarkCargo/<target>/release/`. Each target has its own library
and its own Chromium output directory. The app SDK pin currently qualifies
the Intel engine.

An official optimized build requires the macOS SDK in `PINS.json` (26.5,
build 25F70 for this Chromium revision). The recipe uses the selected Xcode's
default SDK, or accepts a separate SDK directory through `--macos-sdk`.
In either case it checks Apple's SDK metadata, uses the same sysroot for
Chromium and Cargo, and takes the build tools from the selected Xcode.
Keep the SDK at the same location while reusing an official output.

Apple ships this SDK in the signed Command Line Tools for Xcode 26.6
package. Its SHA-256 is
`debe353b27a13cd678b26ab216a040acf07b62c0639d8ac522df4ca07d121eb2`.
Check the package signature with `pkgutil --check-signature` and extract it
with `pkgutil --expand-full`. The SDK directory inside the expanded package is
`Payload/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. You can pass
that directory to the recipe without installing the package or changing the
selected Xcode.
[Apple SDK package](https://swcdn.apple.com/content/downloads/33/19/140-17812-A_21ZLMMLY4E/zu3xwktttpoe71qiawhzgzvqss6rovawsa/CLTools_macOSNMOS_SDK.pkg)

```fish
python3 "$recipe" build --checkout "$engine_checkout" --official --macos-sdk /path/to/MacOSX26.5.sdk --jobs 8
```

The recipe fetches Chromium's pinned PGO profile for the target architecture
and checks the SHA-256 of the decompressed profile before enabling
profile-guided optimization. If bytes already cached at the pinned name fail verification,
the recipe preserves the rejected regular file under
`chrome/build/.bark-rejected-pgo-*/` and asks Chromium's updater to fetch a
replacement once. The replacement must pass the same hash check. Unexpected
cache paths such as symlinks are refused. The dedicated `Barc-<arch>-official`
and `BarkCargo-official` directories keep developer and official products independent.

V8 also uses its versioned `x64.profile` to generate the startup snapshot for
both Intel and Apple Silicon. The official recipe checks V8’s Git revision,
fetches this one input from Google when needed, and verifies its SHA-256
before replacing cached bytes. It records the profile pin in the receipt and
checks it again before publication.

After the link, the recipe records the framework hashes, Chromium and
depot_tools revisions, SDK build, GN arguments and pinned PGO name and SHA-256
in `official-build.json`. The receipt also records a path-independent digest
of Bark's production overlays, Chromium patches, gclient and Siso configuration,
and the Rust matcher's sources, dependency lock and exports. The build compares
that digest before and after compilation. Publication and intake recompute it
from their source snapshot. A Git archive of the matching source works for
intake. The app shell and documentation can change independently of the SDK.
For official builds, Bark's Siso handler retains the
digest of the profile explicitly passed to the browser-core compile. The
receipt checks the browser compile before the recorded raw framework link.
It matches the Siso link digest to the raw and packaged framework bytes. The
versioned official compiler wrapper keeps this compile distinct from previous,
unwitnessed build actions. A normal
`build --official` recognizes the previous official GN arguments, including
outputs that predate the output-local SDK link and compiler wrapper. It writes
the new arguments atomically. If other GN arguments differ or the output is
bound to another SDK directory, use a fresh official output. A dry run leaves
the existing output untouched.
SDK publication rechecks the build outputs and includes the receipt in the
pinned manifest. For receipts written before the link record was required,
rerun the official build before publishing or handing off the SDK. Consumers
can verify an installed official SDK without a Chromium checkout using
`bark-check.py engine --require-official`.

#### Prepare the first official SDK on its native Mac

Start from the clean app revision to be qualified. After `prepare` and
`check`, build and publish from the official output. Publication verifies
that output’s provenance before writing the local pin. A first architecture
can do this before it has a committed pin. The release workflow consumes a
committed official pin after this qualification. If the selected Xcode's
default SDK matches the pin, leave `sdk_args` empty. If you extracted the SDK
separately, uncomment the assignment and use its actual path.

```fish
set arch (python3 "$barc_repo/scripts/chromium_sdk_layout.py" native-arch)
set gn_cpu (python3 "$barc_repo/scripts/chromium_sdk_layout.py" native-arch --gn)
set -lx PATH (dirname "$engine_checkout")/depot_tools $PATH
set -l sdk_args
# set sdk_args --macos-sdk "/path/to/MacOSX26.5.sdk"
python3 "$recipe" build --checkout "$engine_checkout" --arch "$gn_cpu" --official $sdk_args --jobs 8
bash "$barc_repo/scripts/publish-chromium-engine.sh" --arch "$arch" --require-official --replace \
    "$engine_checkout/src/out/Barc-$gn_cpu-official" "$barc_repo/Packages/BarkEngine"
```

`--replace` replaces a previous local publication for this architecture, if
present. The shared SDK headers must still match the other architecture’s
pinned headers. Check the resulting metadata change before adopting the pin.

For a private handoff, commit the published bridge header, generated header
digest and architecture pin together on the local qualification branch. This
lets a receiver reproduce the app when a bridge change also changes the
generated header. Run the commands from `$barc_repo` with `BARK_SIGN_IDENTITY`
set to a local Developer ID Application identity.

```fish
set -l headers (python3 scripts/chromium_sdk_layout.py headers Packages/BarkEngine "$arch")
set -l metadata "$headers/barc_bridge_api.h" "$headers/barc_public_headers_sha256.h" "$headers/engine-artifact-$arch.sha256"
git add -- $metadata
git diff --cached --quiet -- $metadata; or git commit --only -m "Pin the $arch SDK for native qualification" -- $metadata

set -l handoff (mktemp -d /private/tmp/bark-official-handoff.XXXXXXXX)
set -l pin (python3 scripts/chromium_sdk_layout.py digest Packages/BarkEngine "$arch")
set -l archive "$handoff/BarkSDK-$arch-$pin.tar.gz"
set -l revision (git rev-parse HEAD)
set -l sources "Bark-source-$revision.tar.gz"
git archive --format=tar.gz --output="$handoff/$sources" "$revision"
env -u BARK_ENGINE_SOURCE python3 scripts/bark-check.py engine --arch "$arch" --require-official \
    --archive "$archive"
mkdir "$handoff/source"
tar -xzf "$handoff/$sources" -C "$handoff/source"
python3 "$handoff/source/scripts/bark-check.py" build --arch "$arch" --require-official --engine "$archive" \
    --output "$handoff/Bark.app"
ditto -c -k --keepParent "$handoff/Bark.app" "$handoff/Bark-$arch.zip"
pushd "$handoff"
shasum -a 256 "$sources" (basename "$archive") "Bark-$arch.zip" > SHA256SUMS
popd
```

Building the shell from the extracted archive includes exactly the source files
the receiver gets. Give the receiver the three archives and the producer's
`SHA256SUMS`. On the receiving native Mac, run `shasum -a 256 -c SHA256SUMS`
in their directory and check all three match. This distinguishes signed app
builds that use the same SDK. Extract the source tarball into an empty directory
or check out the revision recorded in its filename. From that source root, install
the SDK with `python3 scripts/bark-check.py engine --arch "$arch" --require-official --install --engine "$archive"`.
Unpack the signed app and compare it against the installed SDK with
`python3 scripts/bark-check.py verify --arch "$arch" --require-official /path/to/Bark.app`.
Run the native smoke and guarded walks against that app. Release preparation
uses the approved revision of the qualification metadata.

This checkout holds Chromium's downloaded sources and incremental compiler output.
Keeping it outside the application worktree lets you clear the app's `build/`
directory or retire a worktree without losing a running engine build.

`prepare` creates the pinned Git checkouts, runs gclient dependency sync and
hooks, mounts the Bark trees and applies the patches. Use `prepare --resume`
after an interrupted checkout, dependency sync or recipe application. It accepts
a pristine pinned checkout or one that already passes the exact recipe replay.
A preparation marker lets the recipe finish its own interrupted application
after checking that existing mounts and applied patches match the recipe. It
refuses a mismatched pin, altered gclient configuration or local edits. Keep
that checkout for inspection and use a new directory when you need a pristine run. The recipe never asks Git to reset or clean.
`--dry-run` prints the plan and validates available inputs without creating the
checkout or compiling.

When a Bark patch or mounted resource changes and the upstream pins stay
the same, reuse the existing checkout and its compiled objects. Supply the
Bark Git revision whose recipe you previously applied. Run from a Bark Git
checkout with the destination changes in its working tree.

```fish
python3 "$recipe" update --checkout "$engine_checkout" --from-revision "$previous_bark_revision" --dry-run
python3 "$recipe" update --checkout "$engine_checkout" --from-revision "$previous_bark_revision"
```

The preview checks actual source bytes and executable modes. The update
preserves build outputs and reports conflicting local changes before modifying
source. Repeat the same command to finish an interrupted update. A change
to the upstream pins or dependency configuration requires a fresh preparation.

`build` validates the prepared checkout again. It builds the Rust matcher and
compiler override tool, generates GN, then builds the selected engine, macOS
packaging and Bark browser tests. The developer output is `src/out/Barc-x64`
on Intel or `src/out/Barc-arm64` on Apple Silicon. Repeat the same command
to resume an interrupted build. The recipe refuses an output with different
GN arguments, so give experimental arguments their own output. Wait for any
build started outside the recipe to finish before reusing its checkout or
output.

Engine binaries, profiles, logs and outputs are local artifacts. The recipe
compiles the inputs to the publishing step below. The bytes depend on the local
SDK and Rust compiler versions.

Upstream instructions: [Chromium macOS build](https://chromium.googlesource.com/chromium/src/+/fb096c0011f9d50f0a264a9376420cdea9c421e3/docs/mac_build_instructions.md).

### Upgrade the Chromium revision

Use a local qualification branch and retain the previous SDK and source
revision. Resolve the new upstream tag to its commit and update
`PINS.json` and `CHROMIUM_VERSION`. Read `chrome/build/mac.pgo.txt` and
`chrome/build/mac-arm.pgo.txt` at that commit. If either selector changes,
fetch its exact object with Chromium’s PGO updater, verify it against the
upstream object’s checksum at the applicable encoding, and pin the SHA-256
of the decompressed profile. Check the new `DEPS` V8 revision and its
`include/v8-version.h`. If it changes, verify the versioned Google
`x64.profile` and refresh the V8 revision, version and SHA-256 in `PINS.json`.

Set `CHROMIUM_ENGINE_VERSION` for both outer app configurations in
`Bark.xcodeproj/project.pbxproj` and match the new Chromium-generated
`SCMRevision` in `ChromiumApp/Info.plist`. Staging checks the latter against
the engine’s outer metadata and the shim uses the former to load the
exact framework version.

Prepare a fresh gclient root for the new revision. If a patch conflicts,
adapt the tracked patch against the new base and repeat preparation from a
pristine root. Check the patch budget and exact replay before compiling.

```fish
set barc_repo "$PWD"
set recipe "$barc_repo/Runtime/Chromium/build_engine.py"
set upgrade_root (mktemp -d "$HOME/Library/Caches/chromium-upgrade.XXXXXXXX")
set engine_checkout "$upgrade_root/checkout"
python3 "$recipe" prepare --checkout "$engine_checkout" --jobs 8; and \
    python3 "$recipe" check --checkout "$engine_checkout"; and \
    python3 "$barc_repo/Runtime/Chromium/budget.py" --check
```

Follow [first official SDK preparation](#prepare-the-first-official-sdk-on-its-native-mac)
to publish and verify each architecture's pin. Build the signed app against
that pin. On the matching native Mac, run the engine suite from the official
output, then exercise startup and extension actions in the signed app. Use
the [signed walk environment](../../CONTRIBUTING.md#run-the-signed-ui-walks).

```fish
set -l gn_cpu (python3 scripts/chromium_sdk_layout.py native-arch --gn)
set -l src "$engine_checkout/src"
python3 Runtime/Chromium/run_browser_tests.py --checkout "$src" --binary "$src/out/Barc-$gn_cpu-official/bark_browser_tests"
python3 scripts/bark-check.py smoke --require-official build/Bark.app
python3 Tests/ChromiumExtensionActions/walk.py --require-official --app build/Bark.app --output (mktemp -d)/extensions
```

Update `extension-versions.json` after reviewing its store update query
and qualifying the new candidate.

## Bark's tree and the patches

Use a separate pristine checkout and output when establishing an unmodified
Chromium baseline. The tracked recipe builds the Bark candidate directly.

The recipe has three parts, all in this directory:

- `bark/`: every file Bark owns, mounted at `src/bark`: the C bridge and its public header
  (`bark/bridge/`), the engine entry and header digest (`bark/app/`), the content blocker,
  vault authenticator and two upstream-class definitions Bark adds (`bark/browser/`), page
  resources (`bark/resources/`), the browser tests (`bark/test/`) and the override tool
  (`bark/tools/`). The GN arg `root_extra_deps = [ "//bark" ]` loads it, so no upstream
  `BUILD.gn` names a Bark test or tool; the chrome framework links `//bark:engine`. Resource
  files that other packages own are symlinks into those packages. The recipe copies
  their contents into the mount.
- `chromium_src/`: overrides, mounted at `src/chromium_src`; its `README.md` holds the rules
  for writing one. The args set upstream's GN arg `cc_wrapper` to the redirect tool
  `bark/tools/override_cc.c`, which the recipe builds into the output directory. The tool puts
  `chromium_src` first on every compile's include path and compiles `chromium_src/<path>`
  instead of `<path>` when that exists. Setting or clearing `cc_wrapper`
  changes every compile command, so either costs one full rebuild.
- `patches/`: one patch per upstream file, at `patches/<upstream path>.patch`. A patch only
  adds hooks to upstream files; it never creates, deletes or renames a file, and patches do
  not depend on each other's order.

`BUDGET.json` caps what `patches/` and `chromium_src/` change upstream: patch files, upstream
files, hunks, added lines, override files and files under `ui/views`, `content/`,
`android_webview/`, `tools/metrics/` and upstream tests. `budget.py` prints the counts and
`budget.py --check` fails above any cap, so raising one is a reviewed change.
`CHROMIUM_VERSION` names the pinned version the patches apply to.

The build compiles `libnook_adblock.dylib` from
`Nook/ThirdParty/AdblockRustFFI/`, using the tracked exports list and the engine's
macOS deployment floor. The installer target produces `Bark Packaging/` with
the signer and per-process entitlements from the pinned engine source.

`build_engine.py check` uses `replay_gate.py` to replay the pinned upstream tree,
Bark mounts and patches in a throwaway Git index. It fails if the checkout
differs, apart from the generated Rust matcher. You can also run the replay
directly against the source root when depot_tools is elsewhere:

```fish
python3 "$barc_repo/Runtime/Chromium/replay_gate.py" "$engine_checkout/src"
```

### Native application

`Bark.app` is the outer bundle: the `BarkApp` target owns its executable
and `Info.plist`, and `Bark Framework.framework` is nested inside it. `BRANDING`
sets the product name, the integrated app and framework bundle identifier
`ee.qdo.bark`, and the helper names. Its patch is
`patches/chrome/app/theme/chromium/BRANDING.patch`.
It does not reach `chromium_strings.grd`, so that file's patch sets the product name, helper name, window title
formats and macOS permission reason there. Changing a translatable message drops its
translations, so those strings show in English in every locale. The file's other
messages still say Chromium.

Application launch requires runtime-ready/lifecycle hooks and
`NookNativeShell.framework`. `ChromiumApp/main.cc` links only libSystem. It registers
the early malloc zone, loads the engine framework, then the shell's fixed bundle-local
entry; `ChromeMain` owns the sole application loop. Helpers keep Chromium's own main.
There is no core-only application launch path or WebKit fallback. Its copy of the
zone registration must match the pinned revision, and `CHROMIUM_ENGINE_VERSION` in the
target's build settings must match `chrome/VERSION`. The app enters the engine through
`barc_engine_main_v<N>` and calls it only through the table `barc_bridge_v<N>()` returns; both
names carry the bridge version, so an app and framework built for different versions abort
in main with a message naming the version the app needs. main also aborts when the table is
smaller than the app's `struct BarcBridge`, then hands the table and the entry to the shell's
`barc_native_main`. The shell calls `dlsym` for nothing. `ChromeMain` stays exported for the
helpers.

The raw GN output also has the `Bark.app` filename because the build tools use
its bundle layout. Its executable exits before loading AppKit or the engine,
and its background-only bundle uses `ee.qdo.bark.sdk` without URL or document
handlers. Publish the generated integrated app metadata alongside the framework.
After linking and before writing an official build receipt, the build recipe
checks the requested thin architecture, both property lists, and the raw
launcher's refusal-only library and symbol imports. When the launcher matches the host CPU,
the recipe also exercises all five direct invocation cases, including when
Python runs under Rosetta. Cross-builds report static inspection.

For a private cross-build handoff, copy the launcher and its two property
lists from the same completed GN output into a separate test archive. On the
builder, set `gn_cpu` to the target (`arm64` or `x64`) and use the handoff
directory prepared above.

```fish
tar -czf "$handoff/launcher-check-$gn_cpu.tar.gz" -C "$engine_checkout/src/out/Barc-$gn_cpu-official" \
    Bark.app/Contents/MacOS/Bark Bark.app/Contents/Info.plist gen/chrome/chrome_integrated_app_info_plist.plist
```

On the target Mac, extract those three files in a temporary directory and run
the check from the matching Bark source. Omitting `--arch` requires a launcher
that matches the physical Mac and exercises all five direct invocations.

```fish
set -l launcher_check (mktemp -d)
tar -xzf /path/to/launcher-check-arm64.tar.gz -C "$launcher_check"
python3 Tests/ChromiumSDKLauncher/check.py "$launcher_check"
```

The developer SDK and signed Bark app exclude this private qualification archive.

### Publishing the engine

The app compiles against the `Packages/BarkEngine` binary target. At runtime, `main`
opens the selected engine framework after registering the malloc zone and finds the bridge table.
The `BarkEngine.xcframework/macos-arm64_x86_64` slice contains one universal static library
with no exported symbols and one copy of the public C header `barc_bridge_api.h` from
`bark/bridge/`. The architecture-specific digests live beside it as
`engine-artifact-x86_64.sha256` and, once qualified, `engine-artifact-arm64.sha256`.
The separate, ignored `Packages/BarkEngine/RuntimeArtifacts/<architecture>/Engine/` directory
holds the exact framework, `Bark Packaging`, engine `Info.plist`, public header and
`SHA256SUMS`. The shared public header is identical for both architectures.

The Intel pin is available. The app executable and full Swift/AppKit shell have
been built for both architectures from the universal headers. A signed ARM64 app
requires a separately published and qualified ARM64 runtime pin.

| Component | Intel | Apple Silicon |
| --- | --- | --- |
| Bark launcher and Swift/AppKit framework | Thin Release build, signed with the Intel SDK | Thin Release cross-build on Intel |
| Chromium and its child processes | Pinned x86_64 SDK | Native SDK receipt and on-device testing pending |
| Rust adblock library and C SDK link library | x86_64 slice | arm64 slice |
| Sparkle framework, updater and XPC services | x86_64 slice | arm64 slice |

Staging and signed verification inspect every Mach-O file in the app. The launcher,
native shell and Chromium framework must match the target architecture exactly.
Other embedded frameworks and services can be universal if they include that
architecture. The Release shell weak-links FoundationModels and checks system
model availability on macOS 26 or later. Its locked package graph has no MLX dependency.

The existing Intel SDK cache at `~/Library/Caches/BarkSDK/<digest>/Engine` is unchanged.
The resolver also accepts an existing local Intel `Engine/` directory and legacy Intel
digest under `BarkEngine.xcframework/macos-x86_64/`.

The framework exports three Bark symbols: the entry, the table and the header digest. The
table, `struct BarcBridge`, holds every call the app makes; Swift takes each member's type from
the header. The table and every struct that crosses the bridge start with `size`, as the
header describes, so a field added at the end needs no new version. Until a release relies on
that, main still requires the exact header: publishing refuses an engine unless siso's record
of the last build (`siso fs export`) shows it compiled the same `barc_bridge_api.h` as
`bark/bridge`, and no later change to it. It reads that record, not the source tree, because
the tree may have moved on since the build. Staging refuses an app compiled against another
header than the one in `Engine/`. The engine also exports `barc_public_headers_sha256`, a
digest of the header it compiled that `//bark/app:public_headers_sha256` computes with
`barc_public_headers_sha256.py`. Publishing writes the same digest as
`barc_public_headers_sha256.h` beside the published header, and `main.cc` aborts before the
shell loads when the engine's digest differs from the one it was compiled with.

#### Upgrade a bridge shared by two pinned architectures

Build the new bridge from the same source revision on both native Macs. Keep
the accepted package headers and pins available until you have verified the
next pair. On each builder, publish into its own empty package directory:

```fish
set -l arch (python3 scripts/chromium_sdk_layout.py native-arch)
set -l gn_cpu (python3 scripts/chromium_sdk_layout.py native-arch --gn)
set -l handoff (mktemp -d /private/tmp/bark-sdk-pair.XXXXXXXX)
set -l package "$handoff/Package"
bash scripts/publish-chromium-engine.sh --arch "$arch" --require-official \
    "$engine_checkout/src/out/Barc-$gn_cpu-official" "$package"
python3 scripts/chromium_sdk_layout.py headers "$package" "$arch"
python3 scripts/chromium_sdk_layout.py artifact "$package" "$arch"
```

The publisher writes a sealed `Engine` directory. From each builder, copy
`SHA256SUMS`, `official-build.json` and the `Headers/` directory from that
Engine into a separate transfer directory. These files are enough to stage
the two pins. A complete Engine directory works as input too.

From a private checkout of the new app and engine source, run:

```fish
python3 scripts/bark-check.py pair-sdk \
    --x86-64 /path/to/intel-transfer --arm64 /path/to/arm64-transfer \
    --package Packages/BarkEngine
```

This checks each receipt against the target architecture, current engine
recipe and framework hashes recorded in its manifest. It checks the API and
generated digest header and installs both pins and headers together. The
pins are calculated from the original manifests. Full SDK verification on
each receiving Mac follows below.

Send this staged metadata to both builders. From that source snapshot, each
builder can write its archive using the Engine path printed above.

```fish
set -l engine (python3 scripts/chromium_sdk_layout.py artifact "$package" "$arch")
set -l archive "$handoff/BarkSDK-$arch.tar.gz"
python3 scripts/bark-check.py engine --require-official --arch "$arch" \
    --engine "$engine" --archive "$archive"
```

A receiver with the staged metadata verifies each archive with
`python3 scripts/bark-check.py engine --require-official --arch "$arch"
--engine "$archive"`. Perform native signed qualification for each
architecture before committing the two headers and both pins together. One architecture can still be published independently
when its public headers already match the other accepted architecture.

The app target copies its outer resources from `ChromiumApp/Resources`. Bark owns
its display name, declared app and document artwork, and localized bundle identity.
The SDK publisher checks the scripting definition, policy manifest, copyright and
localized permission descriptions against the engine. Helper icons and the engine's
internal assets stay inside the pinned framework.

Bark’s macOS resource build applies its product name to translated browser labels
before Chromium packs them into the framework. Given a prepared checkout, compare
the generated labels with a staged or signed app, including its installed locales
and grammatical-gender variants. The same command checks that the installed About
page shows the engine version and credits and leaves update checks to Bark’s app menu.
Use the output directory for the app's architecture.

```fish
set -l src "$engine_checkout/src"
python3 Tests/ChromiumWebUIBranding/check.py "$src" "$src/out/Barc-x64/gen/bark/app" --app build/Bark.app
```

The outer bundle and native shell inherit the project's `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION`. A release can set its own app version and Sparkle build
number. `BarkChromiumVersion` records the independent Chromium version and staging
checks it against the actual framework. The localized Info files leave the app's
version to the bundle metadata, so a release number works across all locales.

`Engine/` is read-only, because Python writes bytecode beside the signing tools and any new
file fails its checksums at the next staging. From the engine source root, with depot_tools
on `PATH`, publish the architecture you built. The publisher defaults to native hardware.
For a cross-build, pass `--arch x86_64` or `--arch arm64` and the corresponding GN output. It checks
each Mach-O in the framework and writes only the selected architecture’s artifact and pin.
If the other architecture already has a pin, the public headers must match it.
The publisher verifies a complete read-only SDK before publishing it. Repeating the
same publish verifies the installed local artifact. Pass `--replace` to publish a
different build over the same local destination or repair an incomplete older artifact.
An interrupted publish resumes on the next invocation. Existing cached SDK versions
are unaffected. Commit the public headers and matching pin after validation:

```fish
set gn_cpu (python3 "$barc_repo/scripts/chromium_sdk_layout.py" native-arch --gn)
bash "$barc_repo/scripts/publish-chromium-engine.sh" "$PWD/out/Barc-$gn_cpu" "$barc_repo/Packages/BarkEngine"
```

### Building the app

From the app repository root, point the contributor command at a verified SDK and select a Developer ID Application identity installed on the Mac. The Swift shell and app target compile against the checked-in public headers. The build uses the matching SDK's signing tools and the app's tracked `ChromiumApp/Additions.plist` to sign the complete bundle.

```fish
set -lx BARK_ENGINE_SOURCE /path/to/Engine
set -lx BARK_SIGN_IDENTITY 'Developer ID Application: Your Name (TEAMID)'
python3 scripts/bark-check.py build
```

The result is `build/Bark.app`. The command accepts an empty or absent `build/` directory and verifies the signed app against the engine pin before placing it at the destination. A successful rebuild replaces the previous app at the same path. The contributor commands default to the Mac’s native hardware architecture. Use `--arch` to select a different pinned architecture for `engine`, `build`, `verify`, or `package`. `smoke` and `launch` require the native hardware architecture.
Keep build inputs in Git and the verified SDK in the versioned cache. The engine recipe, SDK headers, Xcode project, package lockfile, resources, staging and local signing code all live in the repository.

Do not sign or launch a partially staged bundle. The framework requires its
standard FMWK Info.plist, `ee.qdo.nook.NativeShell` identity, version-A executable,
Assets.car, default.metallib and exported `barc_native_main`. Preserve sandbox,
hardened-runtime, helper entitlements and library validation throughout staging
and signing. The signing patch retains pre-submission signature verification and
moves Gatekeeper assessment after awaited notarization; it does not confer
notarization or release acceptance.

Staging refuses an engine framework that holds other than one `libnook_adblock.dylib`. After
signing, `bash scripts/stage-chromium-app.sh --check-signed <signed Bark.app>` checks the same in
the whole bundle and fails on any unsigned Mach-O file; `codesign --verify --deep --strict`
passes with an unsigned library the signing config doesn't name.

The native application supplies `--barc-native-shell` and
`--barc-shared-native-window` through its validated startup configuration. Verify
only with a fresh `/private/tmp` synthetic app root and explicit profile UUID;
never use a real profile. Patch application, compilation and mechanical tests do
not establish native interaction, media, profile isolation or release readiness.

### Opt in to Bark iCloud signing

Ordinary Developer ID builds require no provisioning profile and leave CloudKit
disabled. To enable it, supply a current Apple-issued macOS Developer ID
distribution profile for the explicit `ee.qdo.bark` App ID. It must authorize
`iCloud.ee.qdo.bark`, production CloudKit and production push, and include the
Developer ID Application certificate used for signing.

```fish
python3 scripts/bark-check.py build --icloud-profile /path/to/Bark.provisionprofile
python3 scripts/bark-check.py verify build/Bark.app
```

Build and signed verification check the embedded profile, certificate and outer
app entitlements. The native shell runs in that app process. This verifies the
local signing prerequisites. A live sync also needs the production CloudKit
schema and a signed-in iCloud account. For the manual
**Prepare Bark Candidate** workflow, the `icloud` input defaults to enabled. Set the
`BARK_ICLOUD_PROFILE` configuration variable in the architecture’s protected
Actions environment to the profile’s absolute path on the trusted runner. The workflow fails without that file when iCloud is
requested.

### Prepare Bark distribution files

Choose the architecture and corresponding pinned SDK. Use a positive build number
that increases on that architecture’s Sparkle feed, including when the Chromium
version changes. Use the intended HTTPS feed and download directories for that
candidate. The build embeds the architecture-specific feed URL and the existing
pinned Sparkle public key before signing.

Set the variables below for the candidate and use a fresh output directory.

```fish
python3 scripts/bark-check.py build --require-official --arch "$bark_arch" --engine "$bark_engine" \
    --identity "$signing_identity" --output "$bark_app" \
    --release-version "$bark_version" --build-number "$bark_build" \
    --feed-base-url "$bark_feed_base_url"

python3 scripts/bark-check.py package "$bark_app" --require-official --arch "$bark_arch" \
    --engine "$bark_engine" --identity "$signing_identity" \
    --output "$bark_candidate_directory" --download-base-url "$bark_download_base_url" \
    --ed-key-file "$sparkle_key_file" --notary-profile "$notary_profile"
```

Choose a path ending in `Bark.app` for `$bark_app`. The package command
re-verifies its embedded SDK and produces
`Bark-<version>-<build>-macos-<arch>.dmg` and `bark-macos-<arch>.xml`. The
notarytool profile enables notarization and stapling of the app and image.
Use the private key matching the pinned public key. `--ed-key-file -` accepts
it on standard input. Keep the key out of command arguments and logs.

These commands and the [manual preparation workflow](../../CONTRIBUTING.md#prepare-a-bark-distribution-candidate)
prepare files for review. Before publication, verify the installed app and an
update from the previous release on the matching native Mac. If approved for
publication, make the DMG available at the appcast’s enclosure URL before
making that appcast available on the Bark feed. The public Nook transition feed
continues on its existing URL.

### Regression scope and remaining qualification

The maintained `bark_browser_tests` target in `bark/test/BUILD.gn` includes
`BarcBridgeBrowserTest`, `BarcSharedNativeWindowBrowserTest` and
`BarcFourPaneBrowserTest` in
`barc_bridge_browsertest.mm`, `BarcProfilesBrowserTest` in
`barc_profiles_browsertest.mm`, `BarcNativePolicyBrowserTest` in
`barc_native_policy_browsertest.mm`, and `BarcExtensionFocusBrowserTest` in
`barc_extension_focus_browsertest.mm`, plus `BarcExtensionDialogBrowserTest` in
`barc_extension_dialog_browsertest.mm`, and `BarcExtensionStorageBrowserTest` in
`barc_extension_storage_browsertest.mm`. Derived fixtures also cover startup,
discovery, private commands and site data. The target uses Chromium's existing
`browser_tests_runner`, `test_support` and `test_support_ui`, with no custom
runner or registration in monolithic `browser_tests`. Inspect the generated
graph/incremental estimate and compile added objects before committing to its
separate build. From the Bark repository, run the suite against your Chromium
checkout on an unlocked console.

```fish
set chromium_src /path/to/chromium/src
python3 Runtime/Chromium/run_browser_tests.py --checkout "$chromium_src"
```

The runner selects the native developer build. Pass `--binary` for an official
build or another native output directory.
Add `--filter 'BarkWindowHostDefaultBrowserTest.*:BarkWindowHostLegacySwitchBrowserTest.*'`
for a focused run or `--summary` with
a new output path for Chromium's JSON results. The launcher uses a disposable
profile for each test, the mock keychain, one test at a time and zero retries.
The runner takes the shared `/private/tmp/nook-screen-lock` mutex and stops
when hardware input resumes, the console locks, or the mutex is replaced.
Exit status 3 indicates that the screen is unavailable. After a forced
termination, inspect the recorded PID and its test processes before clearing
an abandoned mutex.

Before taking the screen mutex, the runner inspects the Mach-O image of the
test executable and both framework copies in the output directory. All three
must match the Mac’s hardware architecture and contain the capability emitted by the
host-only Mac window factory. The same capability can be inspected offline in
a thin Intel or Apple Silicon image without executing it.
Stage the whole test runtime from one build. Historical browser-test binaries
can open classic Chromium windows and are rejected before launch.

Some legacy fixtures still assert details of the retired window. They remain
migration work and are excluded from current host-only qualification claims.

| Existing fixture | Required Bark test port |
| --- | --- |
| `BarcExtensionStorageBrowserTest` presentation-specific cases | Verify selected extension/settings pages are mounted during prompt visibility, ownership and close checks. The shared host widget and per-profile worker and storage assertions remain. |
| Legacy cases in `barc_bridge_browsertest.mm` | Replace sidebar and header attachment, `BrowserWidget` lifetime and modal anchors, and composed split and Peek views with Bark root, page placement and discovery assertions. Old peer-BrowserView, classic toolbar, and physical split-layout expectations describe retired implementations. |

The updated host fixtures cover enterprise capture on selected and mounted
pages, detached-pane focus, extension sheets and logical-owner lifetime,
private command admission, and root lifetime. The application launch fixtures mount
the selected page in a Bark root and exercise early URLs, Dock reopen, and
commands received while no window is visible. Check their results against the
marked host-only binary. Pre-cutover runs qualify only the older runtime.

These regressions encode transfer/draft/scroll/history, profile binding,
shared-window selection/lifetime and native policy cases; their presence is not
a passing runtime result. Before G1 qualification, execute input/resize/focus/IME,
settings/extension component state, ordinary/last-tab transfer, stale IDs,
hidden-page animation and draft continuity, renderer recovery and clean quit
on an unlocked console with isolated stores. Keep release qualification separate
from baseline compilation, candidate compilation and test-object compilation.

The extension focus case loads the same synthetic MV3 extension into both real
profiles and checks actual focus events while the native window remains key.
It enables upstream UI controls before base setup to prevent the harness from
swizzling `NSApp.keyWindow` and simulating focus notifications. Use the normal
launcher, which isolates each test in its own child, with one job to avoid
competing native windows; do not use `--single-process-tests` for this suite.
Its unpacked test loader does not qualify store installation or permission UI.

Bark reads extension actions from the selected page's Chromium toolbar model.
Site Controls shows the current title, badge and pin state. Pinning writes to
the owning profile. Pinned actions appear beside the address in either toolbar
placement. The bridge checks the selected client, tab and mounted view before
invoking an action. A profile switch dismisses the outgoing extension popup.

Run `python3 scripts/bark-check.py extension-actions` to exercise the Swift
consumer against a test bridge. The engine regressions load an unpacked MV3
extension and cover script-initiated and DevTools actions, policy-enforced
pinning, and closing the window during action enumeration.

The signed-app walk installs a local fixture through Manage Extensions and
opens its pinned action from both toolbar positions. Canceling removal keeps
the fixture in the manager. Confirming removal clears it. After each choice
the walk returns to the same source window and reloads its page.
[Run the signed UI walks](../../CONTRIBUTING.md#run-the-signed-ui-walks)

The storage suite also exercises a synthetic signed permission-increasing update
and actual `permissions.request()` calls from workers and extension tabs. It
checks owned dialog presentation, stale-owner cancellation and profile-local
grants using upstream test installation/gesture helpers and programmatic dialog
buttons after the normal button delay. These are mechanical routing checks;
native input and ordinary store installation/update remain separate cases.
The native-messaging case uses upstream's echo subprocess and isolated user/system
host directories to check per-profile ports, origin rejection and channel cleanup
after disconnect/disable. It does not establish host-process exit, profile
deletion, vendor discovery or installed distribution behavior.
The renderer-failure regression kills Work's renderer, checks Personal's live
state, then recovers Work through same-URL bridge navigation. It does not test
a dedicated Reload command or measure memory reclamation.

Media controls observe the exact page's existing MediaSession without creating
sessions for idle pages. Playback commands require that session's advertised
actions and preserve background ownership. Unknown state disables transport
controls while retaining the prior player; document replacement clears it.
This observation does not establish upload, capture or discard eligibility.

The changed Views ownership/close paths also require the existing
`views_unittests` target. After the candidate build exits, build that target in
the same output and run the retained-client cases plus nearby upstream
destruction, reentrant close, veto and frame-layout regressions:

```fish
autoninja -C out/Barc-x64 -j 8 views_unittests
set views_filter 'ClientOwnsWidgetTest.*:WidgetObserverTest.CloseReentrancy:DesktopWidgetTest.CloseRequested_*:DesktopWidgetTest.SingleWindowClosing:WidgetTest.ReplaceClientContentsView:DialogClientViewTest.LayoutAfterCloseWithDetachedDelegate:DefaultFrameViewTest.GetNonDecoratedClientAreaBoundsInScreen:WidgetTest.RetainedClient*:WidgetTest.PhysicalCloseFinalizesRetainedDelegates'
out/Barc-x64/views_unittests --gtest_filter="$views_filter" --gtest_list_tests
out/Barc-x64/views_unittests --test-launcher-jobs=1 --test-launcher-batch-limit=1 --test-launcher-retry-limit=0 --gtest_filter="$views_filter"
```

The pinned source supplies 16 selected cases, including all four
`ClientOwnsWidgetTest` cases. Check their names against the actual binary's list;
an empty or partial selection is not a pass. Run each case in a separate child
without retries so one crash does not skip later cases. These tests do not establish
Browser/Profile ownership, grouped beforeunload or real native focus, which
remain separate browser-test and installed-build requirements.

Profile creation validates/canonicalizes UUIDs and resolves the immediate
user-data child `Barc-<uuid>` through ProfileManager without active/default
fallback. Callers must revalidate UUIDs against the app model; reported identity
comes from the actual manager-owned Profile. Browser-bound lookup lives in that
Browser's unowned-data host and clears at view destruction. Profile deletion,
reassignment and complete shared-window behavior remain unqualified; this is
not permission to relax the compatibility matrix.

### Native startup storage

Normal native startup uses `~/Library/Application Support/NookChromium/App` and
`Engine`, with a separate `ee.qdo.nook.chromium` preferences domain. It does not
import or reset legacy Nook stores. Explicit `--barc-app-data-dir` plus
`--barc-app-profile` remains temporary-root verification with mock keychain and
isolated preferences; neither mode enables cloud sync.

Normal startup requires bridge version 12 before ChromeMain. Native registration
sets `NookChromium Safe Storage` / `NookChromium` through Chromium's existing
configurable key-storage seam before providers start. Encryption and denial
handling remain upstream; there is no lookup fallback to Chromium's default
item. Kagi uses a separate `NookChromium Kagi Session Link` service. Verification
credentials stay in memory.

Startup reuses saved window IDs, profiles and selection. The implementation
loads the visible selection or two-to-four same-profile split panes while
leaving unrelated pages unloaded. Unsupported cross-profile layouts stay
unmodified and are refused until their native presentation is available.
Additional factory windows stay hidden until exact page/header admission. Failed
restores keep their saved record; an already-bound live owner stays registered
until actual group disappearance, including pending/refused close.

The matched framework requires `barc_set_runtime_close_callback`. Accepted quit
flushes saved windows before native session/window teardown; a later veto resumes
model operations and window admission. This is distinct from the first quit
attempt, which may still fail beforeunload/download consent. Source/fixture
checks do not qualify real multiwindow quit cancellation until engine execution.

### App-owned window lifetime

The app hands each product window to itself with `barc_window_set_app_lifetime`. From then
on a client whose last tab closes or moves out stays open and selected, reports
`BARC_DISCOVERY_EMPTY_STRIP` and takes new tabs: the `unload_controller.cc` and `browser.cc` hooks keep its
`UnloadController` idle and returns from `Browser::TabStripEmpty` before the close. The window
still closes through `barc_window_close` of its last client, its close button or quit, with
their prompts. `barc_tab_select` refuses bridge callbacks, because `TabStripModel::ActivateTab`
CHECKs reentrancy in every build type and those callbacks can run inside a strip change.

### macOS browser windows

The macOS window factory in `browser_window_factory.cc` creates a `BarkBrowserWindow` for each
admitted browser, including windows created by Chromium itself and by browser tests. Normal
windows use the full Bark layout. Popups, installed app windows and undocked DevTools use a
compact host. Bark private windows use a named ephemeral session. An unsupported window type
or private identity is refused during creation.

Bark mounts a Swift/AppKit root with `window_set_root_view`. That attachment replays any
pending request to show the window, including the request to show it inactive. The app places
each live Chromium page view in the root with `tab_native_view`. The host reports view retirement
and full-screen changes through `window_host_observe`. The selected client and its exact
mounted root identify the controls that may act on the page.

The integrated app accepts the default window configuration or an explicit
`--bark-window=host`. It rejects other values before starting Chromium.

### App-owned keys

In native application mode a key reaches a Chromium command only when the command acts on
the shown page (find, zoom, reload, stop, print, devtools, view source, back and forward),
edits, or asks the app for a window (New Window and New Private Window). The app owns every
other key, even one it has no action for. On Mac a key reaches commands four ways, and
the hooks in those four places apply the rule to each: `ChromeCommandDispatcherDelegate` before
and after the page or field sees the key, the main menu's key equivalents (a key swallowed
after the page never reaches the menu; with no browser window key, `AppController` drops a
key equivalent but still runs a click), `BrowserView::LoadAccelerators`, and the renderer's
shortcut reservation. Close Window and Quit keys still reach AppKit's `performClose:` and
`terminate:`, which ask the app. New Window and New Private Window, from any key, menu, the
Dock or a page's command, reach the app through `barc_set_runtime_window_request_callback`;
Chromium opens no window or New Tab page for them. Dock reopen still shows the window the
browser target names. `barc_window_set_page_hidden` marks a physical window that
shows no page, as on an empty space: its page commands then do nothing from keys or the menu.
Keys Chromium reserves from pages, such as Close Window's, still never reach the page. A key
the app owns goes on to the main menu when the app answers that item itself, as it does Downloads.
A window showing an empty space selects a client with no tab, where Chromium runs no command:
New Window and New Private Window still reach the app from it, and `AppController` no longer
reshuffles Close Tab and Close Window by the selected client's tabs, since the app installs both.
`barc_tab_close_selecting` names the tab Chromium shows when the page actually closes, so a
page with a beforeunload listener shows the app's pick, and "Leave site?" keeps the page shown
until it is answered. The app's sidebar and panels are AppKit fields
inside Chromium's content view, which answered `undo:` and `redo:` for its own views fields
only, so Cmd+Z did nothing there; it now answers them only while a views field is editing,
and the window reaches the field's undo.

### Native launch routing

The matched framework requires `barc_set_runtime_browser_target_callback`.
Positional inputs reach Chromium's StartupTabProviderImpl and existing startup
navigation/validation, with no legacy AppDelegate. Early URLs stay in
AppController's StartupTabs; one async resolution spans validation/profile load.
Temporary opening requeues there until posted discovery/admission availability,
without a second owner or URL replay. Shutdown clears borrowed callbacks and
cancels pending delivery. New Window uses the exact live model owner or an
existing regular model UUID; Dock reopen shows that admitted owner when present.

Site-routing rules select their space/profile; the existing external-link
preference otherwise selects an ordinary space or a native Chromium mini popup.
The existing StartupTabs queue retains validated requests until the exact blank
page has model/header admission, then navigates that same page. Closing or moving
a pending page never redirects its request into another document. Mini promotion
retains the live PageSession, native page and opener through model admission.
The mini header provides Cmd+O, native URL sharing and a destination menu.
Same-profile destinations retain the live page; another regular profile opens
an explicitly labelled copy and leaves the original mini open. Private minis
cannot copy into regular profiles. Physical key and sharing-picker interaction
remain unqualified by the adapter checks.
Forced-incognito regular-profile launches fail closed before stock OTR creation;
preserving that managed profile's policies in an independent private session is
unfinished. Real LaunchServices/AppleEvent/key delivery and engine execution of
the new browser cases remain unqualified by source/fixture checks.

### Installed signing proof

The native product is a standard versioned
`Contents/Frameworks/NookNativeShell.framework` bundle. The app's main opens
`Versions/A/NookNativeShell` after loading the engine framework. Keep its
Info.plist and native resources (including Assets.car) inside that framework's
Resources, separate from Chromium's resources. The explicit native signing part
signs the framework container and infers `ee.qdo.nook.NativeShell` from its
Info.plist; it supplies no bare-library identifier override.

After the candidate build succeeds, use the staged `Bark Packaging`
tools with Python 3.11 or newer. Set `signing_identity` to the existing Developer
ID Application identity and `notary_profile` to the existing notarytool Keychain
profile. Keep credentials out of arguments and logs; the profile name is enough.
After successful complete staging above, sign from the staged copy:

```fish
set signed_out "$barc_repo/build/native-signed"
python3 "$staging_input/Bark Packaging/sign_chrome.py" \
    --identity "$signing_identity" --input "$staging_input" --output "$signed_out" \
    --notarize staple --notary-arg=--keychain-profile --notary-arg="$notary_profile"
```

Use normal Developer ID signing for this gate. The upstream `--development`
option injects `get-task-allow` and skips Gatekeeper assessment, so it cannot
qualify the installed proof. Preserve the generated helper entitlements and
complete versioned framework layout. When a release includes bookmark sync,
use the Bark production provisioning profile through the iCloud signing steps above.

Verify the produced DMG, install its complete app in an isolated location
outside the build tree, and require strict signature checks, stapler validation
and Gatekeeper acceptance there. Launch that exact executable with a fresh
synthetic user-data directory and keep the Chromium sandbox enabled. Inspect
helper ownership, resources, profile/extension behavior and clean shutdown.
Repeat with native ARM artifacts on Apple Silicon. These commands are prepared
inputs; no installed or notarized result is claimed by this document.

The private-session bridge creates a separate Guest parent and primary OTR for
each independent session. The native app admits only that actual session identity,
keeps private tabs out of persistent app state, and retains live pages during
same-session window transfers. Factory windows stay hidden until their model,
selected page and native header are attached. Native New Incognito and private
context links use independent sessions; unsupported stock Guest, profile-picker
and synchronous OTR paths cannot bypass admission. Its tests cover session
cookies/site grants, popup
inheritance, final object/metadata disposal, rejected installed extensions even
with regular-profile incognito permission, and unused/failed creation cleanup.
Disk/crash cleanup, PDF rendering, detached private surfaces and actual native
input/menu delivery remain unqualified; PDF registration alone is not
rendering evidence. The popup regression separately checks JavaScript opener
messaging and live state through same-profile transfer, plus `noopener`; its
separate native popup window does not qualify Peek integration.

The page-command bridge dispatches find, zoom, print and DevTools only to the
exact selected native owner and tab, with Chromium's command/policy checks.
Inspect Element uses Chromium's existing inspector command through the same checks.
Background-tab mute preserves selection and reports actual state through the
existing observer. App shortcuts use the existing shortcut manager and reject
stale targets; they do not create WebKit pages or use its extension dispatcher.
Audibility and mute do not establish capture or discard eligibility. Full native
shortcut delivery, printing and DevTools presentation still need qualification.

The split hooks extend the existing same-profile tab collection and Views
content containers to two through four ordered live panes. The split C boundary
validates exact logical owners, ordered handles, orientation, normalized dividers
and active pane; Chrome pin/group rules follow the first pane. Native resize
completion persists all divider positions. Member lookup reads retained split
collections without selection; cleanup requires the exact opaque collection
identity, member order and geometry, so a recreated group wins over stale cleanup. All four container views are constructed
before feature-controller enrollment; unused panes stay hidden and unbound. This
adds two empty view trees, not extra pages; its allocation cost is unmeasured.
The app-controlled split hooks
then replace that collection in native windows: every split, same-profile, cross-profile or
private, is the app-positioned presentation of independent tabs, which `BarcSplitLayout`
reports as `BARC_SPLIT_PHYSICAL` with a generation and no collection. Peek covers the whole split and dims its panes with a compositor layer;
an inactive pane's link selects that pane first. `barc_tab_enable_peek` takes a mask, so
Option-click, and Shift-click when the app setting allows it, request Peek instead of a
download or a window. Chromium's own split commands and menu items are gone from native windows.

The profile-reassignment hooks extend the existing profile deletion helper
with a close-admitted pause before data cleanup. The application commits the
space assignment and source record before allowing cleanup to continue. Unmarked
orphaned source bytes remain pending; missing metadata is not permission to wipe
them. Its browser tests and the integrated startup recovery path still require
runtime qualification.

The content-blocking hooks add native website network matching to the
existing extension WebRequest proxy. One process policy owns immutable serialized
rules; each actual regular/private context owns its mutable matcher. Startup
registers unresolved policy before ChromeMain; enabled requests wait for the
required source token, while disable releases them without waiting for a build.
Exact-document tab exceptions do not extend to frame-less shared/service workers
or extension-owned requests. Extension cancellation and native cancellation remain
independent. Request bodies stay lazy until a matching extension listener asks
for them. The captured private context-menu URL stays on its existing blank-page
intent until exact context/model admission; cancellation never loads a replacement.

The Intel C-only dylib above uses the same pinned adblock-rust serializer as the app,
with an additive method-aware C entry point. The WebSocket hooks
handle WebSocket admission; the cosmetics hooks deliver document-bound
cosmetics and scriptlets before page scripts. These share the existing blocker
policy and preserve extension rules. Native blocked-page Continue has a separate
patch and runtime cases. Source integration does not qualify ARM.

The native matcher dylib has a fixed loader-relative install name and explicit C
exports. GN copies it into the framework's existing `Libraries` directory and
into the test executable's `Libraries` directory; the normal signing manifest
names it explicitly. Rust internals stay in that two-level Mach-O namespace.
Browser helpers map the library image too, but only actual profile contexts
construct matchers. No helper-private memory or throughput result is claimed.

Native blocked-page notices use Chromium's existing InfoBar container. Only a
current native main-frame denial records provenance; a generic extension error
does not. The matching failed navigation emits a typed notice, and the native
button sends a typed action to the exact app page. The app publishes its existing
tab exception before retrying. Queued actions revalidate page/profile/navigation
ownership; the native UI has no separate exemption store or page-script binding.

Authenticated live folders and Gmail favorites use fixed native GET routes in
the owning regular profile's default storage partition. Cookies stay in Chromium;
redirects are reported without following them or saving response cookies. Reads
are bounded to two per profile, eight globally, 4 MiB and 20 seconds. Existing
folder and favorite tasks serialize their respective batches and join repeated
refreshes; profile reassignment, deletion and cancellation reject stale results.
The profile settings' Password Manager link uses the same exact-profile utility
page admission as the other Chromium settings links.

DevMCP screenshots share the existing observation-owned capture slot with tab
thumbnails. Screenshots return JPEG at up to the requested width (1200 pixels by
default), bounded to 4096 pixels per dimension, 8 Mi pixels and 8 MiB encoded.
Hidden pages supply only an available retained viewport, identified as the last
rendered image; capture never shows the page or requests hidden painting.
Encoding runs off the UI thread. Cancellation suppresses publication and holds
the slot until the compositor/encoder retires, preventing overlapping copies.
Document, profile, owner and browser capture policy are checked before delivery.
The product Copy Screenshot menu and shortcut use the same capture at up to
4096 pixels wide. Clipboard publication additionally requires the original
document and front window to remain current and the clipboard to be unchanged
since the request; capture failure preserves the clipboard.

The fixed Boost picker owns one isolated controller on the observed top document.
Its explicit cancellation also runs DOM cleanup; pagehide/hidden cleanup prevents
a picker returning through history. Only trusted input can choose a selector,
bounded to 2048 UTF-8 bytes and 32 ancestors. It neither navigates nor exposes a
generic page-to-native channel. Cancelling a script evaluation is not a substitute.

Pawl password and OTP filling uses Chromium's parsed Autofill fields and typed
password-driver calls. A one-use capability binds the exact field, document,
profile and native owner. Only a direct choice in the existing native picker may
restore its original view's focus; delayed Vault replies cannot activate a window
or fill a changed target. Enabled pages discover fields even when Pawl was locked
or unavailable at startup, so refocusing after recovery does not require toggling
the setting. Disabling Pawl removes native field observation.

Password saving uses Chromium's validated submission and keeps its origin and
profile through login redirects. The native save card belongs to the selected
page mounted in the original Bark window. Switching to another profile cancels
its pending offer. Switching back requires a fresh submission. A user-approved
save already dispatched to Pawl may finish there. The app matches each reply
to its original offer before updating the card.

The WebAuthn chooser offers Pawl alongside Chromium's other authenticators.
The Intel browser tests exercise ES256 creation and assertions through
`navigator.credentials` with a synthetic Pawl provider. A modal assertion
accepts a credential allow-list or an empty list. With an empty list, the
provider supplies the selected credential's user handle. Chromium validates
the relying party and origin and produces the client data. Bark checks the
current document, profile, selected page and physical window before delivering
consent or a reply. Switching profiles cancels an outstanding request.

Platform-authenticator availability reflects Pawl readiness for the requesting
frame. Disconnected and guest contexts retain Chromium's ordinary availability
behavior. Conditional account discovery, real Pawl authentication, hardware
security keys and server-side signature verification still need qualification.

Opt-in history text capture uses the current native page's text snapshot and the
existing search index. It coalesces captures and rejects late results after a
document, profile, owner or setting change. Private and Agent pages are excluded;
capture does not instantiate a WebKit page. Ordinary interactive qualification
and the release matrix remain separate from focused native regression tests.

The page-tweak hooks reuse the exact-document resource receiver for fixed
YouTube/Facebook/Reddit configuration independently of blocker enablement. The
saved Boost file is loaded before initial admission; invalid optional snapshots
revoke scripts and leave ordinary browsing available after native acknowledgment.
Opt-in Boost JavaScript runs after load, in order, as awaited async bodies in a
separate isolated world without native bindings or activation. Material effective
changes retire native continuations and invalidate only affected history documents;
unchanged/unrelated settings preserve eligible live restoration. Revocation cannot
undo effects or cancel promises/timers already started by arbitrary user code.
Payload limits are 16 MiB, 200 matching-source records, and 64 KiB per script.
Reddit GET/HEAD main-frame sortless feeds use Chromium's internal redirect, keeping
query/fragment; existing click rewriting handles client routing. SponsorBlock,
trusted social downloads and ClickUp's WebKit invalidation workaround are outside
this slice. Source/syntax checks do not qualify runtime execution.

The tweak continuations extend the same exact-document receiver,
not a generic page/native message channel. SponsorBlock uses fixed HTTPS hash-prefix
lookup/report endpoints with credentials omitted, selected skip/mute categories,
a 15-second/1-MiB response bound, at most 512 hash entries/256 eligible segments,
one last-video cache (one hour), and 256 once-only report keys per document.
Private/inactive documents never report; config/video/document retirement rejects
old replies and removes controller listeners/timers. Existing media controls use
an isolated trusted-click closure and browser-consumed activation; the main-world
React reader supplies untrusted data only, with no native authority.

Social saves use the exact frame/profile/referrer and ordinary Chromium download
manager/observer. Media MIME is image/video, or missing/octet-stream with a known
media extension (including the legacy audiovisual filename case). Misleading
extensions are sanitized before target selection; ordinary security checks stay
on. Credential inclusion requires both the ancestor/descendant host rule and the
same registrable site including private registries. Other HTTPS CDN URLs and
redirects remain credential-omitted; credential-bearing cross-origin redirects
and all HTTPS downgrades are rejected. Custom social saves use a single stream;
parallel range jobs are ineligible because their fresh requests drop the source
and credential restrictions. Persisted source value13 prevents interrupted
resume/restart and both retry entrypoints/UI, while pausing the same already
validated stream remains ordinary download behavior. No temporary-file export,
new profile registry, or additional renderer is used. The seven maintained native
cases still require execution in the matched candidate; syntax is not runtime
qualification. ARM and performance remain unqualified.

Bark's sidebar, address bar and optional page header provide the browser controls. Chromium
continues to own WebContents, browser profiles and page-bound services such as native dialogs.
A separate video Picture-in-Picture overlay can present video controls. The engine currently
declines creation of a document Picture-in-Picture browser window.
