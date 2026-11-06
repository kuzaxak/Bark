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
The browser SHALL keep extensions disabled in private sessions for the initial Chromium release.

#### Scenario: Installed extension during private browsing
- **GIVEN** an extension is enabled in a regular profile
- **WHEN** a private session is opened
- **THEN** the extension does not execute in it or receive its page events

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
