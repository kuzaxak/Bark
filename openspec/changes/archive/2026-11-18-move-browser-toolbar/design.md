# Toolbar placement

## Context

Bark’s sidebar and page header already read the saved `topBarAddressView` setting. The hosted page reserves height for an AppKit-mounted SwiftUI header. Site Controls uses the button’s window-space geometry. All three depend on which controls are currently mounted.

## Goals / Non-Goals

The browser window should have one primary address and one set of navigation actions. Users can keep them visible when the sidebar is hidden. This change covers the toolbar row represented in the supplied View menu. The remaining menu groups and Chromium’s upstream toolbar have separate owners.

## Decisions

- Use the existing appearance preference, including its persisted value and default sidebar placement. Apply the choice across standard windows.
- Put Show Toolbar / Hide Toolbar immediately below the sidebar command. Read the label and key equivalent from current settings. Keep the stable shortcut identifier for existing custom bindings.
- Use the existing native page header and sidebar layout. Reserve header height once above the page or split. Use the existing active-page lookup for navigation, the address editor, and Site Controls.
- Keep site-specific developer tools available in their existing context. Suppress browser chrome in web-content fullscreen. Keep independent sidebar access in both placements.

## Risks / Trade-offs

A SwiftUI control can outlive its visible anchor while the header moves. Exercise address editing and Site Controls after moving and after hiding the sidebar. Verify the clean signed app to catch stale native headers, duplicate controls, and shortcuts that dispatch twice.
