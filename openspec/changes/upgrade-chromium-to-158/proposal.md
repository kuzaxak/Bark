# Upgrade Bark to Chromium 158

## Why

Signed Bark build 123 uses Chromium 156.0.8078.80. Chromium 158 is now the generally released desktop Stable milestone. Bark needs the upstream fixes and a repeatable way to find incompatible patches before starting a full engine build.

## What Changes

- Port Bark’s engine recipe and browser integration to Chromium 158.0.8127.37 on Intel and Apple Silicon.
- Make the patch rehearsal runnable from a clean Bark checkout against a specified Chromium commit. Document how to select Stable, review conflicts, verify build inputs, resume a build and qualify each architecture.
- Exercise the host-only launcher, profile and permission ownership, Web Store consent and password provider on the new candidate before replacing a signed build.

## Capabilities

### New Capabilities

- `chromium-engine-upgrades` covers rehearsing a Bark patch stack against an upstream revision and determining which architecture-specific candidates have passed qualification.

### Modified Capabilities

## Impact

The change affects the Chromium recipe, compiled bridge and engine tests, per-architecture SDK production, and contributor instructions. Build 123 remains available for normal browsing and comparison. The work is tracked independently on `codex/bark-chromium-158`.
