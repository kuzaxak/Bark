# Browser automation

## Purpose

Preserve existing AI browser tools and DevMCP behavior when their pages use Chromium, including authorization, document ownership and cancellation.

## ADDED Requirements

### Requirement: Authenticated live-source continuity
The browser SHALL read existing authenticated live-folder and favorite sources using the owning space's profile without creating a WebKit page.

#### Scenario: Refresh without an open website tab
- **GIVEN** two regular profiles have different logins for a supported live source and neither has an open tab for that source
- **WHEN** a folder or favorite in one profile's space refreshes
- **THEN** the result uses only that profile's login
- **AND** the refresh does not open or select a website tab

#### Scenario: The source redirects to sign-in
- **GIVEN** an authenticated live-source request redirects to sign-in or another destination
- **WHEN** the source refresh receives that response
- **THEN** it reports the existing signed-out or failed outcome without following the redirect
- **AND** it does not forward the profile's credentials to that destination

#### Scenario: Profile ownership changes during refresh
- **GIVEN** a live-source refresh is pending
- **WHEN** its owning profile is deleted, the space is reassigned, or the request is cancelled
- **THEN** a late result cannot update the replacement profile's folder or favorite
- **AND** the pending operation releases its native request state

#### Scenario: Public feeds remain unauthenticated
- **GIVEN** a live folder uses a public feed URL
- **WHEN** it refreshes while the profile is signed in to that host
- **THEN** the feed request carries no browsing-profile cookies

### Requirement: Automation feature continuity
The browser SHALL execute its existing permitted page-reading and script tools against the intended Chromium document with their existing script and result semantics.

#### Scenario: Read and interact with a Chromium page
- **GIVEN** an authorized caller targets a live website document with an unsaved form
- **WHEN** it uses the existing page-content, element and selected-text tools
- **THEN** the tools read or act on that document and preserve unrelated form state
- **AND** they do not create a WebKit page or reload the document to perform the operation

#### Scenario: Preserve script results and failures
- **GIVEN** an authorized caller evaluates a script in its requested page or isolated context
- **WHEN** the script returns a value, returns undefined, throws, or awaits an operation that rejects
- **THEN** the tool preserves the existing result or error behavior for that caller
- **AND** undefined, null and execution failures are not silently reported as the same successful result

#### Scenario: Read an existing document while resources are loading
- **GIVEN** the person's current displayed website document is available while some resources are still loading
- **WHEN** an authorized caller uses a fixed page-reading or element tool
- **THEN** the tool can operate on that current document without waiting for unrelated resources
- **AND** replacement of the document cancels the operation rather than redirecting it to the replacement

#### Scenario: Operate on the hidden Agent page
- **GIVEN** DevMCP targets its existing Agent page while another profile's page is displayed
- **WHEN** an authorized tool reads or evaluates the Agent document
- **THEN** it uses the Agent page's document and profile
- **AND** the Agent page remains hidden and the displayed page remains selected

### Requirement: Authenticated file-download continuity
The browser SHALL preserve the existing DevMCP download tool's bounded batch, file naming, manifest and no-overwrite behavior using the intended Agent profile without exporting its cookies or creating a WebKit page.

#### Scenario: Download using the owning profile
- **GIVEN** two regular profiles have different logins and an authorized caller targets one profile's Agent document
- **WHEN** the caller downloads a supported batch of URLs
- **THEN** requests use that document's profile, storage partition and applicable cookie and referrer rules
- **AND** redirects do not manually forward credentials belonging to another destination
- **AND** the operation leaves page selection unchanged and does not save response cookies

#### Scenario: Limit a large response while receiving it
- **GIVEN** a server sends a response larger than the tool's supported per-file limit
- **WHEN** the transfer reaches the limit
- **THEN** the browser stops that transfer, removes its partial file and records the existing too-large outcome
- **AND** it does not buffer the complete oversized response in memory before enforcing the limit

#### Scenario: Keep the existing asynchronous job contract
- **GIVEN** a download batch has been accepted and some transfers are still running when the tool returns its progress response
- **WHEN** the request completes normally
- **THEN** the accepted job continues to update its manifest and completion counts
- **AND** returning progress does not silently cancel the remaining URLs

#### Scenario: Cancel an obsolete download job
- **GIVEN** a download job has pending transfers or completed temporary files awaiting publication
- **WHEN** the job is explicitly cancelled, developer access stops, its profile is deleted, or its Agent document or owner is replaced
- **THEN** the browser cancels the job's remaining transfers and removes only its owned temporary files
- **AND** late completions cannot publish files or manifest results for a replacement owner

#### Scenario: Preserve existing destinations and the allowed directory
- **GIVEN** a destination already exists, another job wins the same destination, or the resolved directory has changed
- **WHEN** a completed temporary download is ready to be published
- **THEN** the browser revalidates the allowed destination and never overwrites an existing file
- **AND** it reports the existing-file or failure outcome without writing outside the configured files directory

### Requirement: Native page screenshots
The browser SHALL preserve the existing authorized screenshot tool's JPEG response and requested maximum width for Chromium pages without creating a WebKit page or changing page selection.

#### Scenario: Capture the intended page viewport
- **GIVEN** an authorized caller targets a Chromium page whose rendered viewport is available and capture is permitted by applicable browser policy
- **WHEN** it requests a screenshot with a supported maximum width
- **THEN** the image belongs to that page's document and preserves the viewport's aspect ratio within the requested width
- **AND** a lower-resolution tab thumbnail is not silently substituted

#### Scenario: Capture a hidden page without resuming rendering
- **GIVEN** the targeted Agent page is hidden while another page is displayed
- **WHEN** an authorized caller requests its screenshot
- **THEN** an available image of its last rendered viewport may be returned with that limitation identified to the caller
- **AND** the hidden page remains hidden, its background animation does not resume, and the displayed page remains selected
- **AND** if no suitable image is available, the caller receives an unavailable result rather than an image from another page

#### Scenario: Reject an obsolete or disallowed screenshot
- **GIVEN** a screenshot is pending
- **WHEN** its document or profile changes, its page closes or transfers ownership, the caller cancels, or applicable capture permission is withdrawn
- **THEN** the pending operation settles without publishing the obsolete image
- **AND** a late completion cannot fulfill a replacement request

#### Scenario: Reject unsupported screenshot dimensions
- **GIVEN** a screenshot request exceeds supported output bounds or has an invalid maximum width
- **WHEN** the browser handles the request
- **THEN** the caller receives an explicit refusal before the image is captured
- **AND** the browser does not silently change the requested dimensions or allocate an unbounded image

### Requirement: Script execution authority
The browser SHALL preserve the existing caller authorization and user-approval requirements when dispatching scripts to Chromium.

#### Scenario: Reject an unapproved AI script
- **GIVEN** the AI execute-JavaScript tool requires user approval
- **WHEN** approval is denied or no approval handler is available
- **THEN** no script is dispatched
- **AND** the caller receives a refusal

#### Scenario: Reject an unauthorized DevMCP request
- **GIVEN** a DevMCP request does not satisfy the existing access checks or developer access has been disabled
- **WHEN** the client requests page reading or script execution
- **THEN** no page operation is dispatched and no page is created for that request
- **AND** the request is rejected rather than queued for later execution

#### Scenario: Respect document script restrictions
- **GIVEN** the target document's applicable script policy or sandbox prohibits execution
- **WHEN** a tool requests evaluation, including in an isolated context
- **THEN** the tool refuses execution without weakening that policy

### Requirement: Automation document ownership
The browser SHALL keep an accepted automation operation bound to its original target document and profile until completion or cancellation.

#### Scenario: The target changes while approval is pending
- **GIVEN** an AI script is awaiting approval for a document
- **WHEN** approval completes and the current target no longer matches the captured selection, document or profile
- **THEN** the approved request does not execute on the replacement target
- **AND** the caller is told that the original request cannot proceed

#### Scenario: A pending script outlives its target
- **GIVEN** a script has not completed
- **WHEN** the request is cancelled or its document navigates, closes or changes ownership
- **THEN** the caller's pending operation settles once without publishing a late result into the replacement target
- **AND** the browser releases the operation's retained source and native completion state without waiting for a page promise to settle
- **AND** cancellation does not claim to undo JavaScript that already executed
