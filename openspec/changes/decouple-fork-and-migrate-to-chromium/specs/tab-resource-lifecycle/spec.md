# Tab resource lifecycle

## Purpose

Keep browsing responsive as tab counts grow while limiting background CPU and memory without interrupting active media, capture, or unsaved work.

## ADDED Requirements

### Requirement: User-configurable resource policy
The browser SHALL provide persistent user controls for optional tab-resource optimizations and apply changes to eligible tabs without restarting the application.

#### Scenario: Adjust background resource use
- **WHEN** the user changes the available background-tab residency, idle-suspension or warming controls
- **THEN** the selected policy applies to subsequent lifecycle decisions and survives relaunch
- **AND** media, capture and user-work protection remains enforced

#### Scenario: Turn off optional aggressive optimization
- **WHEN** the user disables an optional proactive suspension, discarding or warming optimization
- **THEN** the corresponding optional action stops
- **AND** ordinary visibility handling still suspends hidden-page animation and restores it when the page becomes visible

### Requirement: Hidden-page animation suspension
The browser SHALL suspend animation-frame callbacks for a tab whose document has no visible browser surface.

#### Scenario: Hide an animating document
- **GIVEN** a visible document continuously requests animation frames
- **WHEN** another tab is selected and the original document is no longer displayed
- **THEN** the original document reports hidden visibility
- **AND** its animation-frame callbacks stop after the visibility transition settles
- **AND** this does not require freezing or discarding the page

#### Scenario: Select the live hidden document again
- **GIVEN** a hidden live document contains an edited draft
- **WHEN** the user selects it again
- **THEN** it reports visible visibility and animation-frame callbacks resume
- **AND** its draft remains intact without a document reload

#### Scenario: Navigate while hidden
- **GIVEN** a background tab is not displayed in any browser surface
- **WHEN** its document loads or reloads
- **THEN** the new document remains hidden and does not begin a continuing animation-frame loop

#### Scenario: Page remains visible in another window
- **GIVEN** a tab's live document is displayed in another window or split pane
- **WHEN** the user selects a different tab in the current window
- **THEN** the still-displayed document remains visible and its animation-frame callbacks continue

### Requirement: Lazy session restoration
The browser SHALL restore saved tab metadata without creating a live page for every saved tab.

#### Scenario: Restore a large session
- **GIVEN** a saved session contains many tabs across several spaces
- **WHEN** the browser starts
- **THEN** selected visible pages load first
- **AND** other pages remain unloaded unless explicitly selected or admitted by the configured warm-tab budget

### Requirement: Media and capture protection
Automatic resource management SHALL preserve pages with active audible playback, picture-in-picture, camera or microphone capture, screen sharing, or a user-selected media control surface.

#### Scenario: Silent screen-sharing call
- **GIVEN** a background call is screen-sharing while its microphone is muted and no audio is audible
- **WHEN** memory pressure triggers tab eviction
- **THEN** the call remains active and the shared stream is not frozen or discarded

#### Scenario: Media continues while other tabs are released
- **GIVEN** a background tab is playing music or presenting picture-in-picture
- **WHEN** unrelated idle tabs are discarded to recover memory
- **THEN** playback and the associated controls remain functional

### Requirement: User work protection
Automatic tab discarding SHALL protect pages with detected unsaved work or an in-progress operation that would be lost on reload.

#### Scenario: Unsaved form or active transfer
- **GIVEN** an inactive page contains an edited unsaved form or an active upload
- **WHEN** a background resource budget is enforced
- **THEN** that page is not automatically discarded while the protected state remains
- **AND** the browser does not represent unknown protection state as confirmed safe

### Requirement: Consistent bulk protection
Bulk hidden-tab resource actions SHALL apply the same media, capture, and user-work protections as automatic resource actions.

#### Scenario: Bulk sleep with an active call
- **WHEN** the user chooses to sleep hidden tabs while one is capturing a microphone or screen
- **THEN** the capturing tab remains active
- **AND** the result identifies protected tabs that were retained

### Requirement: Explicit residency preference
The browser SHALL let users keep a selected tab or site active independently of whether its tab is pinned or favorited.

#### Scenario: Pinned but idle page
- **GIVEN** a pinned page has no protected activity and no keep-active preference
- **WHEN** the configured lifecycle policy discards it
- **THEN** its pinned position and identity remain unchanged
- **AND** selecting it restores its saved navigation state to the supported extent

### Requirement: Bounded background resource policy
The browser SHALL apply its configured background resource policy to eligible pages while reporting when protected pages prevent reaching the target.

#### Scenario: Inactive spaces retain their last selected tabs
- **GIVEN** inactive spaces retain eligible pages that are not displayed in any browser surface and exceed the configured background residency target
- **WHEN** the policy evaluates those pages
- **THEN** being the last selected tab in an inactive space does not alone exempt a page from the background policy
- **AND** pages still displayed in another window, split pane or Peek remain protected

#### Scenario: Protected workload exceeds the budget
- **GIVEN** active calls and visible pages already exceed the configured resource target
- **WHEN** the policy evaluates background tabs
- **THEN** it does not terminate protected work to claim success
- **AND** it reports that protected activity prevents satisfying the target

### Requirement: Responsive tab reactivation
The browser SHALL prioritize a selected sleeping tab's restoration over speculative background warming.

#### Scenario: Select a discarded tab
- **WHEN** the user selects a discarded tab while background warming is queued
- **THEN** the selected tab restores first with visible loading state
- **AND** it retains its tab identity, profile, and supported navigation state

#### Scenario: Return to a space whose selected page was discarded
- **GIVEN** an inactive space's last selected page has been discarded
- **WHEN** the user returns to that space without selecting a different tab
- **THEN** the page begins restoration with visible loading state
- **AND** restoration does not require another tab click
- **AND** the page retains its tab identity, profile, and supported navigation state

### Requirement: Observable lifecycle decisions
The browser SHALL expose a tab's resource state and reason for retention or suspension in diagnostics without recording browsing content.

#### Scenario: Diagnose retained background memory
- **WHEN** a user inspects a background tab's resource diagnostics
- **THEN** they can distinguish unloaded, live, suspended, and protected states supported by that runtime
- **AND** a protected tab identifies the activity or preference preventing eviction

### Requirement: Measured media-aware optimization
A lifecycle-policy release SHALL demonstrate resource savings and restoration responsiveness without regressing the required media-continuity cases on Intel and Apple Silicon.

#### Scenario: Qualify an optimized policy
- **GIVEN** a fixed mixed workload of idle documents, media and capture sessions
- **WHEN** the candidate is compared with the baseline policy
- **THEN** aggregate process memory, idle CPU, restoration latency and playback/capture continuity are reported together
- **AND** a resource saving that breaks a required protected workflow does not qualify as a passing optimization
