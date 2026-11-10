# Bark identity and fresh-start transition

## Context

See [proposal.md](proposal.md) and the identity/continuity specs. The user confirmed Bark, a new logo, Intel plus Apple Silicon support, a new App ID and a new CloudKit container. They subsequently accepted a reset because there are few users. This supersedes the earlier idea of retaining old identifiers or migrating cloud records.

The current target bundle ID is `ee.qdo.nook`; release entitlements specify `538SB59LX4.ee.qdo.nook` and `iCloud.ee.qdo.nook`. `SpaceSyncAvailability.containerID` in `Packages/NookTabsCore/Sources/NookTabsCore/SpaceSync.swift` hardcodes the container, and `SpaceSyncManager` explicitly creates it. Sync uses private and shared databases, zone shares, and `Sync/spaces.json` beside the tab data. Signature/profile checks in `scripts/sign-app.sh` hardcode the old App ID. These are coordinated changes, not a search-and-replace of visible strings.

The WebKit app's entry, `App/Main.swift` on `develop`, runs `LegacyDataMigration` before constructing app state; Bark does not run it. That migrator automatically copies selected historical stores/defaults into the running bundle's domain. Its source list omits the current `ee.qdo.nook`, and comments mention another historical ID. It cannot be reused blindly for the new clean-start behavior.

The logo is present in `Nook/logo.icon`, `Nook/logo-dev.icon`, `Nook/Assets.xcassets/nook-logo-1024.imageset`, and repository assets. Product naming also appears in project/scheme names, menus, onboarding, shared UI, plist descriptions, Sparkle appcasts, release scripts, and upstream-oriented README links.

## Goals / Non-Goals

**Goals:** a coherent Bark identity; correct signing and cloud entitlements for a new application identity; understandable fresh-start onboarding; a verified installation/update path on Intel and Apple Silicon.

**Non-goals:** copying old CloudKit records or shares, preserving old invitations, synchronizing old Nook and Bark clients together, renaming an existing CloudKit container, changing developer teams, or switching renderers in the same release. Deleting the old cloud container or users' local files is unnecessary for starting fresh and is not part of this implementation.

## Decisions

### 1. Explicit identity map

| Surface | Planned identity | Handling |
| --- | --- | --- |
| Product/display name | Bark | All current product surfaces |
| macOS product/executable/project | `Bark.app`, `Bark`, `Bark.xcodeproj` | Coordinate schemes, scripts, resource lookup and updater relaunch |
| Main bundle ID | `ee.qdo.bark` (set by the owner on 2026-11-09) | New explicit App ID under the existing developer team |
| Application entitlement | `538SB59LX4.ee.qdo.bark` if the issued profile uses that prefix | Derive/verify against issued provisioning, never assume a prefix solely from team ID |
| CloudKit container | `iCloud.ee.qdo.bark` (set by the owner on 2026-11-09) | New development/production schema and new user data |
| Helper IDs | Derived unique Bark IDs per helper | Coordinate with the selected Chromium packaging later |
| Update trust | Existing trusted Sparkle signing identity | Do not rotate merely for branding or repository movement |
| Space file import | Continue `.nookspace` support | Keep legacy input identifiers; a new export suffix is not required for this change |
| Persisted keys | Retain where compatibility/import requires them | Document a deliberate allowlist, do not replace indiscriminately |
| Repository | Proposed `kuzaxak/Bark`, pending availability | Independence workstream performs external transition; this plan supplies naming/link edits |

Keep App ID, container ID and product strings in clear configuration sources with explicit legacy constants. Avoid deriving CloudKit identity automatically from display name or bundle ID. Treat bundle identity as a registration and signing change, not as renaming an existing Apple identifier in place. Apple's [bundle identifier documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier) explains its system/signing role and the restriction after App Store upload. Inspect any iOS/TestFlight/App Store records before changing that target: an existing uploaded App Store identity cannot be changed as an ordinary update; a new identity requires a new app record/install path. The macOS direct-distribution plan must not imply an in-place iOS store migration.

### 2. Fresh CloudKit container, with no old-cloud copy

Apple documents that a container [cannot be renamed or deleted after creation](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app). Use a new container rather than pretending the old one was renamed. Development and production have separate schema/data state; schema promotion is not record migration ([CloudKit design guidance](https://developer.apple.com/icloud/cloudkit/designing/)).

Implementation sequence:

1. Confirm access to the existing developer team and availability of the proposed identifiers. Register the new explicit App ID and new iCloud container; associate only the intended Bark container, CloudKit service and push capability with the new identity.
2. Generate matching development and Developer ID provisioning profiles. Update debug, CI and release entitlement/configuration files deliberately. Configure helper IDs independently; do not grant all helpers cloud access.
3. Create the required record types, fields, indexes and roles in the new container using the maintained CloudKit schema tooling under `scripts/cloudkit/`; test in development, then deploy the schema to production. Do not copy old user records, zone shares or invitations.
4. Change the explicit runtime container configuration, entitlement validation, share acceptance validation and scripts to the new ID. Run the existing production-schema and CloudKit availability checks against the new container.
5. Start each first-time Bark account with fresh account binding, zones, subscriptions, device registration and `CKSyncEngine` state. Never import `Sync/spaces.json`, server change tokens, share metadata, zone-owner references, deletion tombstones or old device identities from Nook.
6. Make cloud sync opt-in after onboarding. Before uploading, fetch the new container for an existing Bark dataset; a second install or device joins it rather than treating every launch as authority to wipe it. Bind setup state to the current iCloud account and handle sign-out/account changes explicitly.
7. Create new shares and invitations in Bark. Old Nook links get a specific explanation and request for a new invite. New owner/participant sharing is tested across two accounts before release.

Do not configure the old container as a default fallback, dual-write it, or silently read it when the new container is empty. Old Nook builds may continue using the old backend during retirement; make the separation visible. Retiring old sync is a later operational decision and does not require deleting the old container. This avoids both a cloud-copy migration and destructive cleanup merely to remove a name.

### 3. Local data policy: fresh start, no custom migrator

The accepted reset removes both cloud-copy work and the need for a custom local-data migrator. Bark onboarding explains that tabs, settings, site sessions, extension setup, cloud history and shares start fresh. A clean Bark install uses its new defaults/support domain and never triggers the existing unconditional legacy migrator. Gate/remove that path before `NookApp`/future `BarkApp` state creation.

Retain the existing manual `.nookspace` import for users who choose to export/import their spaces. Verify that this route does not restore old sync/account/sharing state or enable uploads automatically. Do not promise a new settings, credential, cookie, or extension importer.

Keep prior local files untouched; fresh state comes from a new namespace, not deleting another application's data. If a valid Bark setup already exists, do not reset it just because a Nook folder is present. Offer reconnection for credentials/providers without logging secrets. The future Chromium transition applies to the resulting Bark installation as a separate engine migration.

### 4. New identity integration and updater checks

The new ID affects UserDefaults, support/cache directories, Keychain access, TCC permissions, default-browser registration, Launch Services, URL/file handlers, native messaging/vendor allowlists, automation/MCP discovery and provisioning. Audit `AIKeychainStorage`, `BasicAuthCredentialStore`, `KagiSession`, the vault, and Bitwarden integration. Keep safe service names where needed; test actual access with the new signed identity, allow system prompts, and provide reconnect/re-authorize flows where needed. Do not claim the new App ID inherits old OS grants automatically.

Keep version numbers monotonically increasing and maintain the trusted Sparkle key. Rehearse Nook -> transition build -> Bark -> subsequent Bark with the actual pinned Sparkle version on both architectures. A changed bundle ID/name may require a transition installer or explicit handoff; do not assume a normal replacement works. If the direct updater path cannot safely support the new identity, deliver a signed transition build that offers a verified Bark installation path and explains fresh-start behavior. Do not broaden updater validation to accept arbitrary identities. Check duplicate app detection, old launch paths, relaunch, Dock/default-browser registration, interrupted install and data preservation.

The repository move can break the old feed endpoint even if code is correct. Coordinate with the independence plan and keep the old feed/release reachable through a tested bridge period. Rename provisioning-secret labels and runner allowlists in a controlled deployment; keep secret values out of documentation and commits.

### 5. Brand and logo work

Develop three original directions for selection: a simple abstract B; a compact geometric arch suggesting a browser window; and a distinct tab/sidebar motif. These are directions to explore, not a selected design or a request to imitate another browser. Choose one based on recognizability at small sizes, light/dark contrast, independence from the old Nook mark, and suitability for macOS icon rendering.

Deliver an editable vector master, app-icon source suitable for the existing `.icon` workflow, production and distinguishable development variants, monochrome logo, and PNG exports used by the app/README/install media. Review actual 16/32/64/128/256/512/1024-pixel outputs plus system light/dark/tinted rendering where supported. Do not add speculative marketing assets that have no destination. Record asset authorship/license.

Replace current logo references in both `.icon` bundles, asset catalogs, About/onboarding and repository assets; inspect built app icons and DMG background. Clear relevant local caches only when verifying, not through a product startup workaround. Keep third-party browser logos and historical attribution intact.

### 6. Rename sources in a separate mechanical slice

Change product/display names first. Then rename project, targets, schemes, entrypoint, local package/product/module names (`NookWeb` -> `BarkWeb`, `NookTabsCore` -> `BarkTabsCore`, and corresponding settings/UI/design/blocker/tweaks packages), imports, file references and script paths coherently. Keep each rename buildable. Do not combine package renames with runtime behavior edits.

Audit remaining `Nook`, `nook`, upstream URLs and historical bundle prefixes with a classified allowlist: attribution/license, legacy importer/file types, persisted keys and third-party identifiers may remain intentionally. Rewrite README around Bark: independent ownership, Intel and Apple Silicon support, build/signing instructions, optional feature availability, new releases/support paths, migration/reset notice and upstream acknowledgements. Avoid performance and extension claims until the Chromium plan proves them.

## Risks / Trade-offs

- Existing cloud data/shares are deliberately not transferred -> publish a clear reset notice and retain manual space-file import; users recreate invitations.
- A new installation accidentally resets existing Bark cloud data -> first fetch and account-aware onboarding; no cloud deletion in first-run logic.
- Old automatic migration seeds unwanted data -> gate/replace `LegacyDataMigration` before application initialization and cover existing-target cases.
- New App ID changes OS and credential access -> test with real signed identities and offer reconnection rather than copying protected stores blindly.
- Bundle-ID change breaks an ordinary updater path -> mandatory signed multi-hop rehearsal and a bounded transition installer/handoff if needed.
- Optional dependencies lack an Intel slice -> keep browser support native on both architectures; document optional feature availability.
- Mechanical rename conflicts with engine refactor -> finish it first or isolate it until contracts stabilize.

## Migration Plan

| Phase | Deliverable and exit check |
| --- | --- |
| B0: Identity provisioning | New App ID/container registered, required schema deployed, signed prototype launches and accesses only the new production container on both architectures |
| B1: Transition behavior | Fresh-start and existing space-file import, account lifecycle, old-invite rejection and new-share tests pass |
| B2: Visual identity | Selected original mark rendered in app/installer; Bark naming complete |
| B3: Mechanical rename and documentation | Project/packages/scripts build on Intel and Apple Silicon, README rewritten |
| B4: Distribution rehearsal | Old -> Bark -> next Bark verified, fresh install and existing Bark-account cases verified, reset notice included |
| B5: Release | Publish the identity/reset release separately before Chromium cutover, then collect limited-user feedback |

Rollback uses the previous signed app with its untouched local data and old cloud service. Bark data remains in the new container and is never pushed back into Nook automatically. Once users create new Bark records, a rollback notice must explain that the two datasets remain separate. The accepted reset is a transition to a new namespace, not an instruction to destroy the old namespace now.

Planning estimate: 1-3 engineer-weeks for identity/provisioning, fresh-start behavior, renaming and release rehearsals, plus logo selection and external provisioning/review time. Re-estimate if a complex updater installer is required. No custom user-data or CloudKit-record migration is budgeted.

Standalone planning publication keeps this change under `openspec/changes/`. When its implementation is published with the specs, sync requirements into current specs and archive the implemented change on the feature branch; track remaining production rollout/live verification in tickets. Do not commit one-off verification snapshots or logs.
