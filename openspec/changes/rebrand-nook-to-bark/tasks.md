# Implementation tasks

The user accepted fresh local/cloud state under a new Bark App ID and CloudKit container. Do not implement old-cloud record migration, share migration, a custom local-data importer, or deletion of old data. The Chromium shell uses the new sync identity.

## 1. Identity and provisioning (B0)

- [ ] 1.1 Confirm registration of the `ee.qdo.bark` bundle ID and the `iCloud.ee.qdo.bark` container, developer-team access and existing App Store records; deliver an identity map identifying any required new store record instead of an invalid in-place ID change.
- [x] 1.2 Register the new explicit App ID and container with required CloudKit/push capabilities; verify their association in the developer account without attaching the old container as a fallback. The issued Developer ID profile contains the Bark container and production push.
- [ ] 1.3 Generate new development/release provisioning and update the intended target IDs/entitlements; verify the signed app and issued profile agree on application prefix, bundle ID, cloud container and environment.
- [ ] 1.4 Update `scripts/sign-app.sh`, configuration and provisioning-secret references; run signing validation for native Intel and Apple Silicon builds and document the new setup without secret values.

## 2. Fresh CloudKit service (B0-B1)

- [x] 2.1 Configure maintained schema tooling for the new container; verify development record types, fields, indexes and roles match the sync implementation.
- [x] 2.2 Deploy the schema to the new production container; run the production-schema checks and verify no old-container user records were copied. The production export matched the development export after deploying only the schema.
- [x] 2.3 Update `SpaceSyncAvailability`, runtime container selection and entitlement checks; add tests that accept the new identity and reject old-container fallback.
- [x] 2.4 Initialize fresh zones, subscriptions, account binding and sync state; test that old `Sync/spaces.json`, tokens, shares and device metadata are never loaded.
- [ ] 2.5 Handle first versus subsequent Bark devices and account changes; test that joining an existing Bark account fetches its records without wiping or duplicating the dataset.
- [ ] 2.6 Update sharing validation and invitation UX; test old-link rejection plus new owner/participant invitations across two accounts using the new container.
  Two signed Macs on distinct iCloud accounts reached Bark production. The owner resolved the ARM Mac's invitation code and saved encrypted Space and Item fixtures. Saving the invite-only zone share failed because production lacks the system record type `cloudkit.share`. The owner deleted the fixture zone. Development seeding, production deployment and the full participant edit round trip remain open.
- [x] 2.7 Document the reset and old/new-client separation in onboarding and release notes; verify sync remains opt-in and the notice precedes enabling it. Signed Intel Bark displayed the notice during resumed first-run setup. Completing setup locally and reopening preserved the same space without creating a sync store. The user guide, Spaces settings and unreleased changelog also describe the separate datasets.

## 3. Local fresh start and integrations (B1)

- [ ] 3.1 Disable the unconditional legacy migration path for the Bark identity before app state initializes; test first launch with old Nook folders/defaults present.
- [ ] 3.2 Use the new local defaults/support domain and an idempotent setup marker; verify fresh launch, interrupted setup, relaunch and updates never overwrite an existing Bark setup.
- [x] 3.3 Retain manual `.nookspace` import; run existing import checks and verify it cannot restore old cloud/account/sharing state or silently enable uploads. Signed Intel Bark imported a legacy file through Settings into the chosen profile with fresh space, folder and tab IDs. The local import ignored old account, share and sync fields and preserved the original files and selected space. The Finder routing check and 21 model tests passed.
- [ ] 3.4 Audit credential/provider and native messaging identities; verify new signed-app behavior and provide reconnect guidance wherever previous access is unavailable.
- [ ] 3.5 Update URL/file associations, default-browser handling and MCP discovery; verify external links, legacy file open and a documented automation client connection.
- [ ] 3.6 Rehearse cancellation/recovery with old local data present; verify old files remain recoverable and no startup cleanup deletes them.

## 4. Logo and visible identity (B2)

- [ ] 4.1 Prepare three original logo directions with small-size previews; obtain a selected direction and record the asset ownership/license.
- [ ] 4.2 Produce the editable master, production/development app icons, monochrome mark and required raster exports; visually verify small sizes and supported system appearances.
- [ ] 4.3 Replace `.icon` bundle and asset-catalog references plus About/onboarding/repository artwork; inspect icons in built Finder/Dock/app/DMG surfaces.
- [ ] 4.4 Rename visible product strings, menus, plist descriptions and installer/update labels to Bark; review a fresh installation and permission prompts on both architectures. On Intel, signed Bark displayed its local Help, About credits and embedded Settings page. All 228 installed locale packs matched the generated browser strings.

## 5. Mechanical rename and documentation (B3)

- [ ] 5.1 Rename app/project/targets/schemes/entrypoint and update resource paths; verify the documented Xcode build succeeds for Intel and Apple Silicon.
- [ ] 5.2 Rename core/settings/design package products and imports in a coherent slice; run their existing package checks and app builds.
- [ ] 5.3 Rename web/UI/blocker/tweaks package products and imports in a coherent slice; run their existing checks and both architecture builds without changing runtime behavior.
- [ ] 5.4 Update build, signing, DMG, CI and release path references and runner allowlists; verify a staged release pipeline reaches packaging with Bark names.
- [x] 5.5 Rewrite README, contribution/support destinations and trademark/attribution presentation for Bark; verify Intel/Apple Silicon documentation and all public links while retaining upstream license/authorship.
- [ ] 5.6 Audit remaining Nook names and old identifiers against an explicit compatibility/attribution allowlist; verify no unexplained old product branding or active old cloud configuration remains.

## 6. Signed transition and release rehearsal (B4)

- [ ] 6.1 Prepare feed and version continuity with the existing Sparkle trust key; verify the old feed remains reachable through the repository transition.
- [ ] 6.2 Test bundle-ID/product-name replacement using the pinned updater; verify a signed Nook-to-Bark transition on both architectures, implementing a signed transition handoff if ordinary replacement cannot safely work.
- [ ] 6.3 Test Bark-to-next-Bark updates plus interrupted installation/relaunch; verify existing Bark data survives, the correct architecture is selected and the prior app/data remain recoverable on failure.
- [ ] 6.4 Qualify fresh install, existing Nook install, existing Bark account on a second device, signed-out account and new sharing flows; record concise results against the specs.
- [ ] 6.5 Prepare the final reset notice, reconnect instructions, release assets and rollback runbook; verify a reviewer can follow them without assuming old cloud/sharing continuity.

## Workflow follow-up

- Publish standalone planning artifacts under this change directory when requested; keep Apple-issued profiles outside the repository.
- Synchronize current specs and archive the implemented change on the feature branch before publishing/updating the solution PR; use scoped changes if slices ship independently.
- Coordinate repository rename/detachment with the independence workstream after its transition preparation is reviewable.
- Track production merge, release, rollout and live sync/update verification in tickets. Ship the identity/reset release before the Chromium cutover.
- Retire old endpoints only through a separate concrete operational decision. A fresh Bark container does not require deleting old cloud or local data.
