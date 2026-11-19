# Select Pawl Vault as Bark’s credential provider

## Why

A user who enables Pawl Vault can still see a Chromium password prompt or receive a fill from Chromium’s saved passwords. The installed Pawl Vault build 7 recognizes the signed Nook client but refuses the signed Bark client even though both use the same developer team.

## What Changes

- Make the existing choice in Privacy settings authoritative for website passwords. Keep the current default and the user’s existing preference.
- Direct password management to the selected provider. Show an actionable connection status when Pawl needs an update or unlock.
- Reuse Bark’s native Chromium field, submission and WebAuthn integration. Preserve physical security keys and independently supported authenticators.
- Coordinate an exact signed-client compatibility change with Pawl Vault. Its database, authentication, origin checks and passkey keys remain under Pawl’s control.
- Qualify password updates, duplicate login names and private windows alongside existing fill and save flows.

## Capabilities

### New Capabilities

- `credential-provider-selection` determines which provider may offer, fill and store website credentials.

### Modified Capabilities

The open Chromium migration already specifies profile-bound Pawl operations. This change adds provider selection and supersedes the disconnected-provider fallback described in its design.

## Impact

Bark’s Privacy and Profile settings, its existing C engine bridge, Chromium password and passkey routing, and the separately shipped Pawl Vault macOS app. The design uses the existing vault connection and preserves stored passwords and legacy clients.
