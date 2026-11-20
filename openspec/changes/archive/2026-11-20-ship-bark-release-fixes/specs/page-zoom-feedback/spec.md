## ADDED Requirements

### Requirement: Keyboard zoom reports the active page percentage

Bark SHALL display the confirmed percentage on the focused page after zoom in, zoom out or reset by keyboard, including when the page is already at the requested limit. Feedback SHALL preserve keyboard focus and page clicks, expire automatically, and be available to VoiceOver.

#### Scenario: Repeated keyboard zoom in a split

- **GIVEN** the sidebar is hidden and the user is editing in a split pane
- **WHEN** the user increases zoom twice, decreases it once and resets
- **THEN** a single indicator in that pane reflects each resulting zoom level, and typing continues in the same field

#### Scenario: Zoom in Peek

- **GIVEN** a Peek is focused
- **WHEN** the user presses a zoom shortcut
- **THEN** the percentage belongs to the Peek and the indicator disappears when its window loses focus
