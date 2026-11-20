## Why

People upgrading from Nook should keep using their existing update URL. Bark also inherits three user-facing problems from Nook, and keyboard zoom gives no indication of the resulting scale.

## What Changes

- Preserve other apps during transition onboarding and route each Mac from Nook to its native Bark feed.
- Keep visible pages during Clear, isolate chat tool grants and accept current URLhaus updates.
- Display the actual zoom percentage in the page receiving the keyboard shortcut.
- Maintain the Nook transition and the Chromium browser on separate release branches of the renamed repository.

## Capabilities

### New Capabilities

- `browser-maintenance` covers sidebar Clear, malware list refresh and chat tool approvals.
- `page-zoom-feedback` covers the feedback shown when changing zoom by keyboard.
- `nook-update-transition` covers onboarding and update continuity for installed Nook users.

### Modified Capabilities

None.

## Impact

Nook 1.5.5, Bark 2.0, the browser's page-command bridge, the release runner and Sparkle feed publication.
