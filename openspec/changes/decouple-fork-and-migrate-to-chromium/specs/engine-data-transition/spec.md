# Engine data transition

## Purpose

Move existing users to the Chromium runtime without silently losing application data, sharing profile state, or making recovery depend on incompatible engine databases.

## ADDED Requirements

### Requirement: Application data continuity
The engine transition SHALL preserve application-owned profiles, space assignments, tab trees, pinned items, history, settings, and supported saved credentials.

#### Scenario: Upgrade an established installation
- **GIVEN** an installation with multiple profiles, shared-profile spaces, nested tabs, pinned items, history, and settings
- **WHEN** engine migration completes
- **THEN** those records retain their identities and relationships
- **AND** saved credential access continues where its backing provider remains available

### Requirement: Explain nonportable state
The transition SHALL identify website and extension state that cannot be migrated before the user starts the conversion.

#### Scenario: Website storage cannot transfer
- **GIVEN** an existing site depends on WebKit storage that the importer cannot transfer
- **WHEN** the transition is offered
- **THEN** the notice explains that some sites require signing in again
- **AND** migration does not report that site storage as successfully transferred

### Requirement: Restart-safe migration
The transition SHALL resume or safely retry after interruption without duplicating application records or overwriting a completed destination profile.

#### Scenario: Process exits mid-migration
- **WHEN** migration is interrupted after one profile completes but another has not
- **THEN** relaunch recognizes the completed profile
- **AND** it resumes or retries the unfinished profile without resetting the completed one

### Requirement: Recoverable source data
The transition SHALL retain a recoverable pre-migration copy of source data until the user explicitly removes it.

#### Scenario: Migration cannot finish
- **WHEN** migration encounters insufficient disk space or an unreadable source
- **THEN** it reports the failure without deleting the source
- **AND** the user can retry or restore the previous application state

### Requirement: Deliberate global extension conversion
The transition SHALL let the user choose destination profiles for previously global extensions.

#### Scenario: Convert an existing global extension
- **GIVEN** the WebKit app has a globally installed extension
- **WHEN** the user chooses to install it only in Work during conversion
- **THEN** Personal does not receive that installation or its grants
- **AND** nonportable extension settings and required permission prompts are disclosed

### Requirement: Profile-correct website import
Any supported website-state import SHALL retain the original profile boundary.

#### Scenario: Import the same site's cookies from separate profiles
- **GIVEN** two source profiles hold different sessions for the same site
- **WHEN** the importer transfers supported cookies
- **THEN** each session is imported only into its matching destination profile
- **AND** unsupported cookie attributes cause a reported skip rather than a widened cookie scope

### Requirement: Engine rollback uses compatible data
Recovery to the previous engine SHALL use its compatible saved state without silently discarding newer Chromium data.

#### Scenario: Return after Chromium use
- **GIVEN** the user has browsed with Chromium after migration
- **WHEN** they choose recovery to the prior engine
- **THEN** recovery explains which state will be restored
- **AND** Chromium data remains available separately rather than being interpreted as WebKit storage
