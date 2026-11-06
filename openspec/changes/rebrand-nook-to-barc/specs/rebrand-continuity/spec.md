# Rebrand continuity

## Purpose

Let existing Nook fork users move to a new Barc application identity with an explicit fresh start and a verifiable installation, update, and legacy-file import path.

## ADDED Requirements

### Requirement: Distinct application identity
Barc SHALL use its newly registered application identity for signed release builds.

#### Scenario: Inspect the installed product
- **WHEN** the signed Barc release is installed on Intel or Apple Silicon
- **THEN** its bundle and provisioning identify the new Barc App ID
- **AND** its production cloud access uses the new Barc container

### Requirement: Explicit reset notice
The transition SHALL explain the fresh synchronization start before the user enables Barc synchronization.

#### Scenario: Existing user enters Barc
- **GIVEN** the user previously synchronized spaces in Nook
- **WHEN** Barc offers its initial synchronization setup
- **THEN** it explains that previous cloud data and sharing invitations are not transferred
- **AND** users are told that old Nook devices will not synchronize with Barc

### Requirement: Fresh cloud state
Barc SHALL start synchronization in the new container without reusing the previous container's records, subscriptions, sharing identities, or synchronization cursors.

#### Scenario: First Barc sync
- **GIVEN** the old container contains spaces and the new Barc account has not synchronized yet
- **WHEN** the user starts fresh in Barc
- **THEN** old cloud records do not appear in Barc
- **AND** only data the user selects for Barc synchronization is uploaded

#### Scenario: A second Barc device joins
- **GIVEN** one Barc device has already synchronized data to the new container
- **WHEN** a second Barc device signs in to the same account
- **THEN** it joins the existing Barc dataset without resetting or deleting that dataset

### Requirement: Fresh local setup
Barc SHALL start with fresh local application state under the new identity without automatically migrating Nook data.

#### Scenario: Start fresh
- **WHEN** the user launches Barc for the first time
- **THEN** Barc does not copy previous local records or automatically upload them
- **AND** the previous installation's data remains untouched

#### Scenario: Existing Barc setup survives relaunch
- **GIVEN** the user has already completed Barc setup
- **WHEN** Barc launches again or updates
- **THEN** it retains the Barc setup rather than repeating the reset

### Requirement: New sharing invitations
Barc SHALL establish sharing through new invitations issued from the new container.

#### Scenario: Open an old Nook invitation
- **WHEN** the user opens an old-container sharing invitation in Barc
- **THEN** Barc explains that a new invitation is required
- **AND** it does not import or join the old shared zone

### Requirement: Trusted update continuity
The rebrand SHALL provide a signed update from the supported Nook fork release to Barc and onward to the next Barc release.

#### Scenario: Two-hop update rehearsal
- **WHEN** a supported Nook fork installation updates to Barc and then checks for a subsequent Barc release
- **THEN** both updates authenticate and install successfully
- **AND** relaunch opens the intended product with the initial fresh setup or subsequent existing Barc data, as appropriate

### Requirement: Legacy file compatibility
Barc SHALL continue opening previously supported Nook space files.

#### Scenario: Open an existing space export
- **WHEN** a user opens a valid legacy `.nookspace` file in Barc
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
- **AND** retrying does not reset an existing Barc setup
