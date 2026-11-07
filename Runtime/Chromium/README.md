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
procedure. The complete reviewed candidate has 25 ordered patches and 14 copied
sources. Copies precede `lifecycle-close.patch`; the Swift overlay follows those
copies. Do not recopy sources or reapply an overlay afterward. Start from the
pinned unmodified source, not a partially patched checkout.

```fish
set barc_repo (realpath ../../../..)
function prepare_native_candidate
    set -l runtime "$argv[1]/Runtime/Chromium"
    for patch in integration active-client active-client-mac native-window-selection native-owner native-routing native-close native-policy-routing native-factory native-transfer extension-selection native-element-ownership profile-initialization extension-dialog-owner private-sessions lifecycle-close owner-ended native-attach-lifetime swiftui-smoke swiftui-smoke-build signing runtime-startup runtime-native-bootstrap native-shell-signing native-discovery
        if test "$patch" = lifecycle-close
            for source in barc_bridge.h barc_bridge.mm barc_bridge_browsertest.mm barc_profiles.h barc_profiles.mm barc_profiles_browsertest.mm barc_native_policy_browsertest.mm barc_extension_focus_browsertest.mm barc_extension_dialog_browsertest.mm barc_extension_storage_browsertest.mm barc_swiftui_smoke.h BarcSwiftUISmoke.swift barc_runtime_startup.h barc_runtime_startup.cc
                cp "$runtime/$source" chrome/browser/ui/views/frame/; or return 1
            end
        end
        git apply --check "$runtime/$patch.patch"; or return 1
        git apply "$runtime/$patch.patch"; or return 1
    end
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
The installer target generates `Chromium Packaging/` from the same source and
build properties, including the pinned signer and per-process entitlements.
Compilation does not sign or notarize the app.

### Native application and experimental smoke

Application launch requires the native bootstrap, runtime-ready/lifecycle hooks
and `NookNativeShell.framework`. The stock executable initializes Chromium's
allocator and loads the fixed bundle-local framework entry; `ChromeMain` owns
the sole application loop. There is no core-only application launch path or
WebKit fallback. Build the Intel native framework from the same reviewed app
revision, using its existing source/package/resource references:

```fish
set native_derived "$barc_repo/build/native-derived"
xcodebuild -project "$barc_repo/Nook.xcodeproj" -scheme NookNativeShell \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$native_derived" ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO -jobs 4 build
```

Stage only after both builds succeed, preserving engine inputs and using a new
output directory. The staging script copies the complete versioned framework,
Sparkle and SPM resource bundles, and preserves Chromium's Assets.car. Do not
copy a loose native dylib, Assets.car or metallib into Chromium resources.

```fish
set engine_out "$PWD/out/Barc-x64"
set staging_input "$barc_repo/build/native-signing-input"
mkdir "$staging_input"; and \
    bash "$barc_repo/scripts/stage-chromium-app.sh" "$engine_out/Chromium.app" \
        "$native_derived/Build/Products/Release" "$staging_input/Chromium.app"; and \
    ditto "$engine_out/Chromium Packaging" "$staging_input/Chromium Packaging"
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

The maintained `barc_browser_tests` target has **six sources and seven classes**:
`BarcBridgeBrowserTest` and `BarcSharedNativeWindowBrowserTest` in
`barc_bridge_browsertest.mm`, `BarcProfilesBrowserTest` in
`barc_profiles_browsertest.mm`, `BarcNativePolicyBrowserTest` in
`barc_native_policy_browsertest.mm`, and `BarcExtensionFocusBrowserTest` in
`barc_extension_focus_browsertest.mm`, plus `BarcExtensionDialogBrowserTest` in
`barc_extension_dialog_browsertest.mm`, and `BarcExtensionStorageBrowserTest` in
`barc_extension_storage_browsertest.mm`. It uses Chromium's existing
`browser_tests_runner`, `test_support` and `test_support_ui`, with no custom
runner or registration in monolithic `browser_tests`. Inspect the generated
graph/incremental estimate and compile added objects before committing to its
separate build. Its ordinary launcher filter is:

```fish
out/Barc-x64/barc_browser_tests --test-launcher-jobs=1 --test-launcher-retry-limit=0 --gtest_filter='BarcBridgeBrowserTest.*:BarcProfilesBrowserTest.*:BarcSharedNativeWindowBrowserTest.*:BarcNativePolicyBrowserTest.*:BarcExtensionFocusBrowserTest.*:BarcExtensionDialogBrowserTest.*:BarcExtensionStorageBrowserTest.*'
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

### Installed signing proof

The native product is a standard versioned
`Contents/Frameworks/NookNativeShell.framework` bundle. The stock loader opens
`Versions/A/NookNativeShell` after Chromium's allocator initialization. Keep its
Info.plist and native resources (including Assets.car) inside that framework's
Resources, separate from Chromium's resources. The explicit native signing part
signs the framework container and infers `ee.qdo.nook.NativeShell` from its
Info.plist; it supplies no bare-library identifier override.

After the candidate build succeeds, use its generated `Chromium Packaging`
tools with Python 3.11 or newer. Set `signing_identity` to the existing Developer
ID Application identity and `notary_profile` to the existing notarytool Keychain
profile. Keep credentials out of arguments and logs; the profile name is enough.
From the engine source root, after successful complete staging above:

```fish
set signed_out "$PWD/out/Barc-x64-signed"
python3 "$engine_out/Chromium Packaging/sign_chrome.py" \
    --identity "$signing_identity" --input "$staging_input" --output "$signed_out" \
    --notarize staple --notary-arg=--keychain-profile --notary-arg="$notary_profile"
```

Use normal Developer ID signing for this gate. The upstream `--development`
option injects `get-task-allow` and skips Gatekeeper assessment, so it cannot
qualify the installed proof. Preserve the generated helper entitlements and
complete versioned framework layout. The prototype still has Chromium's
identity; production Barc provisioning and CloudKit are separate work.

Verify the produced DMG, install its complete app in an isolated location
outside the build tree, and require strict signature checks, stapler validation
and Gatekeeper acceptance there. Launch that exact executable with a fresh
synthetic user-data directory and keep the Chromium sandbox enabled. Inspect
helper ownership, resources, profile/extension behavior and clean shutdown.
Repeat with native ARM artifacts on Apple Silicon. These commands are prepared
inputs; no installed or notarized result is claimed by this document.

The private-session bridge creates a separate Guest parent and primary OTR for
each independent session. Its tests cover session cookies/site grants, popup
inheritance, final object/metadata disposal, rejected installed extensions even
with regular-profile incognito permission, and unused/failed creation cleanup.
Disk/crash cleanup, PDF rendering, detached private surfaces and native
Guest/Incognito menu routing remain unqualified; PDF registration alone is not
rendering evidence. The popup regression separately checks JavaScript opener
messaging and live state through same-profile transfer, plus `noopener`; its
separate native popup window does not qualify Peek integration.
