# Browser toolbar

## Purpose

People can keep the browser controls next to their tabs or above their page and continue working on the same document.

## ADDED Requirements

### Requirement: Toolbar placement is reversible from View

Bark SHALL offer the action that moves the toolbar to its other placement in the View menu.

#### Scenario: Move the controls above the page

- **GIVEN** a standard Chromium browser window with navigation and the address in the sidebar
- **WHEN** the user chooses Show Toolbar in View
- **THEN** back, forward, reload or stop, the current address and Site Controls appear together above the page
- **AND** their old sidebar positions are freed and View offers Hide Toolbar

#### Scenario: Return the controls using the shortcut

- **GIVEN** navigation is above the page and a document is selected
- **WHEN** the user presses the configured toolbar shortcut (initially ⇧⌘D)
- **THEN** navigation and the address return to the sidebar, the selected document stays open, and View offers Show Toolbar

### Requirement: The toolbar acts on the selected page

Bark SHALL keep page controls attached to the active page when their placement changes.

#### Scenario: Use Site Controls with the sidebar hidden

- **GIVEN** a page is selected and the top toolbar is visible
- **WHEN** the user hides the sidebar and opens Site Controls from the toolbar
- **THEN** the panel opens at its toolbar button and operates on the selected page

#### Scenario: Navigate the active split pane

- **GIVEN** a window with two pages in a split and the second pane selected
- **WHEN** the user moves the toolbar, focuses the address, and navigates
- **THEN** the second pane navigates and the first keeps its document

#### Scenario: Reach the address in an empty space

- **GIVEN** an empty space is selected with the toolbar above the page
- **WHEN** the user clicks the address field
- **THEN** the address editor receives the click above the empty-space view

### Requirement: The placement preference persists

Bark SHALL use the same saved toolbar placement in its standard browser windows.

#### Scenario: Restore the top placement

- **WHEN** the user chooses Show Toolbar, quits Bark, and reopens it
- **THEN** the toolbar appears above the page and View offers Hide Toolbar
