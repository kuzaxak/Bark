# Independent Chromium browser design

## Context

See [proposal.md](proposal.md) for scope and the five capability specs for observable requirements. The user also authorized a limited local integration/performance spike, recorded below. Production implementation, repository detachment and release remain future work.

### Confirmed direction

- Become independent of the original Nook fork and use Chromium for compatibility and performance.
- Broad Chrome extension support is required in the first stable Chromium release.
- Extensions belong to profiles. The profile settings page provides quick links to that profile's Chromium settings.
- Intel (x86_64) and Apple Silicon (arm64) are both mandatory macOS baselines. The README will be rewritten and does not override this requirement.
- Barc name and logo are covered by the companion change.
- Performance, smart tab management, and broad media capabilities are product priorities. Chromium adoption alone is not evidence of lower memory, CPU or energy use.

### Relevant code and operational facts

| Area | Current implementation | Consequence |
| --- | --- | --- |
| Page orchestration | `Packages/NookWeb/Sources/NookWeb/PageSession.swift` and its extensions directly use WebKit delegates, scripts, frames, PDF, media, and view state | Split runtime mechanics from application state; replacing one view is insufficient |
| Existing seams | `WebViewProvider.swift`, `PageSessionDelegate.swift`, `BrowserConfig.swift` expose `WKWebView`, `WKDownload`, and configurations | These interfaces are starting points, not engine-neutral boundaries |
| Profiles | `TabsController.profile(forSpace:)` and `TabsController+Intents.swift` resolve stored profile identities; multiple spaces can share a profile | Key Chromium contexts by existing profile ID, never by space ID or display name |
| Profile UI | `Packages/NookUI/Sources/NookUI/Settings/Profiles.swift` has `ProfileDetailForm` | Add profile-bound actions here; do not create a competing profile manager |
| Extensions | `Nook/Managers/ExtensionManager/ExtensionManager.swift` has one singleton controller, global install state and storage | Per-profile extension state is an intentional behavioral change |
| Window ownership | `WebViewCoordinator.swift` moves one live page view between windows; some protocol comments still describe clones | Preserve the actual single-owner behavior, including opener and page state |
| Blocker/tweaks | `BlockablePage.swift`, rule compilation, scriptlets, `NookTweaks` depend on WebKit | Preserve rule/filter policy but replace execution and request integration |
| Other consumers | Downloads, `DevMCPServer`, `BrowserToolExecutor`, vault/passkeys, cookie tools and native media helpers reach WebKit | Include them in parity testing and the adapter migration |
| Distribution | Sparkle feed already points to `kuzaxak/Nook`; README links mostly point upstream | Product/release independence is partly present, documentation independence is not |
| Repository | GitHub reports public fork of `nook-browser/Nook`, no child forks, default branch `pawl-dev`; local working branch differs | Choose the implementation base deliberately; local remote changes do not detach GitHub's fork network |
| Platforms | README says Apple Silicon/macOS 15.5+; release and CI scripts request `arm64 x86_64`; iOS target and shared packages exist | User confirms Intel and Apple Silicon; correct README and verify both runtime/dependency slices |

## Goals / Non-Goals

**Goals:** a narrow boundary between native product logic and Chromium; one stable identity per profile; a maintainable engine update process; repeatable measurement and recoverable cutover.

**Non-goals:** rewriting the UI in Electron, a new cross-platform UI, a Windows/Linux release, replacing CloudKit with Chrome Sync, recreating every Chrome service, or keeping a permanent user-facing dual-engine mode. iOS keeps WebKit behind the same product-facing seams where practical. A CEF binary or Chromium source dependency is not a replacement for independent ownership of Barc itself.

## Decisions

### 1. Use the Chromium browser layer as the baseline

Plan capacity for a maintained Chromium `chrome/` browser integration with a thin Objective-C++/C boundary consumed by Swift. Retain native SwiftUI/AppKit controls, with Chromium owning browser contexts, extension services, internal WebUI pages, and child processes. This has the strongest alignment with the confirmed extension and profile-settings requirements, but is a substantial engine integration and ongoing maintenance commitment.

Run a bounded CEF Chrome-runtime prototype before committing to the larger integration. CEF is accepted only if the exact pinned revision passes the same extension, internal-settings, profile, view-hosting, and signed-distribution gates. The baseline remains full Chromium if it fails. This is a technical gate with both paths budgeted, not permission to weaken extension scope.

| Option | Native shell fit | Extension and Chromium-settings fit | Decision |
| --- | --- | --- | --- |
| Chromium browser layer with thin embedding boundary | Requires custom macOS integration and run-loop ownership | Most direct reuse of browser profile/extension/WebUI services | Baseline |
| CEF Chrome runtime with Chrome-style browser surfaces | Must prove actual Cocoa/SwiftUI hosting, focus, reparenting and popup behavior | Promising but exposed management/UI APIs must be verified | Lower-maintenance option only after G1 passes |
| Basic CEF Alloy-style view or `content/` embed alone | Easier isolated view | Does not establish required browser UI and extension semantics | Insufficient baseline |
| Electron rewrite | Replaces much of the current shell | Requires separate extension validation and large product rewrite | Outside this plan |

CEF's [architecture documentation](https://raw.githubusercontent.com/chromiumembedded/cef/master/docs/architecture.md) distinguishes Chrome and Alloy styles. Its [programmatic extension-management issue](https://github.com/chromiumembedded/cef/issues/3450) remains open, and the [Alloy-style extension discussion](https://github.com/chromiumembedded/cef/issues/3859) identifies UI limitations. These are reasons to test the selected revision, not proof that any particular release can or cannot meet the full plan.

**G1 must prove on Intel and Apple Silicon:** browser startup/quit without run-loop deadlock; an embedded live tab moved between windows without reload; profile-bound `chrome://settings` and `chrome://extensions`; representative MV3 extensions with real popups and native messaging; separate profile stores; sandboxed helpers; and a signed/notarized prototype launched outside the build tree. Never substitute an external installed Chrome window for an integrated settings page.

For full Chromium, build the integration within its supported build system and export a versioned bridge artifact to Xcode. Do not treat `WebContents` as a stable public embedding ABI or assume Chromium's default Cocoa window can simply be dropped into SwiftUI. Prototype native surface ownership, accessibility, event routing, command dispatch, and process startup first. A CEF success changes the bridge internals, not the contracts or launch requirements.

### 2. Separate application state from engine state

Proposed module names below are architectural roles; use the Barc naming map during implementation to avoid renaming them twice.

```text
Native shell: windows, sidebar, spaces, split views, profile settings
                             |
Application core: tab tree, history, settings, synchronization, actions
                             |
Browser engine contracts: profile, page, surface, events, capabilities
                  /                          \
      Chromium adapter (macOS)       WebKit adapter (iOS/transitional)
                  |
        Objective-C++/C bridge
                  |
Chromium browser contexts / extension services / WebUI / child processes
```

- Extract engine-neutral contracts for `BrowserEngine`, `BrowserProfile`, `BrowserPage`, `BrowserSurface`, navigation events, downloads, permissions, scripting, and snapshots. Keep platform view hosting in platform modules.
- Keep stable profile/tab/window IDs in app models. Use opaque engine handles with explicit lifetime and ownership; do not leak `WK*`, CEF classes, or Chromium pointers into shared UI and tab models.
- Route engine callbacks onto the correct thread and deliver observable state on the main actor. Define cancellation and shutdown ordering; a callback must not revive a closed page or deleted profile.
- Keep one runtime instance per process and one live page per tab. A visible surface is attached to one owning window at a time. Bind popups, Peek, split panes, and devtools to their initiating profile/page.
- Use asynchronous, origin-checked script/message interfaces with explicit frame/world identity for tweaks, translation, vault, and automation. Never expose privileged native methods to arbitrary web content or use unauthenticated remote debugging as the product API.
- Build a WebKit adapter first and run existing behavior through it. This gives a bisectable seam extraction before changing the engine. Remove the macOS WebKit runtime only after Chromium parity; retain the iOS adapter.

### 3. A profile owns the browser context and extensions

Resolve `Space -> existing profile UUID -> Chromium profile/context`. Two spaces sharing the same UUID deliberately share logins, extensions, grants, and Chromium settings. Distinct UUIDs never share these stores. Renaming a profile changes its label, not its directory or extension namespace.

Persistent layout is proposed as `<existing application support root>/Chromium/Profiles/<profile UUID>/`, with an engine-version/migration manifest outside engine-owned databases. Use an appropriate shared user-data root plus separate native Chromium profiles where required by the selected backend. A directory alone is not proof of isolation: independently test prefs, extension services, workers, network contexts, and events. Private contexts are ephemeral and extensions remain disabled initially, matching current private behavior.

Replace the global extension singleton with a profile registry and a thin UI coordinator. Installation, enablement, optional permissions, updates, extension storage, action anchors, options windows, workers, native ports and tab/window event routing all carry an explicit profile ID. Reject stale IDs. Updating a binary shared as an immutable cache must not share runtime state or grants.

Deleting a profile closes its pages and internal-settings surfaces, shuts down workers/ports, and disposes of its context before deleting data. Reassigning a space uses the destination profile; a live document must not silently retain the old profile's cookies or extensions. Keep a stable per-page profile binding and recreate affected pages with an explicit reload when reassignment changes that binding.

### 4. Extend the existing profile settings page

Add a **Chromium** section to `ProfileDetailForm` with these proposed destinations:

| Label | Initial route to verify against the pinned runtime |
| --- | --- |
| Chromium Settings | `chrome://settings/` |
| Extensions | `chrome://extensions/` |
| Privacy and Security | `chrome://settings/privacy` |
| Site Settings | `chrome://settings/content` |
| Clear Browsing Data | `chrome://settings/clearBrowserData` |

Use a typed action `openInternalPage(destination, profileID)` rather than treating this as an arbitrary external URL. Capture the form's selected profile ID at the click; revalidate it immediately before opening. Reuse an internal tab only for the same profile and destination, otherwise create a profile-bound surface. Support profiles with no space/window without changing their assignments. Display the profile name in the surrounding UI and handle deletion explicitly; never fall back to the active/default profile.

Let Chromium own its extension, site-permission and website-data preferences. Native controls overlapping those preferences must read/write through the adapter and refresh on returning from WebUI. Keep app-owned tab/space settings in the app. Establish a mapping for search/download settings before exposing controls for both; avoid two independent values for the same user choice. Hide unsupported shortcuts on the iOS WebKit backend. Validate internal pages against the actual pinned runtime rather than assuming every `chrome://` page is available.

### 5. Define broad extension support as a tested release contract

Freeze extension versions and a pass/fail matrix before the feasibility run. Candidate representatives: Bitwarden (popup/autofill/native host), uBlock Origin Lite (MV3 declarative rules), Dark Reader (content scripts/storage), SponsorBlock (network/content integration), React DevTools (devtools integration), plus maintained fixtures for worker suspend/resume, optional permissions, commands, context menus, options, downloads, `tabs/windows`, and messaging across frames. These are proposed test subjects, not verified compatibility claims.

Exercise install from the Chrome Web Store, verification of downloaded packages, update, disable, remove, and unpacked developer installation. Validate the actual distribution path and service restrictions before advertising it. Do not preserve the WebKit Web Store injector as the Chromium installation authority without review. Test rejected packages and updates adding permissions.

For every relevant case test Work/Personal profiles, two spaces sharing Work, multiple windows, restart, profile deletion, and private sessions. Match the selected Chromium release's supported extension manifest/API policy; do not promise obsolete Manifest V2 support. Browser-account sync is not required. Google's [Chromium API documentation](https://www.chromium.org/developers/how-tos/api-keys/) explicitly identifies restricted services and `chrome.identity.getAuthToken` limitations; record service-specific gaps rather than claiming every Chrome extension works. A required extension depending on such a service is a decision gate, not an automatic waiver.

Native hosts need origin allowlists, bounded messages, and profile-correct port ownership. Reuse the [documented native messaging protocol](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), while validating Barc host discovery and vendor allowlisting/signature expectations separately. Do not assume a host installed for Chrome automatically trusts Barc.

### 6. Port features in vertical slices

| Slice | Work and acceptance focus |
| --- | --- |
| Core browsing | Navigation, redirects, back/forward, session restore, find/zoom, downloads/uploads, drag/drop, context menus, keyboard/IME/accessibility |
| Native surfaces | Single-owner transfer, splits, Peek/popup/opener, fullscreen, printing/PDF, snapshots and devtools |
| Profile/security | Cookies and data deletion, permission prompts, certificates, proxies/network settings where supported, private disposal |
| Protection | Replace WK rule compilation with Chromium request/rule integration; preserve filter lists, exceptions, cosmetic scripts and blocking counters; measure overhead and avoid duplicate blocking with extensions |
| Media/auth | WebRTC camera/mic/screen share, audio routing/mute, mini-player/PiP, WebAuthn, vault/passkeys; test hardware-backed flows on real devices |
| Product integrations | Site tweaks/boosts/translation, full-text history, downloads tidying, AI browser tools and DevMCP, live folders and authenticated fetch paths |

Use native Chromium capabilities where appropriate and retire private WebKit hooks instead of translating private selectors. Do not keep a hidden WKWebView path for a difficult macOS feature without an explicit scoped decision.

### 6a. Make resource management a shared product policy

Implement one engine-neutral lifecycle coordinator for automatic pressure handling, timeout/budget eviction, and bulk hidden-tab actions. The current `TabCompositorManager` already protects visible, audible, PiP, mini-player and camera/microphone pages, but `TabsController.unloadAllHidden()` checks fewer signals. Neither path establishes a complete unsaved-work/upload/screen-sharing protection contract. Reconcile these paths before making eviction more aggressive.

Use explicit unloaded, loading, active, background, frozen (where supported), and discarded states. Separate page metadata and supported restoration state from the live engine object. Serialize transitions, cancel speculative work when a page is selected, and require completion of native-view and engine-object teardown before claiming a discard succeeded. Renderer-count/footprint measurements verify reclamation; hiding a view or issuing a close request is insufficient.

Treat presentation visibility as separate from freezing and residency. Apply the selected surface state when the engine's live native view is ready, update it on every surface transfer/selection, and preserve it through navigation. Verify `document.hidden` and animation-frame suspension in the document itself; a hidden containing view alone did not establish that state in the initial prototype. Restore visibility without reloading live pages. A page displayed in another window/split remains visible. Background timers, network and permitted media activity are distinct from animation-frame callbacks; stopping animation does not require freezing all page execution.

The user explicitly requires configurable performance optimizations. Extend the existing performance settings and persistence rather than introducing another configuration system. Keep ordinary correct visibility and activity protection unconditional; expose optional warming, proactive suspension/discarding and residency policy with understandable controls, live application and relaunch persistence. Implement only controls backed by working behavior. Do not add experimental knobs for engine capabilities the selected backend has not proved.

Activity protection carries reasons: visible surface, audible playback, PiP/mini-player, camera, microphone, screen sharing, active upload, detected unsaved work, and explicit keep-active preference. Capture protection must survive muted/silent calls. Unknown work state is not automatically safe to discard; define conservative handling and user-visible overrides. OS/browser-owned downloads may outlive pages only after that independence is proven. Freeze is also an interruption for calls, workers and time-sensitive applications, so it uses the same protection checks.

Restore saved sessions lazily. Bound eligible background residency with an initial count budget and hysteresis, then tune using aggregate process pressure, restoration latency and recency. Per-page memory estimates are advisory because processes and allocations can be shared. Current standard/performance modes have no eligible-tab count cap; power-saving caps eligible pages at eight while protected/pinned pages remain outside that count. Report protected over-budget workloads honestly. Make pinned position independent from an explicit keep-active choice; migrating that behavior requires a clear setting and regression coverage.

Prefer recent safe pages for a small warm set; freeze eligible idle pages to reduce background execution and discard colder pages when memory pressure/budget requires it. Preserve tab/profile identity and supported history/scroll state, but do not imply arbitrary JavaScript heaps or form state can survive destruction. Coordinate Chromium's own memory-saver decisions with this policy so two independent evictors cannot defeat protection. Native media state should come from runtime events and existing event-driven observations, with bounded reconciliation where required; do not add high-frequency polling.

Qualify media separately: HTML media/MSE, WebM/VP9/Opus, H.264/AAC where enabled and distributable, AV1 where available, HLS/DASH through the intended site/player paths, hardware decoding/fallback, fullscreen, system media controls, PiP/mini-player, WebRTC calls and screen sharing. Record codecs, acceleration and DRM/service access per architecture; Widevine/protected streaming is an explicit feasibility and distribution gate rather than an assumed Chromium feature. Choose mandatory sites/formats at G0. Test playback/capture while switching spaces/windows and while unrelated tabs are frozen/discarded, including silent screen sharing. An Arc-like media experience means this continuity and control behavior, not a promise that every streaming service works.

This coordinator can first improve the WebKit adapter after G2, independently of the larger Chromium port. Keep that slice small enough to validate its resource savings and media protection before enabling more aggressive defaults.

### 7. Migrate data by ownership, not file-format resemblance

Keep tab trees, profile assignments, history, settings, CloudKit records, and credential-provider references in their existing app-owned formats initially. Keep profile UUIDs stable. Do not add a bundle-ID change to the engine cutover.

- Stop writers and take a consistent backup, including SQLite/SwiftData WAL state and app-owned cookie snapshots. Never copy a live database piecemeal.
- Preflight free space, source readability, target ownership and concurrent app instances. Journal per-profile states such as pending/copying/validated/committed; use staging directories and atomic completion markers.
- Create new Chromium storage and validate it before switching the runtime selection. Never point Chromium at WebKit database directories.
- Treat cookies as a conditional supported import through public APIs, preserving attributes and profile ownership. Skip nonrepresentable cookies explicitly. Do not promise IndexedDB, service worker state, local storage, HTTP cache, passkey private material, or extension database portability.
- Present old global extensions as an inventory. Let the user select target profiles, reinstall verified packages and obtain required permissions. Never silently clone old global secrets/state into every profile.
- Preserve source snapshots until explicit cleanup. Rollback restores a compatible app snapshot; newer Chromium-only state remains separately retained/exportable. No simultaneous writes by old and new builds. Recovery does not imply Sparkle permits arbitrary downgrades or that old software remains safe indefinitely.

### 8. Own build integrity and engine updates

Build and qualify native arm64 and x86_64 engine, bridge, helper and dependency artifacts. Prefer a universal application when the engine packaging supports it; otherwise publish separately signed architecture-specific packages and explicit updater selection. Verify architecture coverage for every nested binary. Audit MLX and other optional features for Intel compatibility; use supported architecture guards and truthful UI availability rather than blocking Intel browser startup. Both architectures must pass the release gates independently.

Pin engine source/binary revision, build arguments, patches, SDK/toolchain, hashes and notices. Keep Chromium source/build caches and downloaded binaries outside normal source commits. Build a reproducible bridge/framework artifact with symbols and provenance. Full Chromium uses GN/Ninja as described in the [macOS build instructions](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/mac_build_instructions.md); size build machines and CI caches based on the first measured build.

Package browser/renderer/GPU/utility helpers and resources in the required layout. Decide run-loop ownership and initialize subprocesses before SwiftUI app startup as appropriate; `App/Main.swift` already has pre-start migration responsibilities. Extend `scripts/sign-app.sh` to sign all nested binaries with correct process-specific entitlements, then notarize/staple the result and rehearse a Sparkle update. Chromium's process sandbox and Apple's App Sandbox/hardened runtime are separate concerns. No release workaround may disable Chromium's sandbox or certificate validation. CEF's [sandbox setup](https://chromiumembedded.github.io/cef/sandbox_setup) is revision-sensitive; use the chosen revision's documented setup.

Assign an engine-update owner, monitor stable/security releases, and automate build + mandatory smoke/extension suite for bumps. Proposed response target: triage critical upstream fixes within one working day and aim to ship a qualified patched runtime within 72 hours of availability; confirm staffing at G0. This is an operational target, not an already achieved SLA. Do not ship a stale pinned engine just because application features are unchanged. Track codecs, DRM, WebRTC, and Google-service availability as separate compatibility entries; Chromium adoption alone grants neither service access nor redistribution rights.

### 9. Measure the actual product

Use signed Release baselines on real Intel and Apple Silicon machines, covering the minimum supported macOS and a current compatible macOS for each machine. Compare each candidate to the baseline on the same hardware; never average architectures together or treat Rosetta as Intel qualification. Match profiles, extension versions, blocker configuration, sites, screen resolution, power state, and warm/cold cache treatment. Separate synthetic local fixtures from variable live-site observations.

Measure cold/warm startup; navigation-to-interactive; scroll/input latency and frame drops; tab/space switching; 1/10/50-tab aggregate process memory; idle CPU; CPU/energy during a fixed video call and screen share; crash recovery; and installed/download size. Include browser, renderer, GPU and utility processes, not just the native parent. Reuse `scripts/perf/` and the existing `BrowserPerformance` hooks where useful.

Proposed gate budgets for review at G0: all mandatory workflows pass; at least a 10% improvement beyond run variance in one agreed user-relevant target (for example interaction latency on the current problematic workload); no more than 10% regression in p95 startup/input/tab-switch latency; no more than 20% aggregate memory regression at fixed tab count; no more than 10% energy regression in the fixed call workload. Record at least five comparable runs and median/p95 plus variance where meaningful. These are proposed budgets, not claimed results or user-approved limits. Freeze or explicitly revise them before candidate results are seen. Binary size gets an explicit distribution budget after the first engine build.

### 10. Separate GitHub detachment from code migration

The local repository already has only `origin`; removing an `upstream` remote would do nothing to GitHub's fork relationship. GitHub currently reports this fork as public, roughly 42 MB in its size field and with no child forks, which appears to meet its self-service detachment criteria. Recheck at execution time.

GitHub's [detachment documentation](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork) warns of permanent separation and loss of repository metadata. Inventory and export branches/tags, issues/PRs, release assets, discussions/wiki, settings, branch protections, webhooks, Pages, Actions variables/environments, runner bindings and secrets configuration references before choosing the operation. The API currently reports zero open issues; that does not prove all historical metadata is empty.

Prefer establishing the chosen standalone destination while retaining the old repository for the transition when metadata or feed continuity cannot be guaranteed. Do not prescribe deleting/recreating the existing repository as a routine step. Rehearse restoration, decide exact source/destination and what metadata can be recreated, then obtain explicit authorization for the irreversible operation during implementation. Never regenerate signing keys merely because the repository moved. Update runner allowlists and release URLs, and verify old-feed-to-new-feed updates before retiring any endpoint. The Barc plan owns naming and link content; this workstream owns detachment, repository metadata and infrastructure changes.

## Limited local spike: 2026-11-06

The user authorized this bounded experiment after the plans were prepared. It ran in `/tmp/barc-chromium-spike`, outside the application checkout, with isolated synthetic profiles. No application source, live user data, cloud configuration or repository hosting was changed. This is integration evidence and a source of optimization hypotheses, not completion of G0/G1 or product release qualification.

**Setup:** Intel iMac20,2, 64 GiB RAM, 20 logical CPUs, macOS 15.8.1, Xcode 26.3. Built CEF's `cefsimple` sample in Release with `PROJECT_ARCH=x86_64` and `USE_SANDBOX=ON`; compared it with a small optimized Swift/AppKit `WKWebView` host. Both used an 820x700 content area in a native window, one visible page, and hidden background views. Each synthetic page held a touched 16 MiB buffer, 3,000 DOM rows, an input, a timer and animation frames; the visible page played a muted looping 720p30 VP9 clip. No extensions were installed.

Pinned CEF stable `156.0.15+gcf671c0+chromium-156.0.8078.80`, obtained from the [official automated distribution index](https://cef-builds.spotifycdn.com/index.html). The standard x86_64 archive SHA-256 was `db77f7460ba172a9b2361894c4da062ac88e4f7346e319649217e891eedb4f68`; its published SHA-1 also matched. The resulting sample app occupied about 341 MiB. Matching arm64 distribution metadata was found; arm64 execution was not performed. Local synthetic Chromium profiles needed `--use-mock-keychain` to complete navigation; this test-only setup must not become production credential handling. No `--no-sandbox` switch was used; signed/notarized installed-build sandbox qualification remains outstanding.

### Integration findings

- A CEF page attached successfully under an application-created AppKit view. Requesting Chrome style with `SetAsChild` logged that Chrome style was unsupported and produced Alloy style instead. The pinned macOS API explicitly forces Alloy when `parent_view` is supplied; see [`cef_types_mac.h`](https://github.com/chromiumembedded/cef/blob/cf671c0/include/internal/cef_types_mac.h).
- In that embedded Alloy page, navigation to all five proposed settings/extension shortcuts returned `net::ERR_ABORTED`, leaving the fixture page in place. In a standalone CEF Chrome-style window the routes loaded the Settings/Extensions WebUI components, including the privacy, content and clear-browsing-data routes. This verifies neither profile correctness nor the underlying settings actions. A separate Chrome-style window does not establish integration into Barc's native content area.
- Native view ownership matters: initial CDP page-close requests left all ten targets/renderers retained. Correcting `DoClose` to tear down the child view and waiting for `OnBeforeClose` reduced the live target count to two and process count from fifteen to seven. The synthetic host then recreated a page in the same request context. See CEF's [macOS native delegate](https://github.com/chromiumembedded/cef/blob/cf671c0/libcef/browser/native/browser_platform_delegate_native_mac.mm) for the native-view lifetime mechanism. Debugging commands are measurement tools here, not the proposed product bridge.
- In the initial host, hiding the containing native views before browser creation did **not** make background Chromium documents report `document.hidden`; they continued animation frames. The follow-up below corrects this initialization ordering. This defect confounds the initial engine-level CPU comparison.

**Decision:** the straightforward CEF native-child-view route fails the embedded WebUI requirement at this revision. Keep the full Chromium browser-layer path as the baseline. Any alternative CEF Views/native-shell arrangement must demonstrate native integration, profile-bound WebUI and broad extensions before being substituted. Do not spend the next phase porting features onto an unqualified Alloy host.

### Measurements and optimization trial

The initial matrix ran each engine/tab count three times in alternating engine order. Figures are medians of summed process physical footprints after readiness and settling, including child/GPU/utility processes; WebKit XPC attribution is approximate and shared allocations may be counted more than once. They are footprint estimates, not unique physical RAM or measurements of the Nook application. WebKit used a nonpersistent store while CEF used a fresh disk-backed store, and background visibility differed as noted above. **Superseded for cross-engine comparison:** the follow-up established that the console had been locked during these initial runs and WebKit treated even its nominal foreground page as hidden. Keep these historical observations separate from the unlocked, visibility-checked comparison below.

| Synthetic workload | WebKit host | CEF embedded host |
| --- | ---: | ---: |
| 1 live page including video | 111 MiB | 262 MiB |
| 10 live pages including video | 448 MiB | 858 MiB |
| All 10 pages' load telemetry received after process launch | 703 ms | 784 ms |

Readiness is a local page load callback, not first paint or user-perceived interactivity. These results do not show a performance win from changing engines. They justify optimizing tab residency and the embedding lifecycle before evaluating the finished product.

After correcting teardown, a separate three-run Chromium trial compared live, frozen and discarded states in sequence:

| State of the ten-tab workload | Footprint | CPU (% of one core) | Live pages |
| --- | ---: | ---: | ---: |
| All pages live | 857 MiB | 22.9% | 10 |
| Eight background pages frozen | 850 MiB | 10.2% | 10 |
| Eight background pages destroyed; video plus one page retained | 320 MiB | 10.1% | 2 |

Freezing reduced observed CPU by about 55% with little memory reduction; native disposal reduced footprint by about 63%. The draft input survived freeze/resume and was lost on destruction, confirming the need to protect unsaved work. Destroying these synthetic pages was deliberate experiment control, not a candidate production eligibility policy. Recreating one destroyed local fixture took a median 103 ms, including command-delivery delay; this is not a general website restoration promise. The earlier matrix's CEF warm-reload timing is not comparable to WebKit recreation and is excluded from restoration conclusions.

The video remained playing through freezing/discarding unrelated tabs, with cumulative dropped frames of one or two across about 735 frames in each follow-up run. This establishes only continuity for the local muted VP9 fixture. Audio routing, PiP, WebRTC, screen sharing, codecs beyond that fixture, hardware-decode attribution and DRM remain untested. Freezing in this experiment used CDP lifecycle commands; a production adapter must provide an internal, protected lifecycle operation without exposing a debugging port.

Local reproduction materials are `bench.py`, `WKSpike.swift`, `site/`, the patched CEF sample, `results.json`, `followup.py` and `followup-results.json` under the temporary spike directory. They and downloaded binaries remain outside commits. Three repetitions on one working machine are exploratory evidence; the five-run signed-product matrix, actual Intel/Apple Silicon qualification, extension/profile isolation tests and real media workloads remain open.

**Next implementation priorities:** prove Chrome-layer native surface/WebUI ownership; centralize resource protection; correctly propagate background visibility; implement lazy loading plus bounded warm residency; verify complete page teardown; then qualify rich media and restoration on both architectures. Capture actual first paint separately from the existing `LaunchMetrics.markFirstPaint()` call at navigation commit before using that hook for release comparisons.

### Follow-up: correct native hidden-page behavior

The user requested a deeper spike because hidden tabs should not continue animation. Setting a container hidden before CEF created its child view did not reliably establish the document's hidden state. Applying visibility in `OnAfterCreated` corrected most runs, but repeated testing caught one background page becoming visible during startup. The final experimental host also rejects focus requests from unselected pages through `CefFocusHandler::OnSetFocus` and reconciles native visibility when navigation finishes. Selection state belongs to the host and is reapplied to the live page; ordinary tab switching does not wake already-hidden siblings.

The fix uses native AppKit visibility transitions. Chromium's [`WebContentsViewCocoa`](https://github.com/chromium/chromium/blob/156.0.8078.80/content/app_shim_remote_cocoa/web_contents_view_cocoa.mm) forwards its hide/show notifications to page visibility. Pages remain live; animation suspension is verified by `document.hidden` and unchanged animation-frame counters, without freezing or overriding JavaScript visibility properties. Timers and permitted background work remain subject to the engine's normal policy.

The console lock explained the failed WebKit foreground check. After the user unlocked the Mac, the benchmark required an unlocked console before and after each measured interval, nine hidden documents, and animation progressing in the selected page. Runs interrupted by relocking, or failing visibility checks, were rejected. The final table uses three valid runs per host/configuration with the same ten-tab fixture, eight-second measurement intervals, and one visible video page. The final Chromium correction was remeasured after adding focus/navigation handling; WebKit and the original Chromium host use the preceding valid unlocked control runs.

| Ten live tabs, one selected video page | Aggregate footprint | CPU (% of one core) | Background animation callbacks over the interval |
| --- | ---: | ---: | ---: |
| WebKit control | 516 MiB | 7.4% | 0 |
| Chromium host before visibility correction | 863 MiB | 21.0% | 2,517 |
| Chromium host with corrected visibility | 803 MiB | 8.6% | 0 |

Correct visibility reduced this host's CPU by about 59% and footprint by about 7%, while keeping all ten pages resident. The corrected Chromium host still used about 56% more aggregate footprint than the WebKit control in this fixture. These are host-level exploratory measurements; approximate WebKit process attribution, different profile-store modes and three short repetitions remain limitations. They do not establish a Chromium performance advantage or represent the full current Nook application.

Behavior checks also verified startup hiding, animation resumption when selecting a live page, retained draft input with zero reloads during tab switches, animation stopping again when switching away, and hidden reloads staying hidden. A separate check hid all three prototype pages and observed zero continuing animation callbacks. The selected video continued during the measured intervals. A muted video hidden by switching tabs paused and resumed under Chromium's own media policy; this does not qualify background audible media, PiP, capture or the proposed keep-active behavior. Global window occlusion/session-lock handling still needs installed-product qualification.

The corrected native behavior is the spike default; `BARC_SPIKE_LEGACY_VISIBILITY=1` selects the original host behavior only for comparison. The final CEF patch, Swift control host, benchmark scripts, fixture, manifest and validated results are retained in the ignored local directory `build/chromium-spike/`; binaries and the runnable working tree remain in `/tmp/barc-chromium-spike`. The retained `visibility-validated-results.json` contains only the nine accepted comparison runs. Trial scripts and evidence remain outside commits. Production application code and the outstanding CEF WebUI/extension feasibility decision are unchanged.

## Risks / Trade-offs

- Native embedding may not satisfy Chrome-style UI requirements -> G1 proves it before broad refactoring; full Chromium baseline is budgeted.
- Broad extensions can expose profile-boundary bugs -> isolation tests include workers, native ports, settings WebUI and extension tab enumeration.
- Chromium can use more memory or power despite better compatibility -> matched multi-process measurements gate promotion; no assumed performance win.
- Runtime integration increases maintenance -> narrow bridge, patch inventory, scheduled version bumps and a named security owner.
- Native/Chromium settings can diverge -> one authority per preference and explicit refresh/write-through behavior.
- Old global extension data may contain secrets -> selected-profile reinstall, explicit grants and no blind duplication.
- An optional dependency may lack an Intel slice (README flags MLX) -> isolate architecture-specific optional features and keep the core browser buildable on both; do not silently remove Intel support.
- Rebrand and engine changes share hotspots -> finish mechanical renames before seam extraction, or defer them until the engine branch settles; keep runtime and naming commits separate.

## Migration Plan

| Gate / phase | Deliverable | Exit condition |
| --- | --- | --- |
| G0: Baseline and release decisions | Fixed compatibility/extension matrix, per-architecture performance budgets, Intel/Apple Silicon dependency audit, build/security ownership, data inventory | Mandatory workflows and comparison setup recorded before candidate testing |
| G1: Runtime feasibility | Signed native prototype; CEF evaluated against the same full Chromium requirements | All profile settings, extension, isolation, native surface and sandbox checks pass; otherwise use full Chromium path |
| G2: Engine seams | WebKit running behind new contracts, no engine types in shared product interfaces | Existing package and UI checks pass on macOS; iOS still builds |
| G3: Chromium vertical slice | Profiles, page lifetime, navigation, internal pages, extension install/update | Profile suite and extension core matrix pass |
| G4: Feature and migration parity | Remaining browsing integrations, journaled conversion and recovery | End-to-end feature matrix plus interruption/failure tests pass |
| G5: Distribution readiness | Barc identity, standalone repository path, signed/notarized package, update rehearsal | Old-to-new-to-next update succeeds and recoverability verified |
| G6: Release qualification | Opt-in internal/canary use, then beta, then stable | Compatibility/performance gates pass; engine update process exercised |

Keep WebKit as the default through seam extraction. Use separate test profiles and an explicit restart-time engine choice in development/canary builds; never dynamically switch a live profile or silently mix engine stores. Freeze application schema churn around cutover. After a stable qualification period, remove transitional macOS WebKit code and flags while preserving iOS and necessary legacy import support.

Planning estimate, not a delivery commitment: G0/G1 2-4 engineer-weeks; G2 3-5; G3/G4 10-18 with the full Chromium path; G5/G6 3-6, plus 2-4 calendar weeks of beta observation. Budget roughly 4-8 months for one experienced full-time engineer, revisiting after G1; a qualified CEF path may reduce engine-maintenance work. Separate UI/runtime/release work can proceed concurrently once contracts stabilize, without assuming any particular team size.

Implement as reviewable slices rather than one huge PR. A standalone planning PR keeps these artifacts under this change directory. If implementation is published with its specification, synchronize delivered requirements into current specs and archive the implemented change on that feature branch before publication; split independently completed slices into scoped changes as needed. Track remaining merge, rollout, and live verification in tickets, and keep local traces, snapshots and trial scripts outside commits unless they become maintained regression tests.
