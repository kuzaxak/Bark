# Browser runtime

## Purpose

Deliver Chromium-compatible browsing within the native browser interface while preserving page ownership, profile isolation, and reliable recovery.

## ADDED Requirements

### Requirement: Intel and Apple Silicon support
The macOS browser SHALL support native execution on both Intel and Apple Silicon computers.

#### Scenario: Qualify each architecture
- **WHEN** the release is installed on a supported Intel Mac and a supported Apple Silicon Mac
- **THEN** browsing, profile settings, extensions, and updates work on each architecture
- **AND** each independently passes the required compatibility and performance gates

#### Scenario: Optional feature lacks Intel support
- **WHEN** an optional on-device feature requires hardware or a dependency unavailable on Intel
- **THEN** its availability is explained in the UI
- **AND** the Intel browser still installs, launches, and supports the required browsing and extension features

### Requirement: Chromium web compatibility
The macOS browser SHALL complete the release qualification suite of website workflows using its Chromium runtime.

#### Scenario: Complete an authenticated web workflow
- **GIVEN** a qualifying site with an OAuth popup, file upload, and persistent session
- **WHEN** the user signs in, uploads a file, and relaunches the browser
- **THEN** the workflow completes and the session follows the site's persistence rules
- **AND** the popup preserves the initiating profile and opener relationship

### Requirement: Native navigation continuity
The browser SHALL preserve navigation and live page state when switching spaces or moving a tab between native windows.

#### Scenario: Switch profiles within one window
- **GIVEN** one browser window has Work and Personal spaces whose live pages contain unsaved drafts
- **WHEN** the user switches between those spaces and returns
- **THEN** the same window displays the selected space using its own profile's session and permissions
- **AND** returning to either page preserves its draft, scroll position and back history without reloading its document

#### Scenario: Transfer a live tab
- **GIVEN** a page with a filled form, scroll position, and back history
- **WHEN** the user moves it to another window
- **THEN** those states remain available without reloading the document
- **AND** the original window no longer hosts a second live copy of the page

#### Scenario: Use split views and Peek
- **WHEN** the user opens two pages in a split and a link in Peek
- **THEN** each surface navigates and receives focus independently
- **AND** promoting Peek to a tab preserves its profile and live page

### Requirement: Profile isolation
The browser SHALL isolate persistent website data and site permissions by profile.

#### Scenario: Shared and separate profiles
- **GIVEN** two spaces use profile A and another uses profile B
- **WHEN** a user signs in to a site in one space using A
- **THEN** the other space using A can use that session
- **AND** B receives neither the session nor A's permission grants

### Requirement: Private session disposal
The browser SHALL discard private-session browsing data when the private session ends.

#### Scenario: Close a private session
- **GIVEN** a private session visits a site, signs in, and grants a site permission
- **WHEN** all windows belonging to that private session close and a new private session begins
- **THEN** the new session has none of those cookies, history entries, or permission grants
- **AND** regular profiles contain none of the private session's browsing data

### Requirement: Page failure recovery
The browser SHALL allow recovery from a page-process failure without terminating unrelated browser windows.

#### Scenario: Renderer exits unexpectedly
- **WHEN** a page's renderer process terminates
- **THEN** affected pages expose a recoverable error and reload action
- **AND** tabs, spaces, and windows outside the failed process remain usable

### Requirement: Explicit site authorization
The browser SHALL enforce the initiating profile's permission decision before exposing a protected device or capability to a website.

#### Scenario: Camera permission denied
- **WHEN** a site requests the camera and the user denies access
- **THEN** capture does not begin
- **AND** a grant in another profile does not override the denial

#### Scenario: Untrusted certificate
- **WHEN** navigation encounters an untrusted certificate without an applicable user exception
- **THEN** the browser displays a warning before permitting access to the page

### Requirement: Measured release qualification
The Chromium release SHALL satisfy a documented compatibility and performance acceptance matrix measured against the supported WebKit release on matched hardware and workloads.

#### Scenario: Regression blocks promotion
- **GIVEN** the acceptance matrix and regression budgets were recorded before the candidate run
- **WHEN** a candidate fails a mandatory workflow or exceeds an accepted regression budget
- **THEN** it is not promoted to the default stable release
- **AND** the failure and any later approved change to the budget are recorded explicitly

### Requirement: Verifiable runtime version
The browser SHALL expose its shipped Chromium version in application diagnostics.

#### Scenario: Identify a vulnerable runtime
- **WHEN** a user or maintainer opens runtime diagnostics
- **THEN** the exact engine version and application build can be identified for security-update triage

### Requirement: Media playback and control continuity
The browser SHALL support the mandatory playback, streaming, media-control and capture workflows in its published media qualification matrix on both supported architectures.

#### Scenario: Control background media
- **GIVEN** a qualifying media page is playing in a background space
- **WHEN** the user invokes its mini-player, picture-in-picture or supported system media controls
- **THEN** the controls operate on that page and its profile
- **AND** changing spaces or moving its tab between windows does not interrupt playback

#### Scenario: Qualify a streaming format or service
- **WHEN** a release claims support for a format or protected streaming service
- **THEN** playback and seeking pass the corresponding installed-build tests on Intel and Apple Silicon
- **AND** required codec, acceleration and service availability is documented without inferring support solely from the Chromium version
