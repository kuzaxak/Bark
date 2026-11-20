## Why

Build 124 can lose a renderer while displaying a public GitHub page. Someone who has lost their page or quit the app needs a way to reach the maintainers and describe what happened.

## What Changes

Expose a reporting action in Help and a public form reachable from another browser. Ask for details a person can provide after losing a tab. Record the observed renderer failure separately in Chromium 158 release qualification.

## Capabilities

### New Capabilities

- `problem-reporting` covers access to the public report form and control over submitted details.

### Modified Capabilities

None.

## Impact

Bark Help, the native menu, repository issue forms and user documentation.
