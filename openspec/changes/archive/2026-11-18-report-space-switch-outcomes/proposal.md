# Report the outcome of a space switch

## Why

A Bark window can contain two profiles with the same site open. Its selected space, keyboard commands and permission prompts must identify the same owner. In an r83 walk a location request from Work stayed visible over Personal. Chromium can also select a third client synchronously while handling a switch.

## What Changes

A request to switch spaces has one outcome for the affected window. The sidebar and page commands follow the space and page that actually won. A prompt exposed over a page identifies the document that owns it. A switch that selects an empty space leaves page commands unavailable.

## Capabilities

### New Capabilities

- `space-switch-ownership` covers selection, command targeting and outgoing prompt disposition when switching spaces in a shared window.

### Modified Capabilities

None.

## Impact

The Chromium host, versioned C bridge, Swift page host, tab model and command routing participate. The existing engine migration covers split composition, Peek and restoration. This proposal addresses the switch itself.
