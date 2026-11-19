# Browser runtime

## Purpose

Deliver Chromium-compatible browsing within the native browser interface while preserving page ownership, profile isolation, and reliable recovery.

## ADDED Requirements

### Requirement: Bark owns macOS browser windows
Every macOS browser window created by the application, its engine, or its browser tests SHALL use the Bark interface.

#### Scenario: Create a window outside the sidebar
- **WHEN** a page, extension, keyboard command or browser test creates a browser window
- **THEN** Bark presents it with the initiating profile, private session and opener as applicable
- **AND** a window that Bark cannot present never displays Chromium's original browser controls

#### Scenario: Launch an incompatible development build
- **WHEN** a user supplies a retired window mode or a maintained test runner receives an engine that can create the original Chromium browser interface
- **THEN** the launch fails before a browser window appears

#### Scenario: Open an SDK build product
- **WHEN** someone opens the standalone SDK build product from Finder or the command line
- **THEN** the process exits without opening a browser window
- **AND** the product declares no URL or document handlers to macOS

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
The browser SHALL preserve navigation and live page state when switching spaces, composing split and Peek surfaces, or moving a tab between native windows.

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
- **AND** promoting Peek to a tab or split preserves its profile, opener and live document without reloading

#### Scenario: Stack a split vertically
- **GIVEN** a window showing two to four panes from the same profile, or from different regular profiles, or from one private session
- **WHEN** the user switches the split between side-by-side and top-to-bottom and resizes a divider
- **THEN** every pane keeps its own live page, form input and scroll position without reloading
- **AND** each pane fills the size the layout gives it

#### Scenario: Open Peek over a split
- **GIVEN** a window showing a split in either orientation
- **WHEN** the user opens a link from one pane in Peek
- **THEN** Peek appears above the whole split, bound to that pane's profile, while the panes beneath stay live and keep their layout
- **AND** dismissing Peek returns keyboard focus to that pane

#### Scenario: Compose regular profiles in a split
- **GIVEN** four live tabs alternate between Work and Personal profiles and contain different unsaved drafts
- **WHEN** the user arranges them in a split, changes its orientation and size, and focuses each pane
- **THEN** all four panes retain their documents, drafts and original profile sessions
- **AND** focusing a pane leaves the other displayed panes visible
- **AND** permission prompts and extension commands use the initiating pane's profile

#### Scenario: Preserve protection on an unfocused pane
- **GIVEN** a displayed split pane has a screenshot restriction
- **WHEN** the user focuses another profile's pane or opens Peek over it
- **THEN** the restricted pane's capture protection remains enforced for as long as it is displayed

#### Scenario: Supersede a pending split restoration
- **GIVEN** a saved window is preparing its split and the user selects another tab before preparation finishes
- **WHEN** the older restoration fails or finishes later
- **THEN** the newer selection and its live document remain intact
- **AND** the older request does not close the window or replace the newer layout

### Requirement: Site icons identify the live page

Bark SHALL display each live tab's current site icon in tab rows and matching open-tab search results.

#### Scenario: Two profiles open the same URL

- **GIVEN** Work and Personal each have the same URL open, and their pages supply red and blue icons respectively
- **WHEN** the user searches for the tabs and then the Work page changes its icon to green
- **THEN** the Work tab and its search result show green and the Personal tab and its result still show blue

#### Scenario: Navigate to a page without a site icon

- **GIVEN** a live tab shows its site's icon
- **WHEN** it finishes navigating to a page without a site icon
- **THEN** its tab row shows the generic page icon

### Requirement: Native navigation controls
The browser SHALL provide working address editing, command-palette actions and back/forward history menus in the Chromium window, preserving the requested page and profile.

#### Scenario: Edit an address in either placement
- **GIVEN** the address control is in the sidebar or the optional top bar
- **WHEN** the user opens it by click or focus-address shortcut
- **THEN** its field and suggestions remain visible and interactive within the owning window
- **AND** submitting navigates the page being edited, including Peek, without targeting another selected page after a selection change
- **AND** input-method composition is not treated as a submitted address

#### Scenario: Submit an internal address
- **WHEN** the user submits `chrome://version` or `about:blank` in the address control or command palette
- **THEN** that page opens
- **AND** the text is not sent to the search provider

#### Scenario: Search in a new tab from the command palette
- **GIVEN** the destination space's profile has a default search provider
- **WHEN** the user submits text that is not an address to open in a new tab
- **THEN** the new tab shows that provider's results, and the provider receives the query once
- **AND** the tab does not remain on a blank page

#### Scenario: Use and dismiss the command palette
- **WHEN** the user opens the command palette to create a tab or fill an empty split pane
- **THEN** typing, suggestion selection and submission operate in that window and complete the requested action
- **AND** Escape or an outside click dismisses it without leaving an invisible input surface
- **AND** resizing or closing the window does not leave an orphaned panel

#### Scenario: Select a history entry after intervening navigation
- **GIVEN** the history menu contains multiple visits to the same URL
- **WHEN** the same page navigates again before the user chooses an entry that remains in its history
- **THEN** the chosen visit is restored rather than a different visit occupying its former position

#### Scenario: Reject a stale history choice
- **GIVEN** a history menu is open
- **WHEN** its page or profile is replaced, its window closes, or the chosen visit is removed before selection
- **THEN** selecting the old entry does not navigate another page or a different visit

### Requirement: Spaces without a live page
A Chromium window SHALL show any space the person selects, including one with no tabs, and SHALL keep showing it when its last tab closes, without displaying another profile's page there.

#### Scenario: Enter a new space
- **WHEN** the person creates or selects a space with no tabs
- **THEN** the window shows that space with its empty page area
- **AND** no page of any other space remains visible or receives typing
- **AND** a tab opened from there loads in that space's profile

#### Scenario: Close a space's last tab
- **GIVEN** another space keeps a live page
- **WHEN** the person closes the last tab of the current space
- **THEN** the window stays on the current space, now empty

#### Scenario: Close a selected tab with another space retained
- **GIVEN** another space keeps a live page and the current space has more tabs
- **WHEN** the person closes the selected tab
- **THEN** the window stays on the current space and selects its next tab

### Requirement: Moving a tab between profiles
A tab moved to a space with another profile SHALL close its page in the old profile before it moves, and SHALL load in the new profile when next selected.

#### Scenario: Move a loaded tab to another profile's space
- **WHEN** the person moves a loaded tab to a space that uses another profile
- **THEN** the tab appears in that space and the window stays on its current space
- **AND** the page loads with the new profile's data when selected

#### Scenario: The page refuses to close
- **WHEN** the page's leave prompt keeps it open
- **THEN** the tab stays in its space with its page

### Requirement: Single native browser interface
The browser SHALL show tabs and navigation state only in its native sidebar and optional top bar, and SHALL NOT render Chromium's tab strip or toolbar in a browser window.

#### Scenario: Every window state shows one set of controls
- **GIVEN** a regular or private window showing one page, a split of two to four panes, or Peek
- **WHEN** the window is displayed, resized, changes space, enters or leaves full screen, or is restored after relaunch
- **THEN** no Chromium tab strip, address field, back, forward or reload button, profile button or app menu is visible
- **AND** page content begins directly below the top bar, or at the top of the window when the top bar is off, with no empty band

#### Scenario: Removed controls cannot take focus
- **WHEN** the user moves keyboard focus through the window or inspects it with assistive technology
- **THEN** focus does not enter the removed Chromium controls and they are not exposed as interface elements

#### Scenario: Browser features outlive the toolbar
- **WHEN** the user finds in page, answers a site permission request, saves a password, starts a download or runs an extension action
- **THEN** the feature stays reachable from the native interface and its prompt appears within the window

### Requirement: Copy the current page screenshot
The browser SHALL copy an image of the requested page's rendered viewport through the screenshot command while respecting capture restrictions and current page ownership.

#### Scenario: Copy a Chromium page
- **GIVEN** the current page permits capture and has a rendered viewport
- **WHEN** the user invokes Copy Screenshot through its menu or shortcut
- **THEN** the clipboard contains an image of that page's viewport
- **AND** no replacement page is loaded or selected to perform the capture

#### Scenario: Document changes during capture
- **GIVEN** a screenshot is pending
- **WHEN** its document, profile or owning window changes before the result is delivered
- **THEN** the old result does not update the clipboard or report success

#### Scenario: A newer copy takes priority
- **GIVEN** a screenshot is pending and the user copies another item
- **WHEN** the older screenshot finishes
- **THEN** the newer clipboard content remains intact

#### Scenario: Capture is unavailable
- **GIVEN** the current page disallows capture or has no rendered viewport
- **WHEN** the user invokes Copy Screenshot
- **THEN** the clipboard remains unchanged and the browser reports that the screenshot is unavailable

### Requirement: Profile isolation
The browser SHALL isolate persistent website data and site permissions by profile.

#### Scenario: Shared and separate profiles
- **GIVEN** two spaces use profile A and another uses profile B
- **WHEN** a user signs in to a site in one space using A
- **THEN** the other space using A can use that session
- **AND** B receives neither the session nor A's permission grants

### Requirement: Profile reassignment continuity
The browser SHALL retain a space's tabs and saved windows while changing their website-data ownership to the selected destination profile.

#### Scenario: Move a space between profiles
- **GIVEN** two spaces share Work and Personal has a different signed-in session
- **WHEN** the user moves one Work space to Personal and accepts closing its affected pages
- **THEN** the moved space retains its tab and saved-window identities and reloads its pages using Personal
- **AND** the other Work space remains usable with Work's existing session
- **AND** Work's cookies, extension state and credentials are not copied to Personal

### Requirement: Interrupted profile operation recovery
The browser SHALL keep an interrupted profile deletion or reassignment recoverable through its profile settings.

#### Scenario: Assignment cannot be saved before deletion
- **GIVEN** the user requests deletion of Work and reassignment of its spaces to Personal
- **WHEN** saving the reassignment fails after page closure was accepted
- **THEN** Work's source data is retained and the incomplete operation is shown for retry
- **AND** relaunch does not silently erase that data or substitute another destination profile

#### Scenario: Relaunch with only an unavailable saved window
- **GIVEN** a pending deletion makes the only saved window's profile unavailable and the chosen survivor has no space
- **WHEN** the browser relaunches
- **THEN** the user can reach profile settings and retry the existing operation
- **AND** the unavailable saved window is preserved without creating a persistent recovery space or tab
- **AND** a successful retry restores its original tab and window identities under the chosen survivor

### Requirement: Independent private sessions
The browser SHALL isolate website data and site-permission grants between independently opened private sessions.

#### Scenario: Independently opened private windows remain isolated
- **GIVEN** two private windows are opened independently
- **WHEN** one signs in to a site, stores website data and grants a site permission
- **THEN** the other receives none of that session's cookies, website data or permission grants
- **AND** closing either private session does not clear the other session's live data

### Requirement: Private session disposal
The browser SHALL discard private-session browsing data when the private session ends.

#### Scenario: Close a private session
- **GIVEN** a private session visits a site, signs in, and grants a site permission
- **WHEN** all windows belonging to that private session close and a new private session begins
- **THEN** the new session has none of those cookies, history entries, or permission grants
- **AND** regular profiles contain none of the private session's browsing data

### Requirement: Opt-in page-text history
The browser SHALL preserve the existing opt-in page-text history search for eligible Chromium pages.

#### Scenario: Search a visited page's text
- **GIVEN** page-text history search is enabled and a regular-profile page has finished loading
- **WHEN** the browser captures its text and the user searches for a phrase from that page
- **THEN** the existing history search can return the visited page
- **AND** capture does not create a WebKit page, reload the document, or change the selected tab

#### Scenario: Exclude private and Agent documents
- **GIVEN** page-text history search is enabled
- **WHEN** a private, ephemeral-profile or Agent page finishes loading
- **THEN** its text is not captured for the history index

#### Scenario: Reject a stale history capture
- **GIVEN** a page-text capture is pending
- **WHEN** its document or profile changes, its owner ends, or the setting is disabled before the result returns
- **THEN** that result is not written to history search

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

### Requirement: Profile-bound Pawl Vault integration
When enabled, the Chromium browser SHALL preserve Pawl password/one-time-code selection, user-approved password saving and supported Pawl passkeys. Operations SHALL retain the initiating origin/profile and their valid request or submission identity. Secret filling SHALL require the user's credential choice and the original field's current foreground ownership.

#### Scenario: Fill a field inside another origin
- **GIVEN** the user focuses a supported field inside a cross-origin frame
- **WHEN** the user chooses a Pawl credential
- **THEN** credential lookup uses that frame's origin and the page's profile
- **AND** filling targets only the original field, never a field in the parent or a replacement document

#### Scenario: A late credential result loses its target
- **GIVEN** a credential lookup or fill request is pending
- **WHEN** its document, profile, field or owning foreground window changes
- **THEN** the old result does not fill a field or move focus back
- **AND** cleanup of the old request does not cancel a newer credential request
- **AND** a cancelled user choice can be retried from the current field

#### Scenario: Pawl becomes available after browser startup
- **GIVEN** Pawl integration is enabled and Pawl was locked or unavailable when the browser started
- **WHEN** Pawl becomes available and the user focuses a supported field again
- **THEN** credential selection can resume without relaunching the browser or toggling the setting
- **AND** disabling the integration prevents further field-triggered Pawl requests

#### Scenario: Saving and passkeys retain their consent boundaries
- **WHEN** a site offers a password save or requests a Pawl passkey operation
- **THEN** the corresponding existing user-consent flow remains available for the initiating origin and profile
- **AND** neither operation silently substitutes another profile's credentials
- **AND** working stock Chromium security keys alone do not qualify Pawl passkey parity

#### Scenario: Save after a successful login redirect
- **GIVEN** Chromium has validated a password submission and the site redirects after login
- **WHEN** the user accepts the save offer
- **THEN** the saved credential retains the submission's origin and profile
- **AND** retiring its owner/profile or superseding the submission cancels the old offer

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

### Requirement: Window look follows Arc
The browser window SHALL present the same layout as Arc, judged by comparing the real windows side by side, and SHALL NOT show any Chromium bookmark interface.

#### Scenario: Window controls share one row
- **WHEN** a browser window is displayed with the sidebar visible
- **THEN** the window buttons, sidebar toggle, back, forward and reload controls appear on one row at the top of the sidebar
- **AND** the address control appears directly below that row

#### Scenario: The page is framed
- **GIVEN** a window showing one page, a split, Peek or an empty space
- **WHEN** the window is displayed or resized
- **THEN** the page area has rounded corners and is inset from the top, right and bottom window edges
- **AND** the sidebar colour fills the gap between the page area and the window edge

#### Scenario: The address control at rest
- **GIVEN** a loaded page and no pointer over the address control
- **WHEN** the sidebar is displayed
- **THEN** the address control shows the page's host name without permanent trailing controls

#### Scenario: The Library is not squeezed into the sidebar
- **WHEN** the user opens the Library
- **THEN** it presents the same layout as in Arc rather than fitting inside the sidebar's width

#### Scenario: Bookmarking keeps to the sidebar
- **WHEN** the user presses the Bookmark Tab shortcut on a page
- **THEN** the tab moves to the space's pinned section, or back to its tabs if it is already there
- **AND** no Chromium bookmark dialog or bubble appears
