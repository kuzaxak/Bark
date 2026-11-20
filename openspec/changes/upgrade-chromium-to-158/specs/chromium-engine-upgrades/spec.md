# Chromium engine upgrades

## Purpose

Contributors can assess Bark’s compatibility with a prospective Chromium release and identify which engine and architecture have been verified.

## ADDED Requirements

### Requirement: Rehearse a specified upstream revision

The upgrade check SHALL report whether the current Bark recipe applies to the upstream commit the contributor selected.

#### Scenario: Baseline passes and the proposed release conflicts

- **WHEN** a contributor checks an existing recipe against its known-good commit and a new tag has removed a line required by a patch
- **THEN** the baseline check succeeds and the check of the new tag fails with the affected source path

#### Scenario: Ported recipe succeeds

- **WHEN** the contributor repeats the check after adapting the conflicting patches
- **THEN** a successful result identifies the resolved commit and the number of patches applied

### Requirement: Preserve local work during rehearsal

The upgrade check SHALL preserve the contributor’s checked-out revision, staged and unstaged edits, and existing build outputs.

#### Scenario: A contributor has staged work on the previous milestone

- **WHEN** a contributor rehearses another locally available commit from a checkout with a staged edit and an incremental build
- **THEN** the same revision is checked out afterward with the original staged edit and build output still present, including when the rehearsal encounters a conflict

### Requirement: Qualify each architecture against its own candidate

The upgrade record SHALL identify the Chromium version and verification reached for each candidate architecture.

#### Scenario: One architecture has only compiled

- **WHEN** an Intel candidate completes its native checks and the Apple Silicon engine has only been cross-compiled
- **THEN** the record identifies native verification for Intel and outstanding native execution for Apple Silicon

### Requirement: Upgrade existing Nook installations to Chromium

The existing Nook update feed SHALL offer an authenticated path to the Chromium-based Bark release for each supported Mac.

#### Scenario: Existing installations adopt the new browser

- **GIVEN** an installed Nook 1.5.4 using its published update feed and allowing automatic updates
- **WHEN** the Chromium migration is released and the user completes the normal update and relaunch cycle
- **THEN** the installation becomes Bark for the Mac's native processor, including when Nook ran under Rosetta
- **AND** subsequent checks find updates for that processor
- **AND** existing Nook profile files remain available on disk

#### Scenario: A user defers the migration

- **GIVEN** a Nook installation with automatic update checks turned off
- **WHEN** the Chromium release becomes available
- **THEN** the existing installation can still open and export its spaces until the user chooses to update

#### Scenario: A Nook user skips the initial Chromium release

- **WHEN** a Nook 1.5.4 installation first checks its published update URL after a later Bark release
- **THEN** it can still authenticate the universal transition update and reach the supported native Bark release
