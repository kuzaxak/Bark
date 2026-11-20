## ADDED Requirements

### Requirement: Clear preserves pages in use

Clearing loose tabs in a space SHALL retain the complete trails containing a selected tab or a visible split pane in any window sharing that tree. Other loose tabs and their trails SHALL be cleared. Bookmarks and private windows retain their own contents.

#### Scenario: A second window is using a nested page

- **GIVEN** two regular windows share a space, the first displays a split, the second displays a child of a loose tab, and another loose tab is unused
- **WHEN** the user clears that space
- **THEN** each visible pane, the child's trail and their selections remain available, and the unused tab is removed

### Requirement: Conversation approvals belong to the selected tool provider

A grant for the rest of a conversation SHALL apply only to the approved provider and expire when the chat is cleared.

#### Scenario: Two servers and the browser offer tools

- **GIVEN** two external servers and browser tools are configured to ask for approval
- **WHEN** the user grants one server approval for this chat
- **THEN** further calls to that server may proceed, and calls requiring approval from the second server or the browser still prompt

### Requirement: Malware list updates accept the current feed size

Bark SHALL accept an otherwise valid URLhaus list between 10,000 and 30,000,000 bytes inclusive and retain the existing validation on other lists.

#### Scenario: A valid list grows

- **WHEN** an otherwise valid 12 MB online malware list is downloaded
- **THEN** its size passes the URLhaus download check

#### Scenario: An oversized list arrives

- **WHEN** the URLhaus download exceeds 30,000,000 bytes
- **THEN** the size check rejects it
