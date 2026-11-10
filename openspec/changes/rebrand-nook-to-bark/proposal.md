# Rename Nook to Bark

## Why

The independent app needs a clear identity: Bark, with an original logo. The repository's `TRADEMARK.md` explicitly asks modified distributions to use a different name and icon, and user-facing links still mix upstream Nook destinations with this fork's release infrastructure.

## What Changes

- Rename the installed product and its user-facing surfaces to Bark, including menus, onboarding, settings, permission descriptions, installers, updates, and documentation.
- Create and select an original Bark mark, then deliver production and development app icons, in-app assets, and repository artwork with small-size and appearance checks.
- Move public source, download, support, and release links to the chosen Bark destination; coordinate repository naming with the independent-distribution plan.
- Register a new Bark App ID and CloudKit container, with main bundle ID `ee.qdo.bark` and container `iCloud.ee.qdo.bark` under the existing developer team.
- **BREAKING:** Start Bark synchronization fresh. Existing cloud records, shares, invitations, and sync tokens are not migrated; the user accepted a reset because the current user base is small.
- Start with fresh local state and retain the existing manual space-file import as an optional recovery path. Do not build a custom automatic data migrator or automatically seed the new cloud container.
- Preserve update-signing trust and legacy file import compatibility, and explain any system permissions or integrations that require reconnection after the App ID change.
- Keep upstream attribution, copyright, and license notices while clearly identifying Bark as an independently maintained derivative.
- Update internal project and package names in an isolated mechanical phase after the visible identity and upgrade path work; retain compatibility keys deliberately.

## Capabilities

### New Capabilities

- `product-identity`: Consistent Bark naming, original visual assets, and clear ownership and attribution.
- `rebrand-continuity`: A clear transition to the new App ID, fresh local/cloud state, and verified update and legacy-file compatibility.

### Modified Capabilities

None: no durable specs existed before these two planning changes.

## Impact

Touches `App/`, onboarding, menus and settings, shared UI, `Nook/Info.plist`, Xcode products/schemes, `Nook/logo.icon`, `Nook/logo-dev.icon`, asset catalogs, `assets/`, README and project policies, and signing/DMG/release scripts. Audit persistence keys, bundle IDs, CloudKit identifiers, native messaging, MCP discovery, and file types before renaming any of them.

The user selected a new App ID and CloudKit container, then explicitly accepted a fresh start instead of cloud-data migration. The plan therefore replaces `ee.qdo.nook` and `iCloud.ee.qdo.nook` with the proposed Bark identifiers, regenerates provisioning, and resets synchronization state. Both Intel and Apple Silicon remain required; rewrite README accordingly. Logo style and final repository/domain names remain selection decisions; this plan creates no artwork and makes no external repository or cloud changes.

This change is independent of renderer implementation and should be tested and released separately from the Chromium migration. Rebrand shared surfaces consistently.
