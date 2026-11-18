# Space switch ownership

## Purpose

People switching spaces in a shared Bark window can identify the profile and page that receive their next command or permission decision.

## ADDED Requirements

### Requirement: A space switch identifies its final destination

Each request SHALL produce one outcome identifying the invoking window, whether the requested selection took effect, and the resulting selected client and focused pane or empty space. If that window closes before completion, the outcome SHALL identify its closure.

#### Scenario: A later selection wins during a switch

- **WHEN** Work requests Home and the same window selects Research while processing that request
- **THEN** the outcome identifies Research and its focused pane and marks the Home request as superseded
- **AND** the sidebar identifies Research and the next page command reaches its focused pane

#### Scenario: A modal interaction blocks a switch

- **WHEN** a window's active modal interaction refuses a switch
- **THEN** the outcome identifies the refusal and the retained selection
- **AND** the window continues to route commands to that selection subject to the modal interaction

#### Scenario: The selected space has no page

- **WHEN** a user switches into an empty space
- **THEN** the sidebar selects that space and page-specific commands are unavailable

#### Scenario: Closing the invoking window

- **WHEN** the invoking window closes during a switch and a second window remains open
- **THEN** the request completes as closed and leaves the second window's selection and command routing intact

### Requirement: Outgoing prompts stay with their documents

The outcome SHALL identify what happened to each affected outgoing prompt. A user SHALL only be able to answer a document's permission prompt in the context of that document.

#### Scenario: Parking a location request

- **WHEN** a Work page requests location and the user switches to Personal, which displays the same site under another profile
- **THEN** Work's prompt is hidden and reported as pending for its originating document
- **AND** returning to that document exposes the pending request and delivers the user's decision there

#### Scenario: The original document goes away

- **WHEN** the requesting document closes while its prompt is hidden
- **THEN** the prompt is retired and cannot be shown or answered on its replacement
