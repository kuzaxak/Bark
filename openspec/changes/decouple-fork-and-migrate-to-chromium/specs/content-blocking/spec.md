# Content blocking

## Purpose

Preserve the browser's configured filter lists and blocking exceptions when replacing WebKit, including coexistence with Chrome extensions and trustworthy blocking diagnostics.

## ADDED Requirements

### Requirement: Native request blocking
The Chromium browser SHALL apply the enabled native network-filter policy to eligible website requests before sending them to the network.

#### Scenario: Block subresources and redirected requests
- **GIVEN** an enabled filter list blocks an image and the destination of a script redirect
- **WHEN** a page or its child frame requests those resources
- **THEN** the blocked image and redirect destination receive no request
- **AND** unrelated resources remain available

#### Scenario: Apply policy to worker network traffic
- **GIVEN** an enabled filter blocks a network resource requested by a dedicated, shared or service worker
- **WHEN** the worker requests that resource without an applicable exception
- **THEN** the resource receives no request
- **AND** the decision uses that worker's actual profile, independently of the selected tab or window

#### Scenario: Block website WebSocket connections
- **GIVEN** an enabled filter blocks a WebSocket destination
- **WHEN** a page, dedicated worker, shared worker or service worker attempts a connection without an applicable exception
- **THEN** the destination receives no connection from that attempt
- **AND** unrelated WebSocket connections remain available
- **AND** regular and private profiles cannot borrow another tab's exception

#### Scenario: Cancel a pending WebSocket connection
- **GIVEN** a WebSocket connection is waiting for a blocking decision
- **WHEN** its initiating document is replaced, its profile shuts down or its connection is cancelled
- **THEN** completing the old decision does not start that connection
- **AND** a replacement document does not inherit its pending work or exception

#### Scenario: Restore policy before the first website request
- **GIVEN** saved settings enable an optional filter list and allowlist one site
- **WHEN** the browser starts and a page requests resources before filter preparation finishes
- **THEN** requests covered by that list remain blocked unless the saved exception applies
- **AND** startup does not temporarily send those requests without the configured policy

#### Scenario: A service worker wakes without a window
- **GIVEN** native blocking is enabled and a profile has a persisted website service worker but no open window
- **WHEN** that worker wakes and requests a blocked resource
- **THEN** the resource receives no request
- **AND** opening a window or selecting that profile is not required to apply its policy

#### Scenario: A private-menu navigation precedes filter readiness
- **GIVEN** native blocking is enabled and its filter preparation is pending
- **WHEN** a link is opened in a new private window
- **THEN** its first website requests are subject to the configured policy
- **AND** cancelling that pending navigation does not later load the captured destination

#### Scenario: A newer policy supersedes pending preparation
- **GIVEN** preparation of an enabled filter policy is pending
- **WHEN** the user disables native blocking before that preparation completes
- **THEN** subsequent requests follow the disabled policy
- **AND** pages waiting for that preparation can continue without waiting for the obsolete work to finish
- **AND** completion of the older preparation does not re-enable native blocking

#### Scenario: Re-enable after changing filter selections
- **GIVEN** blocking is disabled and the user changes the enabled filter lists
- **WHEN** the user re-enables blocking and opens a page while the changed rules are being prepared
- **THEN** the page's first requests use the changed filter selections
- **AND** previously prepared rules do not prematurely admit those requests

### Requirement: Blocking exception ownership
The browser SHALL apply native blocking exceptions only within their configured site or tab scope.

#### Scenario: Continue after a native navigation block
- **GIVEN** the native filter blocks a top-level navigation
- **WHEN** the browser presents the block and the user chooses its continue action
- **THEN** the browser retries the approved host with a native exception scoped to that tab
- **AND** extension filtering remains effective
- **AND** a later navigation to a different host does not inherit that exception

#### Scenario: Temporarily disable one tab
- **GIVEN** two tabs in the same profile visit the same site and native blocking is temporarily disabled for one tab
- **WHEN** each tab or its attributable child frame or dedicated worker requests a matching resource
- **THEN** the exempt tab's requests are allowed by the native blocker and the other tab's requests remain blocked
- **AND** expiration restores native blocking for subsequent requests from the exempt tab

#### Scenario: Shared worker has no single owning tab
- **GIVEN** a shared or service worker serves multiple tabs and one tab has a temporary exception
- **WHEN** the worker makes a request that cannot be attributed to one tab
- **THEN** the decision uses the worker's profile and applicable site policy
- **AND** it does not inherit an exception from whichever tab is selected

#### Scenario: Change selection during an exempt request
- **GIVEN** an eligible OAuth page has a native blocking exemption and another profile contains a nonexempt page
- **WHEN** focus changes to the other profile while the OAuth page follows a redirect
- **THEN** the exemption remains scoped to the initiating page
- **AND** neither profile receives the other's per-tab exemption or request diagnostics

#### Scenario: A replacement document cannot exempt an older request
- **GIVEN** a nonexempt page has a matching request whose filtering decision is delayed
- **WHEN** the same tab navigates to a different document with a blocking exception before that decision completes
- **THEN** the older request does not inherit the replacement document's exception
- **AND** completing the older decision does not change the replacement document's exception

### Requirement: Independent extension filtering
The browser SHALL preserve extension filtering decisions when native blocking is enabled, disabled or exempted.

#### Scenario: A native exception does not override an extension
- **GIVEN** a page is exempt from native blocking and an installed extension blocks one of its requests
- **WHEN** the page makes that request
- **THEN** the extension's block remains effective
- **AND** the native blocker does not report that request as its own block

#### Scenario: An extension redirect remains subject to native policy
- **GIVEN** an extension redirects a request to a resource blocked by the native filter policy
- **WHEN** the redirect is processed without an applicable native exception
- **THEN** the blocked destination receives no request
- **AND** request completion and error reporting occur once

### Requirement: Page protection parity
The browser SHALL apply supported cosmetic rules and scriptlets according to the configured filter sources and their trust permissions.

#### Scenario: A scriptlet must precede page scripts
- **GIVEN** an enabled and permitted scriptlet changes an API used by a website's first inline script
- **WHEN** the document loads
- **THEN** that first script observes the configured scriptlet behavior
- **AND** the browser does not substitute injection after the page script has already executed

#### Scenario: Apply frame-specific cosmetic rules
- **GIVEN** a page contains a cross-origin frame with different applicable cosmetic rules
- **WHEN** both documents load
- **THEN** each document receives the rules applicable to its own URL and the page's blocking exceptions
- **AND** navigation or removal of the frame prevents a delayed result from modifying its replacement

#### Scenario: Preserve scriptlet trust boundaries
- **GIVEN** a filter source lacks permission to use a trusted scriptlet
- **WHEN** that source requests the scriptlet and page content attempts to invoke the native configuration channel
- **THEN** neither action obtains the trusted behavior or native privileges
- **AND** permitted rules continue to operate without exposing privileged native methods to page scripts

#### Scenario: Preserve eligible history documents under unchanged protection
- **GIVEN** a page with cosmetic rules and scriptlets is otherwise eligible for live back/forward restoration
- **WHEN** the user leaves and returns without a material change to that page's protection policy
- **THEN** cosmetic filtering alone does not prevent live restoration of its form and JavaScript state
- **AND** publishing equivalent protection settings does not invalidate that document

#### Scenario: Do not restore obsolete protection from history
- **GIVEN** a retained history document used cosmetic rules or scriptlets
- **WHEN** a material change makes that document's protection policy obsolete and the user returns to it
- **THEN** the browser does not restore the obsolete protected runtime
- **AND** history documents whose effective protection policy is unchanged remain eligible for live restoration

### Requirement: Live page customization
The browser SHALL preserve Boost preview, save, cancel and element-picking behavior for Chromium pages without creating another page or changing the user's selection.

#### Scenario: Preview and cancel a draft
- **GIVEN** a page has saved Boost settings and its editor is open
- **WHEN** the user changes the draft and then cancels
- **THEN** the preview affects only the editor's page and does not persist the draft
- **AND** the page returns to the latest saved settings even if an older preview result arrives later

#### Scenario: Replace a pending editor
- **GIVEN** a preview result is pending when the page navigates or a newer editor replaces it
- **WHEN** the older editor closes or its result arrives
- **THEN** it does not change the replacement document or the newer editor's preview
- **AND** closing the editor releases its retained page and pending work

#### Scenario: Pick an element
- **GIVEN** an eligible page's Boost editor is open
- **WHEN** the user starts element picking and chooses an element
- **THEN** the editor receives a selector for that element in the initiating document
- **AND** the picker does not navigate the page or expose native privileges to its scripts

#### Scenario: Cancel a picker across page lifecycle changes
- **GIVEN** an element picker is active
- **WHEN** the user cancels, selects another page, closes the editor, or its page is hidden, navigated, transferred or closed
- **THEN** the picker removes its highlight, cursor changes and input interception
- **AND** returning through history does not restore the cancelled picker
- **AND** an older result cannot modify a replacement document or a newer picking session
