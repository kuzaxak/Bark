# Move the browser toolbar

## Why

People who hide Bark’s sidebar need another place to see the current address and use navigation. The existing appearance preference enables a page header, but the Chromium View menu gives people no way to discover or reverse the move there.

## What Changes

- Offer Show Toolbar or Hide Toolbar next to the sidebar command in View. Use the configured toolbar shortcut, initially ⇧⌘D.
- Move navigation, the current address and Site Controls together between the sidebar and the top of the page. Keep one set of controls for the selected page.
- Retain the saved placement when the sidebar closes, windows change, or Bark restarts.

## Capabilities

### New Capabilities

- `browser-toolbar` covers placement and operation of the navigation toolbar in Bark’s Chromium browser windows.

### Modified Capabilities

## Impact

The Swift app menu, shortcut routing and SwiftUI window chrome share Bark’s existing appearance setting. The Chromium engine and C bridge have no new API requirements.
