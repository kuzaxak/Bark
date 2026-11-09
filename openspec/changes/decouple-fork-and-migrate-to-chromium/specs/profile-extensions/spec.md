# Profile extensions and Chromium settings

## Purpose

Provide broad Chrome extension support with independent profile ownership and reliable access to each profile's underlying Chromium settings.

## ADDED Requirements

### Requirement: Broad extension support at launch
The first stable Chromium release SHALL pass the declared Chrome extension compatibility suite covering installation, updates, MV3 worker lifecycle, content scripts, actions, options, messaging, storage, network rules, and native messaging.

#### Scenario: Exercise representative extensions
- **GIVEN** the release suite contains independently authored extensions exercising each required capability
- **WHEN** they are installed and used through ordinary browser UI
- **THEN** every mandatory workflow completes, including after a browser restart and an extension update
- **AND** any unsupported Google-service-dependent behavior is explicitly identified rather than advertised as working

### Requirement: Profile-owned extension installations
The browser SHALL scope an extension's installed and enabled state to its owning profile.

#### Scenario: Install in one profile
- **GIVEN** profiles Work and Personal exist and two spaces share Work
- **WHEN** an extension is installed in Work
- **THEN** it is available in both Work spaces
- **AND** it is absent from Personal until separately installed there

#### Scenario: Disable or remove one installation
- **GIVEN** the same extension is installed in Work and Personal
- **WHEN** the user disables or removes it in Work
- **THEN** Personal's installation and enabled state are unchanged

### Requirement: Profile-owned extension state
The browser SHALL isolate an extension's permissions, persistent storage, and running background state by profile.

#### Scenario: Independent settings for the same extension
- **GIVEN** the same extension is installed in Work and Personal
- **WHEN** the user stores a value and grants an optional host permission in Work
- **THEN** Personal cannot read that value or exercise that grant
- **AND** the isolation survives an extension update and browser restart

### Requirement: Profile-bound extension events
The browser SHALL expose only the owning profile's tabs, windows, and page events to an extension.

#### Scenario: Extension enumerates tabs
- **GIVEN** Work and Personal each have windows and private browsing is open
- **WHEN** a Work extension requests its accessible tabs and windows
- **THEN** it receives only regular Work tabs and windows allowed by its permissions
- **AND** a subsequent profile switch does not redirect its actions to Personal

### Requirement: Explicit extension permissions
The browser SHALL require user consent before an extension gains additional permissions.

#### Scenario: Update requests more access
- **WHEN** an update requests a new permission requiring consent
- **THEN** that permission is not granted before the user accepts it in the owning profile
- **AND** declining does not grant it through another profile's acceptance

### Requirement: No extensions in private sessions
The browser SHALL keep extensions installed by users or organizations disabled in private sessions for the initial Chromium release.

#### Scenario: Installed extension during private browsing
- **GIVEN** a user-installed extension is enabled in a regular profile
- **WHEN** a private session is opened
- **THEN** the extension does not execute in it or receive its page events

#### Scenario: Regular-profile incognito preference cannot enable private execution
- **GIVEN** a user-installed extension has incognito access enabled in a regular profile
- **WHEN** a private session is opened
- **THEN** the extension remains unable to execute in that private session or receive its page events

### Requirement: Profile settings shortcuts
Each Chromium-backed profile's settings page SHALL offer quick links to Chromium Settings, Extensions, Privacy and Security, Site Settings, and Clear Browsing Data for that selected profile.

#### Scenario: Settings selection differs from active window
- **GIVEN** Settings has Work selected while the front browser window uses Personal
- **WHEN** the user selects the Extensions quick link
- **THEN** the extension manager opens in Work
- **AND** the destination visibly identifies Work and does not adopt Personal's runtime context

#### Scenario: Clear only the selected profile
- **GIVEN** Work and Personal both have site data
- **WHEN** the user follows Work's Clear Browsing Data link and confirms deletion
- **THEN** Chromium applies the selected deletion to Work only
- **AND** native profile settings reflect the resulting state on return

#### Scenario: Profile has no open window
- **WHEN** the user opens a settings shortcut for a valid profile with no open window
- **THEN** a settings surface is created in that profile without changing its space assignments

### Requirement: Consistent profile search preferences
The browser SHALL use each Chromium profile's effective search provider consistently across native search controls, typed searches and supported search suggestions.

#### Scenario: Change the provider in Chromium settings
- **GIVEN** Work and Personal have different search providers
- **WHEN** the user changes Work's provider in Chromium settings and returns to the native interface
- **THEN** Work's native control and subsequent searches use the new provider
- **AND** suggestions are not sent to Work's previous provider
- **AND** Personal's provider remains unchanged

#### Scenario: Change the provider through the native control
- **WHEN** the user chooses an editable profile's provider through its native search control
- **THEN** Chromium settings and searches in that profile's spaces reflect that same choice
- **AND** other profiles retain their choices

#### Scenario: Import the effective choice once
- **GIVEN** a profile has an explicit app search choice or inherits the app default before conversion
- **WHEN** its Chromium search preferences are initialized
- **THEN** its effective choice is imported once
- **AND** subsequent launches or app-global changes do not overwrite its Chromium choice

#### Scenario: Provider controlled by policy or an extension
- **GIVEN** a profile's provider is controlled by mandatory policy or an extension
- **WHEN** the user opens the native search control
- **THEN** the control identifies that restriction and cannot override it
- **AND** searches continue using the effective controlled provider

#### Scenario: Custom provider requires a POST request
- **GIVEN** the profile's supported custom provider requires POST data and a particular query encoding
- **WHEN** the user submits a typed search
- **THEN** the request uses that provider's required method, data and encoding
- **AND** it is not replaced by a GET request or another provider

#### Scenario: Search from a new tab or split
- **GIVEN** the profile's Chromium provider differs from its former app search choice
- **WHEN** the user submits a search to create a tab or fill a split pane
- **THEN** the new page uses its own profile's Chromium provider and request semantics
- **AND** no preliminary request is sent to the former provider or to the POST destination using GET

#### Scenario: Keep a background search cold and recoverable
- **WHEN** the user opens a search in a background tab without selecting it
- **THEN** the query is retained without creating its renderer or changing the selected page
- **AND** selecting it after relaunch, or after closing and reopening its containing folder, executes the retained query in that tab's profile
- **AND** private queries remain outside persisted session and closed-tab records

#### Scenario: Suggestions follow the edited page
- **GIVEN** the address editor targets a split or Peek page whose profile differs from the window's current space
- **WHEN** the user types a search
- **THEN** suggestions use the edited page's effective provider
- **AND** changing or closing the editing target invalidates its pending suggestions
- **AND** a private page sends no suggestion request

### Requirement: Stale profile targets fail safely
The browser SHALL refuse a settings or extension action whose target profile no longer exists.

#### Scenario: Profile deleted before opening settings
- **GIVEN** a profile-specific shortcut was queued before the profile was deleted
- **WHEN** the shortcut executes
- **THEN** the user sees that the profile is unavailable
- **AND** no default or currently active profile is substituted

### Requirement: Native messaging authorization
The browser SHALL authorize native messaging using the requesting extension identity and that profile's permissions.

#### Scenario: Host rejects an extension origin
- **WHEN** an extension attempts to contact a host whose allowed origins do not include it
- **THEN** the connection is rejected
- **AND** an authorized connection from another profile does not authorize this request
