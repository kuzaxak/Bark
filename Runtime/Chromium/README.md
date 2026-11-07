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
From `build/chromium-engine/checkout/src`:

```fish
set barc_repo (realpath ../../../..)
for patch in integration active-client active-client-mac native-window-selection native-owner native-routing native-close native-policy-routing native-factory native-transfer extension-selection native-element-ownership profile-initialization extension-dialog-owner
    git apply --check "$barc_repo/Runtime/Chromium/$patch.patch"; or break
    git apply "$barc_repo/Runtime/Chromium/$patch.patch"; or break
end
```

Stop on any failed check/application; do not skip patches or continue to GN.
After every patch succeeds, copy the current bridge/profile implementations and
all five regression sources into that same checkout. In particular, include
the macOS policy regression supplied with the policy patches:

```fish
cp "$barc_repo/Runtime/Chromium/barc_bridge.h" "$barc_repo/Runtime/Chromium/barc_bridge.mm" chrome/browser/ui/views/frame/
cp "$barc_repo/Runtime/Chromium/barc_profiles.h" "$barc_repo/Runtime/Chromium/barc_profiles.mm" chrome/browser/ui/views/frame/
cp "$barc_repo/Runtime/Chromium/barc_bridge_browsertest.mm" "$barc_repo/Runtime/Chromium/barc_profiles_browsertest.mm" "$barc_repo/Runtime/Chromium/barc_native_policy_browsertest.mm" chrome/browser/ui/views/frame/
cp "$barc_repo/Runtime/Chromium/barc_extension_focus_browsertest.mm" "$barc_repo/Runtime/Chromium/barc_extension_dialog_browsertest.mm" chrome/browser/ui/views/frame/
```

These hooks use Chromium's existing macOS UI target and framework exports; the
C interface is bounded feasibility code, not a stable external C++ embedding
ABI. Choose core-only or the optional SwiftUI overlay below **before** the next
candidate GN generation/build. There is no need for an intermediate core-only
full build. Separate scratch outputs are for small GN-only configuration checks,
not additional complete engines.

`--barc-native-shell` attaches the minimal AppKit sidebar through Views'
`NativeViewHost`. Chromium keeps its Browser, Profile, tab model, extension
services, WebUI and application loop. The bridge reserves native layout space,
validates SessionID/TabHandle ownership, and accepts an `NSHostingView` as a
replacement shell; nullptr explicitly detaches it.

Add `--barc-shared-native-window` to opt into the retained logical-client
composition path. Each logical Browser retains its own Profile and tab model
while sharing one physical Widget. The default remains the stock separate-window
path. Patch application, compilation and source regressions do not qualify
cross-profile selection, focus, policy or teardown in an executing native window.
Inactive-client window geometry/API semantics remain an explicit G1 case.
Same-profile transfer moves the live TabModel; cross-profile transfer is rejected
and requires explicit recreation. Successful close dispatch is not completed
teardown evidence.

### Optional SwiftUI hosting smoke

Apply this overlay **after** copying the current core `.h`/`.mm` files above;
recopying `barc_bridge.mm` afterward would erase the overlay. Check and apply
`swiftui-smoke.patch` first, then `swiftui-smoke-build.patch`, stopping on failure:

```fish
git apply --check "$barc_repo/Runtime/Chromium/swiftui-smoke.patch"; and git apply "$barc_repo/Runtime/Chromium/swiftui-smoke.patch"
```

Only after that succeeds:

```fish
git apply --check "$barc_repo/Runtime/Chromium/swiftui-smoke-build.patch"; and git apply "$barc_repo/Runtime/Chromium/swiftui-smoke-build.patch"
```

Then copy the Swift view and C declaration:

```fish
cp "$barc_repo/Runtime/Chromium/BarcSwiftUISmoke.swift" "$barc_repo/Runtime/Chromium/barc_swiftui_smoke.h" chrome/browser/ui/views/frame/
```

`barc_enable_mac_swift_smoke` defaults to false; the launch switch alone does not
compile Swift support. This is an `NSHostingView` counter/text-field smoke view,
not the Nook SwiftUI application: it adds no `App`/`Scene` entry point or second
application loop. Hosting, interaction and IME still require native execution;
a GN check or compiled object does not prove them.

### One candidate build

For the installed signing proof, also apply the bounded packaging correction:

```fish
git apply --check "$barc_repo/Runtime/Chromium/signing.patch"; and git apply "$barc_repo/Runtime/Chromium/signing.patch"
```

It retains signature verification before submission and performs Gatekeeper
assessment after notarization has completed. The normal DMG packaging path is
used for this proof. Stop if the patch fails to apply.

After the core patches/copies and any selected Swift overlay are complete, set
the candidate arguments in the existing output. Only do this after the baseline
has terminated and its artifact/provenance is captured:

```fish
cp "$barc_repo/Runtime/Chromium/args-x64.gn" out/Barc-x64/args.gn
```

For the optional SwiftUI candidate, enable its flag before GN generation; omit
this line for a core-only candidate:

```fish
printf '\nbarc_enable_mac_swift_smoke = true\n' >> out/Barc-x64/args.gn
```

Generate/build the selected candidate once, reusing the existing engine output:

```fish
gn gen out/Barc-x64 --fail-on-unused-args
autoninja -C out/Barc-x64 -j 8 chrome chrome/installer/mac
```

The second target generates `Chromium Packaging/` from the same pinned source
and build properties. It supplies the upstream signer and per-process
entitlements; it does not sign or notarize the app during compilation.

For local qualification only, launch with a fresh synthetic store. The mock
keychain is limited to that fixture, never a shipping setting. Development CDP,
if needed, uses a loopback-only port (this lane reserves 9228). Keep the sandbox.
The core AppKit shell uses:

```fish
out/Barc-x64/Chromium.app/Contents/MacOS/Chromium --barc-native-shell --barc-shared-native-window --user-data-dir="$PWD/out/Barc-x64/native-synthetic-profile" --use-mock-keychain
```

For a candidate built with the Swift flag, use `--barc-swiftui-smoke` instead of
`--barc-native-shell`; retain `--barc-shared-native-window` when testing composition.
Neither launch command is a qualification result.

### Regression scope and remaining qualification

The maintained `barc_browser_tests` target has **five sources and six classes**:
`BarcBridgeBrowserTest` and `BarcSharedNativeWindowBrowserTest` in
`barc_bridge_browsertest.mm`, `BarcProfilesBrowserTest` in
`barc_profiles_browsertest.mm`, `BarcNativePolicyBrowserTest` in
`barc_native_policy_browsertest.mm`, and `BarcExtensionFocusBrowserTest` in
`barc_extension_focus_browsertest.mm`, plus `BarcExtensionDialogBrowserTest` in
`barc_extension_dialog_browsertest.mm`. It uses Chromium's existing
`browser_tests_runner`, `test_support` and `test_support_ui`, with no custom
runner or registration in monolithic `browser_tests`. Inspect the generated
graph/incremental estimate and compile added objects before committing to its
separate build. Its ordinary launcher filter is:

```fish
out/Barc-x64/barc_browser_tests --test-launcher-jobs=1 --gtest_filter='BarcBridgeBrowserTest.*:BarcProfilesBrowserTest.*:BarcSharedNativeWindowBrowserTest.*:BarcNativePolicyBrowserTest.*:BarcExtensionFocusBrowserTest.*:BarcExtensionDialogBrowserTest.*'
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

After the candidate build succeeds, use its generated `Chromium Packaging`
tools with Python 3.11 or newer. Set `signing_identity` to the existing Developer
ID Application identity and `notary_profile` to the existing notarytool Keychain
profile. Keep credentials out of arguments and logs; the profile name is enough.
From the engine source root:

```fish
set engine_out "$PWD/out/Barc-x64"
set signed_out "$PWD/out/Barc-x64-signed"
python3 "$engine_out/Chromium Packaging/sign_chrome.py" \
    --identity "$signing_identity" --input "$engine_out" --output "$signed_out" \
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
