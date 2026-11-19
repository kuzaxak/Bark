# Rebrand continuity

## Purpose

Let existing Nook fork users move to a new Bark application identity with an explicit fresh start and a verifiable installation, update, and legacy-file import path.

## ADDED Requirements

### Requirement: Distinct application identity
Bark SHALL use its newly registered application identity for signed release builds.

#### Scenario: Inspect the installed product
- **WHEN** the signed Bark release is installed on Intel or Apple Silicon
- **THEN** its bundle and provisioning identify the new Bark App ID
- **AND** its production cloud access uses the new Bark container

### Requirement: Explicit reset notice
The transition SHALL explain the fresh synchronization start before the user enables Bark synchronization.

#### Scenario: Existing user enters Bark
- **GIVEN** the user previously synchronized spaces in Nook
- **WHEN** Bark offers its initial synchronization setup
- **THEN** it explains that previous cloud data and sharing invitations are not transferred
- **AND** users are told that old Nook devices will not synchronize with Bark

### Requirement: Fresh cloud state
Bark SHALL start synchronization in the new container without reusing the previous container's records, subscriptions, sharing identities, or synchronization cursors.

#### Scenario: First Bark sync
- **GIVEN** the old container contains spaces and the new Bark account has not synchronized yet
- **WHEN** the user starts fresh in Bark
- **THEN** old cloud records do not appear in Bark
- **AND** only data the user selects for Bark synchronization is uploaded

#### Scenario: A second Bark device joins
- **GIVEN** one Bark device has already synchronized data to the new container
- **WHEN** a second Bark device signs in to the same account
- **THEN** it joins the existing Bark dataset without resetting or deleting that dataset

### Requirement: Opt-in Chromium bookmark synchronization
Bark SHALL let a user enable iCloud sync on each Mac and choose the content synchronized for each regular space.

#### Scenario: Sync nested folders across Macs
- **GIVEN** two Macs have enabled sync for the same Bark space with Favorites & Pinned
- **WHEN** a bookmark or folder is created, renamed, reordered, moved into another folder or deleted on either Mac
- **THEN** both Macs converge on the same names, folder contents and ordering
- **AND** open tabs stay local unless the user selects Everything

#### Scenario: Turn off sync on this Mac
- **WHEN** the user turns off sync on a Mac and relaunches Bark
- **THEN** its bookmarks remain available locally
- **AND** subsequent bookmark edits stay on that Mac until the user enables sync again

#### Scenario: Incoming change affects a live Chromium page
- **WHEN** applying a remote change would discard a page that the user still has open or transfer it to another profile
- **THEN** Bark preserves the open page and its profile
- **AND** the remote change remains pending until Bark can apply and save it

### Requirement: Fresh local setup
Bark SHALL start with fresh local application state under the new identity without automatically migrating Nook data.

#### Scenario: Start fresh
- **WHEN** the user launches Bark for the first time
- **THEN** Bark does not copy previous local records or automatically upload them
- **AND** the previous installation's data remains untouched

#### Scenario: Existing Bark setup survives relaunch
- **GIVEN** the user has already completed Bark setup
- **WHEN** Bark launches again or updates
- **THEN** it retains the Bark setup rather than repeating the reset

### Requirement: New sharing invitations
Bark SHALL establish sharing through new invitations issued from the new container.

#### Scenario: Share bookmarks between two iCloud accounts by invite code
- **GIVEN** two Macs have enabled Bark sync using different iCloud accounts
- **WHEN** the owner enters the other Mac’s invite code and the invited user accepts the resulting link
- **THEN** both users can edit bookmarks in the shared space and see each other’s changes
- **AND** each Mac continues to show its own iCloud account ID in Spaces settings

#### Scenario: Open an old Nook invitation
- **WHEN** the user opens an old-container sharing invitation in Bark
- **THEN** Bark explains that a new invitation is required
- **AND** it does not import or join the old shared zone

### Requirement: Trusted update continuity
The rebrand SHALL provide a signed update from the supported Nook fork release to Bark and onward to the next Bark release.

#### Scenario: Two-hop update rehearsal
- **WHEN** a supported Nook fork installation updates to Bark and then checks for a subsequent Bark release
- **THEN** both updates authenticate and install successfully
- **AND** relaunch opens the intended product with the initial fresh setup or subsequent existing Bark data, as appropriate

### Requirement: Legacy file compatibility
Bark SHALL continue opening previously supported Nook space files.

#### Scenario: Open an existing space export
- **WHEN** a user opens a valid legacy `.nookspace` file in Bark
- **THEN** the existing import behavior works without requiring a filename or content rewrite
- **AND** old cloud tokens, sharing state and automatic sync opt-in are not restored by importing a space file

### Requirement: Integration continuity
The rebrand SHALL explain and support reconnection for integrations affected by the new application identity.

#### Scenario: Use existing integration configuration
- **GIVEN** a working external-link association, credential provider, native messaging host, or local automation client before the rename
- **WHEN** the corresponding integration is used after the rebrand
- **THEN** it continues to work or provides a documented reconnection step
- **AND** no secret or permission is silently widened during migration

### Requirement: Recoverable rebrand update
A failed rebrand update SHALL leave the previous local installation data recoverable.

#### Scenario: Installer or relaunch failure
- **WHEN** replacement or relaunch of the rebranded app fails
- **THEN** the user can recover the prior signed build and its data
- **AND** retrying does not reset an existing Bark setup
