## Purpose

Give the user a predictable choice of who may offer, fill, or save a website login in a Bark window, including when their chosen vault is unavailable.

## ADDED Requirements

### Requirement: Selected website password provider
Bark SHALL use the selected provider exclusively for built-in website password flows.

#### Scenario: An existing Chromium login matches
- **GIVEN** a regular profile already contains a Chromium login and the user has selected Pawl Vault
- **WHEN** a matching sign-in page loads or the user focuses its login field
- **THEN** only Pawl may offer a saved login or fill credentials through the browser
- **AND** Chromium does not automatically sign in, generate a password, or offer to save or update the submission

#### Scenario: Returning to Chromium
- **WHEN** the user selects Chromium and relaunches Bark
- **THEN** the owning profile can use its existing Chromium logins and Pawl does not offer credentials
- **AND** changing the provider neither copies nor deletes stored credentials

#### Scenario: Change the preference during a live credential request
- **WHEN** the user selects a different provider while Bark is running
- **THEN** Settings identifies the running provider and explains that the selection takes effect after a restart
- **AND** the current request remains with the running provider

### Requirement: Provider availability
Bark SHALL preserve the user's provider selection across disconnects, locks and restarts.

#### Scenario: Locked or incompatible provider
- **GIVEN** Pawl is selected
- **WHEN** the provider is locked, closed or refuses the signed Bark client
- **THEN** Bark shows the applicable recovery action in Passwords settings
- **AND** no Chromium suggestion, automatic fill or save substitutes for Pawl
- **AND** after recovery a new user gesture can start a fresh request

#### Scenario: Navigate before page attachment
- **GIVEN** a Bark profile with Pawl selected and a Chromium password already stored
- **WHEN** a document appears before Bark attaches its credential UI or while a page is being transferred
- **THEN** Chromium does not deliver a stored password to the document

### Requirement: Bound consent
Bark SHALL honor a Pawl credential selection only for the requesting foreground field, document, profile and native owner.

#### Scenario: Account chooser outlives the field
- **GIVEN** passwords or one-time codes exist for an embedded sign-in form
- **WHEN** the user opens the chooser and switches space, pane or profile before Pawl replies
- **THEN** the result is discarded and neither page receives a secret

#### Scenario: Script focuses the login field
- **WHEN** a page puts focus on a password field without user interaction
- **THEN** it cannot open Pawl's picker or request a secret
- **AND** a supported mouse or keyboard gesture on that field can open the picker

### Requirement: Consented credential writes
Bark SHALL offer an explicit, correctly targeted save or update for a validated regular-window website login.

#### Scenario: Update a known login after redirect
- **WHEN** the user approves updating a uniquely matched login after a successful submission and redirect
- **THEN** Pawl saves the new password on the approved entry for the original site
- **AND** the original profile owns the offer and Chromium stores no copy

#### Scenario: Several entries could be overwritten
- **WHEN** matching the login yields multiple possible update targets or the selected entry changes before saving
- **THEN** an unselected or changed entry cannot be silently overwritten

#### Scenario: Site used in a private window
- **WHEN** a successful private-window login is submitted
- **THEN** Bark offers no credential write from that submission and records no persistent browser-side login history for the integration

### Requirement: Authenticator choice
Selecting Pawl SHALL preserve Chromium's site and relying-party checks and the user's ability to choose a supported external security key.

#### Scenario: Supported modal passkey sign-in
- **WHEN** a site requests a supported passkey and the user chooses Pawl
- **THEN** the resulting signature belongs to that request and can be verified by the relying party
- **AND** cancelling consent settles only that request

### Requirement: Recognizable credential management
Bark SHALL identify the selected provider at its password-management entry points.

#### Scenario: Open Passwords from a profile
- **WHEN** the user opens password management with Pawl selected
- **THEN** they reach Pawl management or connection settings for Bark
- **AND** an unavailable provider has a visible status

#### Scenario: Open the built-in password manager directly
- **GIVEN** Pawl is the running provider
- **WHEN** the user invokes a browser password-management shortcut, built-in URL or context menu
- **THEN** the browser routes management to Pawl or its connection settings
- **AND** the page cannot receive credentials from Chromium through that action
