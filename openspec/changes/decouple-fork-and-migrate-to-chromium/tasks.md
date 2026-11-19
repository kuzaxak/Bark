# Implementation tasks

Unchecked production tasks remain outstanding. Complete the replacement and its functional tests on Intel first, using the executable bridge evidence to advance application integration. Defer ARM compilation and native qualification until the integrated replacement is ready; keep its current cache. Interactive native, signing and performance qualifications remain required before release and do not block independent implementation. A failing feature must be fixed before dependent code relies on it. Complete the Barc identity/reset transition separately; this engine migration preserves the resulting Barc data.

The immediate milestone is one usable integrated Intel app. Use the paired signed app and engine for startup/quit, browsing/history, drafts across tabs/spaces/splits/Peek, profile settings and isolation, extensions, downloads and screenshots. Continue fixing observed failures against that candidate and close the remaining feature gaps before starting more optimization work. Focused native tests and successful synthetic product workflows do not complete the ordinary interaction and release gates. Keep ARM and performance benchmarks deferred.

## 0. Authorized exploratory spike

- [x] 0.1 Run a bounded isolated Intel CEF/AppKit embedding spike, compare a synthetic WebKit baseline, inspect required WebUI routes, and measure freeze/discard effects; record conclusions and limitations in `design.md` while keeping trial code, binaries and raw evidence outside commits. This does not qualify broad extensions, profile isolation, Apple Silicon or signed distribution.
- [x] 0.2 Correct hidden-page visibility in the isolated native spike; verify stopped animation, live reactivation and hidden reload, then repeat the WebKit comparison without freezing and record the results. The final comparison uses three accepted unlocked runs per configuration; failed visibility/locked-session attempts are excluded.

## 1. Baseline and release contract (G0)

- [x] 1.1 Record the implementation base and release baseline; verify the intended branch contains the profile and tab behavior described in this plan. See the implementation baseline in `design.md`; universal unsigned Release compilation passed, while platform/runtime qualification remains in 1.2/1.4 and later gates.
- [ ] 1.2 Audit arm64/x86_64 slices for the engine candidates and app dependencies, including MLX; deliver a dual-architecture build matrix with optional feature handling documented.
  The [SDK architecture matrix](../../../Runtime/Chromium/README.md#publishing-the-engine) records shell and dependency coverage. The ARM64 engine receipt and native qualification remain open.
- [ ] 1.3 Freeze website workflows and extension versions/capabilities in a maintained acceptance matrix; verify all required spec scenarios have a case and assigned owner.
- [ ] 1.4 Capture repeatable baseline measurements on real Intel and Apple Silicon Macs using existing performance hooks; record hardware, build, workload and aggregate process metrics outside source commits.
- [ ] 1.5 Agree performance budgets, package-size budget procedure and engine-security response ownership before candidate measurement; verify the release checklist records those decisions.
- [ ] 1.6 Define the required media/site matrix, including codecs, MSE/streaming, hardware decoding, PiP/system controls, WebRTC/screen sharing and protected-content distribution feasibility; record mandatory cases separately from optional capabilities on each architecture.

## 2. Runtime feasibility (G1)

- [ ] 2.1 Qualify startup, clean shutdown and native focus in the selected full Chromium runtime without disabling the sandbox. Complete Intel integration first and carry these cases to final ARM qualification; do not build another CEF host after its rejection in 2.6.
- [ ] 2.2 Qualify profile-specific settings/extension WebUI and Work/Personal isolation in the selected runtime; verify each shortcut operates in the selected profile even with another front window.
- [ ] 2.3 Run the mandatory extension capability subset in the selected runtime; verify install/update, workers, action popup, native messaging and independent per-profile state.
- [ ] 2.4 Qualify live view transfer, split panes and popup/opener behavior in the selected runtime; verify form/history state survives transfer and keyboard/IME/accessibility work.
- [ ] 2.5 At final distribution qualification (G5), sign/notarize the integrated build and launch from an installed location on both architectures; verify helper signatures, resource discovery and sandbox behavior.
- [x] 2.6 Record CEF pass/fail against every G1 criterion; if any mandatory criterion fails, select the full Chromium path without reducing launch scope. Native multi-tab hosting failed; the gate table in `design.md` distinguishes partial profile evidence from failed or unqualified extension/lifecycle/distribution requirements. Full Chromium is selected.
- [ ] 2.7 Pin full Chromium source/toolchain/build arguments and produce the x86_64 browser-layer bridge first; verify provenance and Intel smoke launch. Produce and qualify arm64 after the integrated Intel replacement is ready.
- [ ] 2.8 For the full Chromium path, prove browser-context/extension/WebUI ownership and native surface lifecycle through the Intel bridge, including one native product window switching profile spaces with retained live pages and correct native/extension focus, independent private sessions, private data disposal and installed-extension denial despite regular-profile incognito opt-ins. Use mechanical evidence to document the G2 integration boundary; complete remaining interactive, ARM and installed-distribution checks before release. If CEF qualified, record the alternative explicitly.

## 3. Engine-neutral seams with WebKit (G2)

- [x] 3.1 Introduce engine profile/page/event contracts and lifetime rules; add contract tests for cancellation and callbacks arriving after close. `Profile`, `PageNavigation` and `NativePageHost` define the ownership boundary; `ProfileEngineTests` and `NativePageLifecycleTests` verify cancelled creation, close veto, owner teardown and rejection of late callbacks.
- [x] 3.2 Move `BrowserConfiguration` and profile storage access behind a WebKit adapter; verify shared-profile spaces and private-session isolation with regression tests.
  Chromium startup, Developer Mode and content blocking bypass WebKit configuration. ProfileEngineTests cover shared-profile spaces, private WebKit cookie isolation and Chromium profiles without a WebKit store. NativeBlockerModelTests cover the optional WebKit controller hook.
- [x] 3.3 Adapt `PageSession`, `WebViewProvider`, and `PageSessionDelegate`; verify navigation, URL/title state and close behavior using existing package checks.
  Chromium’s host implements the shared page delegate. WebKit hosts opt into the view provider and WebKit callbacks. The adopted-page regression covers commit, title, acknowledged close and a late title event.
- [x] 3.4 Separate AppKit surface ownership from page state; verify one live page per tab across window transfer, split and Peek checks.
  Page-host checks retain the existing page adapter across a window transfer. The signed Intel mini-window transfer in section 4a preserved the document and draft. AppKit checks cover promotion while the source pane keeps focus and a late Peek request for the promoted sibling. The signed split walk restored typing to the original document, draft and scroll position, and delivered a click to the uncovered sibling.
- [ ] 3.5 Remove engine types from shared public UI/model boundaries and document the adapter API; verify package builds.
  WebKit hosts use the explicit profile storage and page delegate adapters. The package suite exercises custom and private stores and Chromium profiles without a WebKit store. The old PDF overlay and its public WebKit save/open operations have been removed. Public WebKit view accessors on the shared page still need migration.

## 3a. Shared smart-tab policy (after G2, before G4 completion)

- [ ] 3a.1 Unify automatic and bulk resource actions behind one eligibility policy; test muted screen sharing, camera/mic, audio, PiP/mini-player, unsaved edits, uploads, unknown work state and explicit keep-active preferences.
  Signed Intel Bark reproduced the loss of a hidden edited document on bulk unload. The fixed action retained the original document, editability and draft, and reported the tab with unknown activity. The model tests also cover muted capture and known media.
- [ ] 3a.2 Implement lazy session restoration and a bounded eligible warm set; verify a large session does not create all live pages at startup and selected-tab restoration outranks queued warming.
- [ ] 3a.3 Add serialized freeze/discard/restore transitions and cancellation; verify teardown completion, no leaked page/view owners, profile/history continuity, restoration when returning to an inactive space without another tab click, and no late callback reviving a closed page.
- [ ] 3a.4 Separate pin/favorite placement from residency preferences and expose lifecycle reasons; verify protected over-budget cases remain active and are reported without recording page content.
- [ ] 3a.5 Adapt the policy to WebKit first and coordinate Chromium memory-saver ownership in the Chromium adapter; verify automatic and bulk engine decisions cannot bypass protected activity, inactive spaces' last selected pages remain subject to the background budget, and disabling optional policies cancels their pending actions.
- [ ] 3a.6 Compare the existing and candidate policies on matched 1/10/50-tab workloads on both architectures; report aggregate footprint, CPU, restoration latency and media/capture continuity together before changing defaults.
- [ ] 3a.7 Propagate actual presentation visibility at page creation, selection, navigation and window transfer; verify zero continuing animation-frame callbacks in hidden documents, live resumption without lost drafts, and continued animation for pages still displayed elsewhere.
  Signed Intel Bark stopped hidden animation, resumed the same editable document and kept both visible split panes animating. Hidden navigation and transfers between windows remain to be qualified.
- [ ] 3a.8 Expose persistent controls for optional resource optimizations through the existing performance settings; verify live policy changes, relaunch persistence, disabled optional actions and unchanged protection/visibility guarantees.

## 4. Chromium pages and profiles (G3)

- [x] 4.1 Integrate runtime initialization, bridge callbacks and shutdown into the process entrypoint; verify repeated launch/quit does not leak helpers or deadlock. Repeated signed Intel product launches with synthetic profiles and normal quit passed, including saved-window startup and the corrected streamed-download path; helper and listener cleanup passed. Native focus, installed distribution and ARM qualification remain separate gates.
- [ ] 4.2 Bind existing profile UUIDs to persistent Chromium contexts; test same-profile sharing, cross-profile isolation and profile renaming without storage relocation.
- [ ] 4.3 Implement ephemeral contexts and profile deletion/reassignment lifecycle; test no private residue, no surviving extension ports after deletion, assignment persistence failures, and reachable retry after relaunch even when the explicit survivor has no space. Preserve affected tab/window identities and source data until cleanup is admitted.
- [ ] 4.4 Implement Chromium navigation and observable page state; test redirects, back/forward, authentication popups and cancelled navigation.
- [ ] 4.5 Implement surface attach/detach and native focus routing; run window-transfer, two-to-four-pane splits across regular profiles, Peek promotion and popup-opener checks on both architectures. Verify pane-specific permission/extension ownership, capture protection for every displayed pane, and superseded saved-layout restoration.
- [x] 4.6 Handle process failures and diagnostics; terminate a renderer in a maintained integration test and verify recoverable affected tabs plus usable unrelated windows. The integrated Intel candidate passed `RendererFailurePreservesOtherProfileDocument`: the targeted renderer exited, its tab recovered through native navigation, and the other profile retained its renderer, live closure, draft and window ownership. ARM qualification remains in 9.1.

## 4a. Bark window and SDK cutover

- [x] Build the Intel app from a checkout with an absent output directory, using locked dependencies, tracked signing inputs and an SDK matching the checked-in pin. Verify the signature, embedded engine and final output. A fresh publication from the Intel Chromium output reproduced the checked-in headers and SDK digest.
- [x] Transfer the pinned Intel developer SDK through a gzip tar archive. An empty cache restored all 587 entries with the original executable bits and five framework aliases. The signed Bark app matched the transferred SDK, and a second export reproduced the same archive bytes.
- [x] Exercise a real modified link in a signed Bark window. Verify Escape restores source input and promotion to split preserves the preview document and its draft.
- [x] Qualify compact external-link windows and site popups on the same signed Intel candidate. Three 480 × 306 popups, including a cross-origin redirect, messaged the opener and returned input to its draft on close. The external mini's Open in Space button fit inside the header and a physical click preserved the live document and draft.
- [x] Complete host ownership of engine-created normal and private windows, extension UI and vault/passkey prompts. Intel engine regressions cover window ownership, superseding profile selections, pending-close refusal and cancellation of outgoing prompts. The signed Intel app opened extension actions from both toolbar placements. On a loopback site it filled a synthetic login, saved another through Bark’s native card, and filled the new login in a fresh document. Choosing Pawl in Chromium’s WebAuthn chooser opened Bark’s consent sheet on the requesting window. Canceling the sheet and dismissing Chromium’s acknowledgement returned `NotAllowedError` to the page with zero registrations. Hardware and real Pawl integration are tracked in 6.8.
- [x] Retire the stock macOS browser window at the factory and all launch entry points. Browser tests use the same factory. The signed Intel candidate passed startup, popup, Peek and retired-switch checks. Engine tests covered private windows, app-owned commands, external URLs and Dock reopen.
- [x] Measure first physical input and return to a parked live tab on the signed Intel developer candidate. Three guarded fresh-profile trials on an iMac20,2 (i9-10900K, 64 GiB, macOS 15.8.1) observed 2.06–2.22 s from launch to the first trusted pointer event (median 2.09 s) and 104–262 ms from switching back to a trusted key in the original draft field (median 113 ms). The outgoing page was hidden and absent from the physical window’s accessibility tree, then accepted input in the same document with the draft and focus retained. Chromium reported no discard. These observed bounds include harness and loopback overhead with uncontrolled machine caches. Disk-discard recovery was outside this walk.
- [x] Verify installation and update on the signed Intel developer build. Install build 100 from its Developer ID signed disk image into a private Applications directory. Sparkle rejected a changed Ed25519 signature and kept the original app running. With the valid archive it relaunched build 101 from the installed executable path and restored the saved draft. The installed launcher, Swift shell and Chromium framework matched the signed update images byte for byte. The replacement also passed the full embedded SDK comparison against the Intel pin.
- [x] Cross-compile the app executable and full Swift/AppKit shell for Intel and Apple Silicon. Both Release builds linked against the public SDK headers, exported the native shell entry and contained the app resources. Mach-O inspection verified each target architecture and the bundle-local engine-loading boundary.
- [ ] Qualify the official optimized engine and both SDK slices. Verify successful first input, return to parked tabs, signed installation and installed updates on native Intel and Apple Silicon Macs.

## 5. Profile extensions and settings (G3)

- [ ] 5.1 Replace global extension ownership with a profile registry; test separate installation, enablement, storage and permissions for the same extension in two profiles.
- [ ] 5.2 Implement verified installation/update/removal and permission prompts; test invalid packages, permission-increasing updates, restart and independent profile actions.
- [ ] 5.3 Integrate extension actions, options, workers and tab/window events; test real suite representatives and ensure no events cross profile/private boundaries.
- [ ] 5.4 Adapt native host discovery and ports; test allowed/disallowed origins, vendor host behavior and port shutdown on profile deletion.
- [ ] 5.5 Add typed profile-bound internal-page actions to `ProfileDetailForm`; test every quick link, inactive/no-window profiles, changed selection and deleted-profile races.
- [ ] 5.6 Map overlapping native/Chromium preferences through one authority and refresh the native form on return; verify data deletion and preference edits affect only the selected profile. Complete one-time search-choice import, native/WebUI consistency, controlled-provider restrictions, custom request semantics and suggestion ownership against `profile-extensions/spec.md`; retain Keychain-backed Kagi credentials without copying them into provider templates.
- [ ] 5.7 Document supported extension APIs/service limitations and run the full frozen suite on Intel before exiting G3; repeat every mandatory entry on Apple Silicon at final qualification.

## 6. Feature parity (G4)

- [ ] 6.1 Adapt downloads/uploads and file panels; test cancellation, suggested names, destination selection and download history.
- [ ] 6.2 Adapt site permissions, certificate warnings and cookies/data deletion; test denied capture, exceptions and profile isolation.
- [ ] 6.3 Port native navigation conveniences, back/forward history menus, find/zoom, context menus, shortcuts and drag/drop; run the corresponding existing UI checks and IME/accessibility smoke cases. Include the optional top address bar and per-site Developer bar in the actual Chromium shell; switching address placement must retain a visible, working address control, and enabling a site Developer bar must display its tools on that page.
- [ ] 6.4 Implement Chromium blocker request integration using existing filter policy; test blocking, redirects, frame/worker ownership, exceptions, counters and coexistence with extension rules against `content-blocking/spec.md`. Preserve exact private-context ownership and qualify worker attribution separately from ordinary page requests. Verify saved whitelist/optional-list settings before first load, windowless service-worker wakes, private-menu first-request admission and superseded startup policy; ordinary-window checks alone do not qualify startup coverage.
- [ ] 6.5 Port cosmetic rules, scriptlets, tweaks and translation using the appropriate page or isolated context; test document-start ordering, frame handling and protection against untrusted native-bridge messages. Include the existing optional YouTube/Facebook/Reddit features, SponsorBlock, social downloads and saved opt-in Boost JavaScript; filter-list scriptlets and Boost CSS alone do not complete this task. Verify Boost editing and picking through an actually mounted native product control.
- [ ] 6.6 Port PDF/printing, snapshots and developer tools; verify embedded/docked tools and keyboard focus without an unintended second browser shell.
  Signed Intel Bark showed a one-page PDF in its own print preview. Escape dismissed the preview and left the source PDF open. The native-host engine regression also checks ownership across profiles and still requires a linked run.
- [ ] 6.7 Port media state, mute, audio routing, PiP and mini-player; verify call/screen-share/video workflows and energy metrics on both architectures.
- [ ] 6.8 Adapt vault/autofill and WebAuthn integration; preserve Pawl password/OTP selection, password saving and passkeys, including availability after startup and exact-field cancellation. Test actual picker focus restoration, origin/profile-bound consent and supported hardware/security-key flows. Native form filling or stock Chromium WebAuthn alone does not complete this task.
- [ ] 6.9 Adapt AI browser tools, DevMCP and authenticated live-fetch consumers to engine contracts; verify existing tool behavior and permission boundaries against `browser-automation/spec.md` without adding new AI features. Cover approval-time target changes, late asynchronous results, script restrictions and cancellation without a hidden WebKit fallback.
- [ ] 6.10 Update maintained architecture and compatibility documentation for each migrated feature; verify no macOS feature silently falls back to a hidden WebKit page.
- [x] 6.11 Port opt-in page-text history capture; verify searchable regular-page text, private/Agent exclusions, disabled settings and stale-result rejection without creating a WebKit page. Signed Intel product checks confirmed body-only search in the persisted index, Agent exclusion and no index when disabled. Maintained tests cover private/Agent admission, same-path coalescing and seven late-result invalidations without a WebKit page. Private product execution and palette/preference UI qualification remain in 9.1.
- [ ] 6.12 Stop rendering Chromium's tab strip and toolbar in browser windows; verify in the real window across single, split, Peek, private, full-screen and relaunch states, plus focus, accessibility and toolbar-anchored prompts.
- [ ] 6.13 Run Nook's tab, space, window and split shortcuts in Chromium windows, which `KeyboardShortcutManager` currently gates off; verify each acts on the sidebar's tabs rather than Chromium's hidden strip.
- [ ] 6.14 Present every split through one app-controlled composition of independent tabs, replacing `SplitTabCollection`; verify side-by-side and top-to-bottom layouts, divider resize, same-profile, cross-profile and private splits, and Peek over a split in the real window.
- [x] 6.15 Expose extension actions, popups and pinning in the native sidebar. In the signed Intel app, install an unpacked MV3 extension through Manage Extensions, pin it in Site Controls, open its popup from the sidebar and again after moving the toolbar above the page, dismiss it, and unpin it. Engine tests also verify managed pinning and profile ownership.
- [ ] 6.16 Wire the AI assistant, its settings and its browser tools in Chromium windows; verify a tool call acts on the exact visible page.
- [ ] 6.17 Show empty spaces and move loaded tabs between profiles in Chromium windows, with Chromium's fallback client never carrying a window into another space; verify creating a space, closing a space's last tab, closing with another space retained, and moving a tab in the real window.
- [ ] 6.18 Close the app-side parity gaps from the Chromium feature audit: theme and appearance, General settings, Site Controls, space deletion, quit-time saves, palette and shortcut actions, favorite cards; verify each in the real window.
  Signed Intel Bark exposed distinct Back and Forward controls in Settings. A disposable host using Bark's updater and the pinned Sparkle framework verified automatic-check and download controls, their persisted values after relaunch, and their absence during update rehearsal.
- [ ] 6.19 Add the engine hooks the audit needs: favicons, navigation policy for link cleaning, site routing and Warn-before-HTTP, hovered link, load progress, session state after unload; verify each in the real window.
- [ ] 6.20 Make the Chromium window match Arc: window controls on one row, framed page with rounded corners, address control at rest, Favorites tiles, Library layout, and no Chromium bookmark interface; verify by side-by-side comparison with the real Arc window, with the owner judging.

## 7. Engine data conversion and recovery (G4)

- [ ] 7.1 Add consistent backup, free-space and concurrent-writer preflight; test cancellation, read failure and disk exhaustion without changing source data.
- [ ] 7.2 Implement staged per-profile migration journals; test process interruption/retry without duplication or overwriting completed destination profiles.
- [ ] 7.3 Preserve app-owned records and stable IDs; test representative multi-profile tabs/history/settings and resulting Barc sync state.
- [ ] 7.4 Implement supported cookie import with explicit skips; test same-site sessions in different profiles and nonrepresentable attributes.
- [ ] 7.5 Add selected-profile conversion of global extensions and migration notices; verify no automatic all-profile secret/state duplication and required permissions are requested.
- [ ] 7.6 Implement recovery using engine-compatible snapshots; verify newer Chromium data is retained and document user-visible recovery limits.

## 8. Distribution and repository readiness (G5)

- [ ] 8.1 Export repository metadata and verify a Git mirror of published refs; prepare a concrete detachment/destination runbook without changing the live fork.
- [ ] 8.2 Prepare Barc feed/source/support configuration and runner allowlist changes coordinated with the rebrand; verify all destinations and old-feed bridging in a staging rehearsal.
- [ ] 8.3 Package native engine/bridge/helpers for Intel and Apple Silicon; verify every nested executable architecture and resource path in the installed artifact.
- [ ] 8.4 Extend inside-out signing, provisioning validation and notarization for runtime helpers; verify installed launch, sandbox and Gatekeeper acceptance on both architectures.
- [ ] 8.5 Exercise a signed application update and recovery with realistic profile data; verify the correct architecture receives a compatible package.
- [ ] 8.6 Add version/provenance diagnostics, license notices and an engine-update runbook; rehearse one engine bump through the smoke and extension gates.
  Signed Intel Bark’s Help menu reports the app build, Chromium version, architecture and verified engine manifest digest. The target-specific packaging tests cover both architectures.

## 9. Integrated qualification (G6)

- [ ] 9.1 Run the complete compatibility, extension and migration matrices on both architectures; attach concise results to the review/ticket and keep transient logs outside commits.
- [ ] 9.2 Compare candidate measurements against the frozen per-architecture budgets; record pass/fail and any explicitly accepted change before promotion.
- [ ] 9.3 Prepare opt-in canary/beta rollout, recovery instructions and named security ownership; verify a release candidate can use the runbook without undocumented steps.
- [ ] 9.4 Remove the remaining WebKit paths and flags while retaining read-only import of the WebKit app's data; verify both architecture builds and the final runtime suite. The legacy app scene, desktop window, split compositor, mini-window presenter, extension host and app-owned cookie/cache managers have been removed. Bark's profile-specific Chromium controls handle site data. Shared WebKit services and fixtures remain.

## Workflow follow-up

- Publish standalone planning artifacts under this change directory when requested. No implementation is completed by this plan.
- Split independently implemented slices into scoped changes as needed; synchronize current specs and archive implemented changes on their feature branches before publishing solution PRs.
- Obtain authorization for the concrete irreversible repository operation after the metadata backup and transition rehearsal are reviewable; then verify fork independence, preserved refs and infrastructure settings.
- Track merge, canary/beta/stable rollout and live verification in tickets; public Chromium distribution depends on the Barc identity/reset release.
