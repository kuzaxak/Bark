# Implementation tasks

Unchecked production tasks remain outstanding. The local spikes inform this plan and do not complete G1. Complete the Barc identity/reset transition separately; this engine migration preserves the resulting Barc data. Follow the gates in `design.md`; do not begin broad feature porting before runtime feasibility passes.

## 0. Authorized exploratory spike

- [x] 0.1 Run a bounded isolated Intel CEF/AppKit embedding spike, compare a synthetic WebKit baseline, inspect required WebUI routes, and measure freeze/discard effects; record conclusions and limitations in `design.md` while keeping trial code, binaries and raw evidence outside commits. This does not qualify broad extensions, profile isolation, Apple Silicon or signed distribution.
- [x] 0.2 Correct hidden-page visibility in the isolated native spike; verify stopped animation, live reactivation and hidden reload, then repeat the WebKit comparison without freezing and record the results. The final comparison uses three accepted unlocked runs per configuration; failed visibility/locked-session attempts are excluded.

## 1. Baseline and release contract (G0)

- [x] 1.1 Record the implementation base and release baseline; verify the intended branch contains the profile and tab behavior described in this plan. See the implementation baseline in `design.md`; universal unsigned Release compilation passed, while platform/runtime qualification remains in 1.2/1.4 and later gates.
- [ ] 1.2 Audit arm64/x86_64 slices for the engine candidates and app dependencies, including MLX; deliver a dual-architecture build matrix with optional feature handling documented.
- [ ] 1.3 Freeze website workflows and extension versions/capabilities in a maintained acceptance matrix; verify all required spec scenarios have a case and assigned owner.
- [ ] 1.4 Capture repeatable baseline measurements on real Intel and Apple Silicon Macs using existing performance hooks; record hardware, build, workload and aggregate process metrics outside source commits.
- [ ] 1.5 Agree performance budgets, package-size budget procedure and engine-security response ownership before candidate measurement; verify the release checklist records those decisions.
- [ ] 1.6 Define the required media/site matrix, including codecs, MSE/streaming, hardware decoding, PiP/system controls, WebRTC/screen sharing and protected-content distribution feasibility; record mandatory cases separately from optional capabilities on each architecture.

## 2. Runtime feasibility (G1)

- [ ] 2.1 Pin a CEF Chrome-runtime candidate and build a minimal native host on both architectures; verify startup, clean shutdown and native focus without disabling the sandbox.
- [ ] 2.2 Prototype profile-specific settings/extension WebUI and Work/Personal isolation; verify each shortcut operates in the selected profile even with another front window.
- [ ] 2.3 Run the mandatory extension capability subset in that host; verify install/update, workers, action popup, native messaging and independent per-profile state.
- [ ] 2.4 Prototype live view transfer, split panes and popup/opener behavior; verify form/history state survives transfer and keyboard/IME/accessibility work.
- [ ] 2.5 Sign/notarize the prototype and launch from an installed location on both architectures; verify helper signatures, resource discovery and sandbox behavior.
- [x] 2.6 Record CEF pass/fail against every G1 criterion; if any mandatory criterion fails, select the full Chromium path without reducing launch scope. Native multi-tab hosting failed; the gate table in `design.md` distinguishes partial profile evidence from failed or unqualified extension/lifecycle/distribution requirements. Full Chromium is selected.
- [ ] 2.7 For the full Chromium path, pin source/toolchain/build arguments and produce native x86_64/arm64 browser-layer bridge artifacts; verify provenance and smoke launch for each. If CEF qualified, record this task as superseded in a reviewed task revision.
- [ ] 2.8 For the full Chromium path, prove browser-context/extension/WebUI ownership and native surface lifecycle through the bridge; rerun 2.2-2.5 and document the integration boundary before G2. If CEF qualified, record the alternative explicitly.

## 3. Engine-neutral seams with WebKit (G2)

- [ ] 3.1 Introduce engine profile/page/event contracts and lifetime rules; add contract tests for cancellation and callbacks arriving after close.
- [ ] 3.2 Move `BrowserConfiguration` and profile storage access behind a WebKit adapter; verify shared-profile spaces and private-session isolation with regression tests.
- [ ] 3.3 Adapt `PageSession`, `WebViewProvider`, and `PageSessionDelegate`; verify navigation, URL/title state and close behavior using existing package checks.
- [ ] 3.4 Separate AppKit surface ownership from page state; verify one live page per tab across window transfer, split and Peek checks.
- [ ] 3.5 Remove engine types from shared public UI/model boundaries and document the adapter API; verify package builds and the existing iOS target remain buildable.

## 3a. Shared smart-tab policy (after G2, before G4 completion)

- [ ] 3a.1 Unify automatic and bulk resource actions behind one eligibility policy; test muted screen sharing, camera/mic, audio, PiP/mini-player, unsaved edits, uploads, unknown work state and explicit keep-active preferences.
- [ ] 3a.2 Implement lazy session restoration and a bounded eligible warm set; verify a large session does not create all live pages at startup and selected-tab restoration outranks queued warming.
- [ ] 3a.3 Add serialized freeze/discard/restore transitions and cancellation; verify teardown completion, no leaked page/view owners, profile/history continuity, and no late callback reviving a closed page.
- [ ] 3a.4 Separate pin/favorite placement from residency preferences and expose lifecycle reasons; verify protected over-budget cases remain active and are reported without recording page content.
- [ ] 3a.5 Adapt the policy to WebKit first and coordinate Chromium memory-saver ownership in the Chromium adapter; verify automatic engine decisions cannot bypass protected activity.
- [ ] 3a.6 Compare the existing and candidate policies on matched 1/10/50-tab workloads on both architectures; report aggregate footprint, CPU, restoration latency and media/capture continuity together before changing defaults.
- [ ] 3a.7 Propagate actual presentation visibility at page creation, selection, navigation and window transfer; verify zero continuing animation-frame callbacks in hidden documents, live resumption without lost drafts, and continued animation for pages still displayed elsewhere.
- [ ] 3a.8 Expose persistent controls for optional resource optimizations through the existing performance settings; verify live policy changes, relaunch persistence, disabled optional actions and unchanged protection/visibility guarantees.

## 4. Chromium pages and profiles (G3)

- [ ] 4.1 Integrate runtime initialization, bridge callbacks and shutdown into the process entrypoint; verify repeated launch/quit does not leak helpers or deadlock.
- [ ] 4.2 Bind existing profile UUIDs to persistent Chromium contexts; test same-profile sharing, cross-profile isolation and profile renaming without storage relocation.
- [ ] 4.3 Implement ephemeral contexts and profile deletion/reassignment lifecycle; test no private residue and no surviving extension ports after deletion.
- [ ] 4.4 Implement Chromium navigation and observable page state; test redirects, back/forward, authentication popups and cancelled navigation.
- [ ] 4.5 Implement surface attach/detach and native focus routing; run window-transfer, split, Peek promotion and popup-opener checks on both architectures.
- [ ] 4.6 Handle process failures and diagnostics; terminate a renderer in a maintained integration test and verify recoverable affected tabs plus usable unrelated windows.

## 5. Profile extensions and settings (G3)

- [ ] 5.1 Replace global extension ownership with a profile registry; test separate installation, enablement, storage and permissions for the same extension in two profiles.
- [ ] 5.2 Implement verified installation/update/removal and permission prompts; test invalid packages, permission-increasing updates, restart and independent profile actions.
- [ ] 5.3 Integrate extension actions, options, workers and tab/window events; test real suite representatives and ensure no events cross profile/private boundaries.
- [ ] 5.4 Adapt native host discovery and ports; test allowed/disallowed origins, vendor host behavior and port shutdown on profile deletion.
- [ ] 5.5 Add typed profile-bound internal-page actions to `ProfileDetailForm`; test every quick link, inactive/no-window profiles, changed selection and deleted-profile races.
- [ ] 5.6 Map overlapping native/Chromium preferences through one authority and refresh the native form on return; verify data deletion and preference edits affect only the selected profile.
- [ ] 5.7 Document supported extension APIs/service limitations and run the full frozen suite on Intel and Apple Silicon; verify every mandatory entry passes before exiting G3.

## 6. Feature parity (G4)

- [ ] 6.1 Adapt downloads/uploads and file panels; test cancellation, suggested names, destination selection and download history.
- [ ] 6.2 Adapt site permissions, certificate warnings and cookies/data deletion; test denied capture, exceptions and profile isolation.
- [ ] 6.3 Port native navigation conveniences, find/zoom, context menus, shortcuts and drag/drop; run the corresponding existing UI checks and IME/accessibility smoke cases.
- [ ] 6.4 Implement Chromium blocker request integration using existing filter policy; test blocking, exceptions, counters and coexistence with extension rules.
- [ ] 6.5 Port cosmetic rules, scriptlets, tweaks and translation to isolated script contexts; test frame handling and protection against untrusted native-bridge messages.
- [ ] 6.6 Port PDF/printing, snapshots and developer tools; verify embedded/docked tools and keyboard focus without an unintended second browser shell.
- [ ] 6.7 Port media state, mute, audio routing, PiP and mini-player; verify call/screen-share/video workflows and energy metrics on both architectures.
- [ ] 6.8 Adapt vault/autofill and WebAuthn integration; test supported hardware/security-key flows and origin-bound credential prompts.
- [ ] 6.9 Adapt AI browser tools, DevMCP and authenticated live-fetch consumers to engine contracts; verify existing tool behavior and permission boundaries without adding new AI features.
- [ ] 6.10 Update maintained architecture and compatibility documentation for each migrated feature; verify no macOS feature silently falls back to a hidden WebKit page.

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

## 9. Integrated qualification (G6)

- [ ] 9.1 Run the complete compatibility, extension and migration matrices on both architectures; attach concise results to the review/ticket and keep transient logs outside commits.
- [ ] 9.2 Compare candidate measurements against the frozen per-architecture budgets; record pass/fail and any explicitly accepted change before promotion.
- [ ] 9.3 Prepare opt-in canary/beta rollout, recovery instructions and named security ownership; verify a release candidate can use the runbook without undocumented steps.
- [ ] 9.4 After qualification, remove transitional macOS WebKit paths and flags while retaining iOS/import support; verify both desktop builds, iOS build and final runtime suite.

## Workflow follow-up

- Publish standalone planning artifacts under this change directory when requested. No implementation is completed by this plan.
- Split independently implemented slices into scoped changes as needed; synchronize current specs and archive implemented changes on their feature branches before publishing solution PRs.
- Obtain authorization for the concrete irreversible repository operation after the metadata backup and transition rehearsal are reviewable; then verify fork independence, preserved refs and infrastructure settings.
- Track merge, canary/beta/stable rollout and live verification in tickets; public Chromium distribution depends on the Barc identity/reset release.
