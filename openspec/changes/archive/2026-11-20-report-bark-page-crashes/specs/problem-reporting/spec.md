## Purpose

People can report a problem after losing a page and decide which information to share publicly.

## ADDED Requirements

### Requirement: A renderer failure leaves a reporting route available

Bark SHALL offer a Help action that opens a user-editable issue form independently of the current page. The form SHALL also be reachable from another browser after Bark quits.

#### Scenario: Request help after a tab crashes

- **WHEN** the user chooses Report a Problem after a page crashes or with all browser windows closed
- **THEN** the issue chooser opens and the user can describe what happened before submitting

#### Scenario: File a report from an older release

- **WHEN** the user follows the repository’s reporting link in another browser
- **THEN** they can report that a single tab or the whole app quit, along with the version, steps and approximate time

### Requirement: The reporter chooses what to share

Opening the form SHALL leave the current address, browsing data and crash dump on the user's Mac.

#### Scenario: Report while visiting a private address

- **WHEN** the user opens the form from a page with a private address or query string
- **THEN** the form opens with blank report fields and the user chooses what to submit
