# Independent Chromium browser

## Why

The fork needs its own release direction and Chromium compatibility while retaining Nook's native browser interface and user data. WebKit types currently cross page, profile, extension, download, and automation boundaries; replacing the view alone cannot deliver broad Chrome extension support or establish a measurable performance improvement.

## What Changes

- Establish an independent repository and release operation, preserving Git history, provenance, and license notices. Repository detachment is a separate operational step with a metadata backup and recovery plan.
- Replace the macOS browsing backend with Chromium behind engine-neutral page and profile interfaces. Preserve the native SwiftUI/AppKit shell, spaces, tabs, split views, Peek, and multi-window ownership.
- Require broad Chrome extension support at launch, including installation and updates, MV3 workers, actions/popups, permissions, storage, and native messaging. Select the integration through an early feasibility gate; do not assume a basic CEF view supplies the full browser feature set.
- Make extension installation, enabled state, permissions, and storage independent per profile. Add profile-settings shortcuts to Chromium settings and the extension manager in the selected profile.
- Preserve application-owned data, isolate Chromium profile storage, and provide restart-safe migration and recovery.
- **BREAKING:** WebKit website storage and extension state are not directly reusable as Chromium databases. Some sessions may require sign-in and extensions may require reinstallation; explain this before migration.
- Gate rollout on compatibility, security, and measured performance. Adopt a maintained Chromium update process.
- Prioritize responsive tab switching and bounded background resource use with a media-aware tab lifecycle, including safe suspension/restoration and explicit protection for playback, calls, screen sharing, and user work.

## Capabilities

### New Capabilities

- `independent-distribution`: Maintainer-owned source, support, and update destinations with retained provenance.
- `browser-runtime`: Chromium browsing behavior, lifecycle, native-shell continuity, isolation, and release qualification.
- `profile-extensions`: Broad extension behavior and profile-bound Chromium settings entry points.
- `engine-data-transition`: Recoverable migration of application data and explicit treatment of nonportable site data.
- `tab-resource-lifecycle`: Predictable background-tab resource management that preserves media continuity and user work.
- `content-blocking`: Existing filter policy, exceptions and page protection applied by Chromium without crossing profile boundaries or overriding extension decisions.

### Modified Capabilities

None: this is the first specification set in the repository. Existing behavior to preserve is included in the new contracts.

## Impact

Primary areas: `Packages/NookWeb` (especially `PageSession`, `Profile`, `BrowserConfiguration`, `WebViewProvider`, and `PageSessionDelegate`), `NookBlocker`, `NookTweaks`, native view hosting, `ExtensionManager`, downloads, cookies, permissions, vault/passkeys, AI/MCP tools, build/signing/release scripts, and CI. Chromium introduces packaged helper processes, resources, build provenance, and responsibility for engine security updates.

Required platform scope is macOS on both Intel (x86_64) and Apple Silicon (arm64), as confirmed by the user; retain the current 15.5 deployment target unless separately agreed. This branch builds only the Chromium product, `Bark.app`: the owner removed the iOS app and the WebKit macOS app from it on 2026-11-10. The WebKit app keeps building from `develop`, which is the fallback and the reference for existing behavior. iOS and other platform expansion, Google account browser sync, universal extension compatibility, and new AI features are out of scope.

The companion change `rebrand-nook-to-bark` owns the Bark name, visual identity, and public-facing rebrand. Ship that identity before public distribution of the independent Chromium product.
