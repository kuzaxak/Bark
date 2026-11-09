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
Xcode 26.3 (17C529), SDK 26.2. This is a developer build: pinned official
builds require SDK 26.5. ARM execution and installed signing remain separate gates.

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
Apply candidate options to an actual output only after its current baseline
build terminates; never regenerate an output with an active compile. `args-arm64.gn`
keeps the same candidate settings with only `target_cpu` changed to `arm64`.
GN-only checks use separate `out/Barc-media-args-check` and
`out/Barc-arm64-args-check` directories; configuration generation does not
establish an ARM build or native execution.

## Checkout and build

Run these fish commands from the Barc repository root. Engine sources, profiles,
logs and outputs belong under ignored `build/chromium-engine/`; do not copy them
into the app repository. Allow 100–250 GB and several hours. Check free space
before every stage and during long builds; stop if available space drops below
150 GB. Build locally with at most eight jobs. Do not disable the sandbox.

```fish
set engine "$PWD/build/chromium-engine"
mkdir -p "$engine/checkout/src"
git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$engine/depot_tools"
git -C "$engine/depot_tools" fetch --depth=1 origin 500126d6e351e4f0834b70f71b454ce5c3733c54
git -C "$engine/depot_tools" checkout --detach 500126d6e351e4f0834b70f71b454ce5c3733c54
git -C "$engine/checkout/src" init
git -C "$engine/checkout/src" remote add origin https://chromium.googlesource.com/chromium/src.git
git -C "$engine/checkout/src" -c protocol.version=2 fetch --depth=1 --no-tags origin fb096c0011f9d50f0a264a9376420cdea9c421e3
git -C "$engine/checkout/src" checkout --detach fb096c0011f9d50f0a264a9376420cdea9c421e3
cp Runtime/Chromium/checkout.gclient "$engine/checkout/.gclient"
set -gx DEPOT_TOOLS_UPDATE 0
set -gx PATH "$engine/depot_tools" $PATH
# Use the system CA bundle if the host Python has no configured trust store.
set -gx SSL_CERT_FILE /etc/ssl/cert.pem
"$engine/depot_tools/ensure_bootstrap"
cd "$engine/checkout"
gclient sync --no-history --nohooks --revision src@fb096c0011f9d50f0a264a9376420cdea9c421e3 --jobs 8
gclient runhooks
cd src
mkdir -p out/Barc-x64
# Establish the initial baseline with upstream codec/branding defaults.
sed -E '/^(is_chrome_branded|proprietary_codecs|ffmpeg_branding) =/d; /^# Candidate /d' ../../../../Runtime/Chromium/args-x64.gn > out/Barc-x64/args.gn
gn gen out/Barc-x64 --fail-on-unused-args
autoninja -C out/Barc-x64 -j 8 chrome
```

Resume an interrupted dependency sync or build with the same final commands;
retain the checkout, output directory and running process rather than starting
a second build. A tool observation timeout does not mean its process exited.
Verify the source/depot_tools `git rev-parse HEAD`, `chrome/VERSION`, downloaded
Clang version, SDK selected by GN and `args.gn` before attributing build results.

The initial `chrome` target establishes the unmodified browser-layer baseline.
It omits the candidate's three explicit codec/branding arguments above; the
candidate build below restores the complete checked-in arguments.
It does not establish a native SwiftUI bridge, profile isolation, extension
compatibility, signed distribution or either architecture's release qualification.

Upstream instructions: [Chromium macOS build](https://chromium.googlesource.com/chromium/src/+/fb096c0011f9d50f0a264a9376420cdea9c421e3/docs/mac_build_instructions.md).

## Native bridge slice

Keep the unmodified browser-layer baseline distinct from this patched candidate.
First wait for the baseline build to terminate and capture its artifact, source/
toolchain/argument provenance and result. Then reuse `out/Barc-x64` for the next
candidate; do not modify sources or arguments under a running build. Use the complete reviewed `Runtime/Chromium` patch/source set
from one revision; apply it once to the pinned source, in the following order.
From `build/chromium-engine/checkout/src`, use this single stop-on-error
procedure. The complete reviewed candidate has 56 ordered patches and 30 copied
sources (the BRANDING file, 16 bridge sources, the existing translation script, two cosmetic resources
the Boost picker resource, the native matcher header, the fixed-tweaks header, three tweak resources
and the header digest script). Copies precede `lifecycle-close.patch`; the Swift overlay follows those
copies. Do not recopy sources or reapply an overlay afterward. Start from the
pinned unmodified source, not a partially patched checkout.

```fish
set barc_repo (realpath ../../../..)
function prepare_native_candidate
    set -l runtime "$argv[1]/Runtime/Chromium"
    cp "$runtime/BRANDING" chrome/app/theme/chromium/BRANDING; or return 1
    for patch in integration active-client active-client-mac native-window-selection native-owner native-routing native-close native-policy-routing native-factory native-transfer extension-selection native-element-ownership profile-initialization extension-dialog-owner private-sessions lifecycle-close owner-ended native-attach-lifetime swiftui-smoke swiftui-smoke-build signing runtime-startup native-keychain native-shutdown native-shell-signing native-discovery private-entrypoints native-permission-owner native-incoming-routing native-split native-profile-deletion native-profile-reassignment native-transfer-admission native-external-routing native-cross-profile-presentation native-boost-css native-page-translation native-resource-protection native-peek native-script-execution native-content-blocking native-blocked-navigation native-cosmetics native-profile-search native-boost-picker native-websocket-blocking native-page-tweaks native-pawl-passkeys native-devtools-panels native-tweaks-continuations native-hide-stock-chrome native-sdk-entry native-product-strings native-app-controlled-splits native-header-hash native-app-lifetime
        if test "$patch" = lifecycle-close
            for source in barc_bridge_api.h barc_bridge.h barc_bridge.mm barc_bridge_browsertest.mm barc_profiles.h barc_profiles.mm barc_profiles_browsertest.mm barc_native_policy_browsertest.mm barc_extension_focus_browsertest.mm barc_extension_dialog_browsertest.mm barc_extension_storage_browsertest.mm barc_swiftui_smoke.h BarcSwiftUISmoke.swift barc_runtime_startup_api.h barc_runtime_startup.h barc_runtime_startup.cc
                cp "$runtime/$source" chrome/browser/ui/views/frame/; or return 1
            end
        end
        if test "$patch" = native-page-translation
            cp "$argv[1]/Packages/NookWeb/Sources/NookWeb/Resources/page-translate.js" chrome/renderer/resources/; or return 1
        end
        if test "$patch" = native-cosmetics
            mkdir -p chrome/common/resources/nook_cosmetics; or return 1
            cp "$runtime/native_cosmetic_observer.js" chrome/common/resources/nook_cosmetics/observer.js; or return 1
            cp "$argv[1]/Packages/NookBlocker/Sources/NookBlocker/Resources/scriptlets.json" chrome/common/resources/nook_cosmetics/scriptlets.json; or return 1
            cp "$argv[1]/Nook/ThirdParty/AdblockRustFFI/include/nook_adblock.h" chrome/browser/content_blocking/nook_adblock/nook_adblock.h; or return 1
        end
        if test "$patch" = native-boost-picker
            cp "$runtime/native_boost_picker.js" chrome/common/resources/nook_boost_picker.js; or return 1
        end
        if test "$patch" = native-page-tweaks
            mkdir -p chrome/common/resources/nook_tweaks; or return 1
            cp "$runtime/barc_page_tweaks.h" chrome/browser/content_blocking/; or return 1
            cp "$argv[1]/Packages/NookTweaks/Sources/NookTweaks/Resources/youtube-tweaks.js" chrome/common/resources/nook_tweaks/; or return 1
            cp "$argv[1]/Packages/NookTweaks/Sources/NookTweaks/Resources/reddit-tweaks.js" chrome/common/resources/nook_tweaks/; or return 1
            cp "$argv[1]/Packages/NookBlocker/Sources/NookBlocker/Resources/facebook-feed-prune.js" chrome/common/resources/nook_tweaks/; or return 1
        end
        if test "$patch" = native-header-hash
            cp "$runtime/barc_public_headers_sha256.py" chrome/browser/ui/views/frame/; or return 1
        end
        if test "$patch" = native-tweaks-continuations
            cp "$argv[1]/Packages/NookTweaks/Sources/NookTweaks/Resources/youtube-sponsorblock.js" chrome/common/resources/nook_tweaks/; or return 1
            cp "$argv[1]/Packages/NookTweaks/Sources/NookTweaks/Resources/social-image-download.js" chrome/common/resources/nook_tweaks/; or return 1
            cp "$argv[1]/Packages/NookTweaks/Sources/NookTweaks/Resources/social-video-source.js" chrome/common/resources/nook_tweaks/; or return 1
        end
        git apply --check "$runtime/$patch.patch"; or return 1
        git apply "$runtime/$patch.patch"; or return 1
    end
    # Isolate the pinned Rust runtime behind its fixed C ABI. Existing
    # universal/iOS static archives remain unchanged.
    set -l blocker_target "$argv[1]/build/native-adblock-x64"
    env MACOSX_DEPLOYMENT_TARGET=13.0 cargo rustc --locked --release \
        --target x86_64-apple-darwin --target-dir "$blocker_target" \
        --manifest-path "$argv[1]/Nook/ThirdParty/AdblockRustFFI/Cargo.toml" \
        --lib --crate-type cdylib -- \
        -C 'link-arg=-Wl,-install_name,@loader_path/Libraries/libnook_adblock.dylib' \
        -C "link-arg=-Wl,-exported_symbols_list,$argv[1]/Nook/ThirdParty/AdblockRustFFI/nook_adblock.exports"; or return 1
    cp "$blocker_target/x86_64-apple-darwin/release/libnook_adblock.dylib" \
        chrome/browser/content_blocking/nook_adblock/libnook_adblock.dylib; or return 1
end
if prepare_native_candidate "$barc_repo"
    cp "$barc_repo/Runtime/Chromium/args-x64.gn" out/Barc-x64/args.gn; and \
        gn gen out/Barc-x64 --fail-on-unused-args; and \
        autoninja -C out/Barc-x64 -j 8 chrome chrome/installer/mac
end
functions -e prepare_native_candidate
```

On failure, stop and inspect the checkout; this is not an idempotent resume
command. No intermediate core-only full build is needed. Keep separate scratch
outputs for GN-only configuration checks, not duplicate complete engines.
The installer target generates `Bark Packaging/` from the same source and
build properties, including the pinned signer and per-process entitlements.
Compilation does not sign or notarize the app.

### Native application and experimental smoke

`Bark.app` is the outer bundle: the `NookChromiumApp` target owns its executable
and `Info.plist`, and `Bark Framework.framework` is nested inside it. `BRANDING`
sets the product name and the `ee.qdo.bark` bundle identifier in the engine's bundle,
framework and helper names. It does not reach `chromium_strings.grd`, so
`native-product-strings.patch` sets the product name, helper name, window title
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
`barc_engine_main_v<N>`, whose name carries the bridge version, so an app and framework
built for different versions fail at `dlsym`. `ChromeMain` stays exported for the helpers.

### Publishing the engine

The app builds without this checkout. It compiles against the `Packages/BarkEngine`
binary target and never links the engine: `main` opens the framework after registering
the malloc zone, and the shell resolves the bridge with `dlsym`. So the
`BarkEngine.xcframework` slice is a library slice whose static library defines no symbols.
Its public C headers (`barc_bridge_api.h`, `barc_runtime_startup_api.h`,
`barc_page_tweaks.h`) and `engine-artifact.sha256` are committed. The engine itself sits in
the same slice under the ignored `Engine/` directory: the framework, `Bark Packaging`, the
engine's `Info.plist`, copies of those headers and `SHA256SUMS`. The private C++ stays in
`barc_bridge.h` and `barc_runtime_startup.h`, which the engine alone includes. x86_64 only
for now.

The bridge's structs cross without a size argument, so a layout change with no version bump
would otherwise start fine and read the wrong layout. Publishing therefore refuses an engine
unless siso's record of the last build (`siso fs export`) shows it compiled the same three
headers as `Runtime/Chromium`, and no later change to them. It reads that record, not the
source tree, because the tree may have moved on since the build. Staging refuses an app
compiled against headers other than the ones in `Engine/`. The engine also exports
`barc_public_headers_sha256`, a digest of the three headers it compiled that a GN action computes
with `barc_public_headers_sha256.py`. Publishing writes the same digest from `Runtime/Chromium` as
`barc_public_headers_sha256.h` beside the published headers, and `main.cc` aborts before the shell
loads when the engine's digest differs from the one it was compiled with.

The outer app's own resources (`app.icns`, `Assets.car`, `scripting.sdef`, the policy
manifest and the `.lproj` strings) are committed in `ChromiumApp/Resources` and copied by
the app target. They are generated by the engine's build, so publishing refuses an engine
whose resources differ. If the difference is intended, update `ChromiumApp/Resources` from
the engine, then publish again.

`Engine/` is read-only, because Python writes bytecode beside the signing tools and any new
file fails its checksums at the next staging. From the engine source root, with depot_tools
on `PATH`, after a successful build. If there is an earlier `Engine/`, run `chmod -R u+w` on it
and remove it, then commit the changed headers and SHA:

```fish
bash "$barc_repo/scripts/publish-chromium-engine.sh" "$PWD/out/Barc-x64" "$barc_repo/Packages/BarkEngine"
```

### Building the app

Build the Intel app target and native framework from the same reviewed app revision,
using their existing source/package/resource references. The scheme builds both:

```fish
set native_derived "$barc_repo/build/native-derived"
xcodebuild -project "$barc_repo/Nook.xcodeproj" -scheme NookNativeShell \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$native_derived" ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO -jobs 4 build
```

Stage only after both builds succeed, preserving engine inputs and using a new
output directory. The staging script starts from the app target's `Bark.app` and
adds the complete versioned engine framework from the published artifact, Sparkle
and SPM resource bundles. It refuses an artifact that fails its checksums or isn't the
one the app was built against, and any mismatch between the app and engine it can see.
Do not copy a loose native dylib, Assets.car or metallib into Chromium resources.

```fish
set engine_artifact "$barc_repo/Packages/BarkEngine/BarkEngine.xcframework/macos-x86_64/Engine"
set staging_input "$barc_repo/build/native-signing-input"
mkdir "$staging_input"; and \
    bash "$barc_repo/scripts/stage-chromium-app.sh" \
        "$native_derived/Build/Products/Release/Bark.app" "$engine_artifact" \
        "$native_derived/Build/Products/Release" "$staging_input/Bark.app"; and \
    ditto "$engine_artifact/Bark Packaging" "$staging_input/Bark Packaging"; and \
    chmod -R u+w "$staging_input/Bark Packaging"
```

Do not sign or launch a partially staged bundle. The framework requires its
standard FMWK Info.plist, `ee.qdo.nook.NativeShell` identity, version-A executable,
Assets.car, default.metallib and exported `barc_native_main`. Preserve sandbox,
hardened-runtime, helper entitlements and library validation throughout staging
and signing. The signing patch retains pre-submission signature verification and
moves Gatekeeper assessment after awaited notarization; it does not confer
notarization or release acceptance.

The retained `--barc-swiftui-smoke` counter/text-field view is experimental engine
hosting material, not the native application. Its two patches are already in the
ordered procedure above; do not apply them a second time. To compile that smoke,
add `barc_enable_mac_swift_smoke = true` to candidate args before the single GN
step, not after compilation. Leave it disabled for normal application builds.
The native application supplies `--barc-native-shell` and
`--barc-shared-native-window` through its validated startup configuration. Verify
only with a fresh `/private/tmp` synthetic app root and explicit profile UUID;
never use a real profile. Patch application, compilation and mechanical tests do
not establish native interaction, media, profile isolation or release readiness.

### Regression scope and remaining qualification

The maintained `barc_browser_tests` target has six sources, including
`BarcBridgeBrowserTest`, `BarcSharedNativeWindowBrowserTest` and
`BarcFourPaneBrowserTest` in
`barc_bridge_browsertest.mm`, `BarcProfilesBrowserTest` in
`barc_profiles_browsertest.mm`, `BarcNativePolicyBrowserTest` in
`barc_native_policy_browsertest.mm`, and `BarcExtensionFocusBrowserTest` in
`barc_extension_focus_browsertest.mm`, plus `BarcExtensionDialogBrowserTest` in
`barc_extension_dialog_browsertest.mm`, and `BarcExtensionStorageBrowserTest` in
`barc_extension_storage_browsertest.mm`. Derived fixtures also cover startup,
discovery, private commands and site data. It uses Chromium's existing
`browser_tests_runner`, `test_support` and `test_support_ui`, with no custom
runner or registration in monolithic `browser_tests`. Inspect the generated
graph/incremental estimate and compile added objects before committing to its
separate build. Its ordinary launcher filter is:

```fish
out/Barc-x64/barc_browser_tests --gtest_filter='Barc*' --gtest_list_tests
out/Barc-x64/barc_browser_tests --test-launcher-jobs=1 --test-launcher-retry-limit=0 --gtest_filter='Barc*'
```

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

Normal startup requires bridge version 8 before ChromeMain. Native registration
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
`BARC_DISCOVERY_EMPTY_STRIP` and takes new tabs: `native-app-lifetime.patch` keeps its
`UnloadController` idle and returns from `Browser::TabStripEmpty` before the close. The window
still closes through `barc_window_close` of its last client, its close button or quit, with
their prompts. `barc_tab_select` refuses bridge callbacks, because `TabStripModel::ActivateTab`
CHECKs reentrancy in every build type and those callbacks can run inside a strip change.

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
complete versioned framework layout. Production provisioning for `ee.qdo.bark` and
CloudKit are separate work.

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

`native-split.patch` extends the existing same-profile tab collection and Views
content containers to two through four ordered live panes. The split C boundary
validates exact logical owners, ordered handles, orientation, normalized dividers
and active pane; Chrome pin/group rules follow the first pane. Native resize
completion persists all divider positions. Member lookup reads retained split
collections without selection; cleanup requires the exact opaque collection
identity, member order and geometry, so a recreated group wins over stale cleanup. All four container views are constructed
before feature-controller enrollment; unused panes stay hidden and unbound. This
adds two empty view trees, not extra pages; its allocation cost is unmeasured.
`native-app-controlled-splits.patch`
then replaces that collection in native windows: every split, same-profile, cross-profile or
private, is the app-positioned presentation of independent tabs, which `BarcSplitLayout`
reports as kind 1 with a generation and no collection. Its public-header hunks live in
`barc_bridge_api.h`. Peek covers the whole split and dims its panes with a compositor layer;
an inactive pane's link selects that pane first. `barc_tab_enable_peek` takes a mask, so
Option-click, and Shift-click when the app setting allows it, request Peek instead of a
download or a window. Chromium's own split commands and menu items are gone from native windows.

`native-profile-reassignment.patch` extends the existing profile deletion helper
with a close-admitted pause before data cleanup. The application commits the
space assignment and source record before allowing cleanup to continue. Unmarked
orphaned source bytes remain pending; missing metadata is not permission to wipe
them. Its browser tests and the integrated startup recovery path still require
runtime qualification.

`native-content-blocking.patch` adds native website network matching to the
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
with an additive method-aware C entry point. `native-websocket-blocking.patch`
handles WebSocket admission; `native-cosmetics.patch` delivers document-bound
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

Password saving consumes Chromium's validated password-manager submission,
retaining its origin and profile through login redirects. A connected Pawl
consumer uses the existing native save card; disabled, disconnected or refused
consumers leave Chromium's save UI available. A newer submission retires the old
offer even when it falls back to Chromium. Owner retirement cancels offers and
unsent saves. A user-approved save already dispatched to Pawl may finish there;
its late reply cannot dismiss a newer offer. Ordinary card interaction and Pawl
authentication still require product qualification.

`native-pawl-passkeys.patch` adds an explicit Pawl choice beside Chromium's stock
authenticators. The initial provider supports ES256 creation and assertions with
a nonempty credential allow-list; Chromium retains RP, origin, script-policy and
response validation. The current document/profile/owner owns consent and reply.
Retirement cancels queued vault requests before socket dispatch; authentication
already sent may finish but cannot complete a retired Chromium request.
Conditional account discovery, empty allow-lists and Pawl-aware platform-availability
queries remain incomplete. Synthetic response tests do not qualify real Pawl
authentication, hardware keys or server-side signature verification.

Opt-in history text capture uses the current native page's text snapshot and the
existing search index. It coalesces captures and rejects late results after a
document, profile, owner or setting change. Private and Agent pages are excluded;
capture does not instantiate a WebKit page. Ordinary interactive qualification
and the release matrix remain separate from focused native regression tests.

`native-page-tweaks.patch` reuses the exact-document resource receiver for fixed
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

`native-tweaks-continuations.patch` extends the same exact-document receiver,
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

`native-hide-stock-chrome.patch` removes Chromium's tab strip, toolbar and
bookmarks bar from every window that has a native shell: regular and private
pages, splits, Peek, utility pages and compact minis. Nook's sidebar and optional
header are the only browser chrome, so the page starts directly under the header,
or at the window top without one. Those views still exist unlaid and hidden, so
upstream commands, tab models and bubble anchors keep working. Hidden Views leave
the accessibility tree by themselves; the toolbar is also pruned because a WebUI
toolbar page keeps its own tree while hidden. Real popups, DevTools and extension
windows keep stock chrome. Native application windows do not use immersive
fullscreen: its overlay widgets have no content here, and an empty Mac overlay
widget fails a size check on entry.
