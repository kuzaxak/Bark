# Independent distribution

## Purpose

Give users a maintainer-owned source, support, and update path while preserving the project's origins and recoverable repository history.

## ADDED Requirements

### Requirement: Independent project destinations
The distributed application SHALL direct source, support, release, and update actions to destinations controlled by the independent project's maintainers.

#### Scenario: User requests support
- **WHEN** a user opens the application's support or source action
- **THEN** it opens the independent project's configured destination
- **AND** upstream links appear only as clearly labeled attribution or dependency references

### Requirement: Repository independence preserves history
The standalone source repository SHALL retain the selected fork's published branch and tag commit identities when leaving the upstream fork network.

#### Scenario: Compare source after separation
- **GIVEN** a verified inventory of published branches and tags before separation
- **WHEN** the standalone repository is established
- **THEN** each inventoried branch and tag resolves to the recorded commit
- **AND** the repository is no longer a member of the upstream fork network

### Requirement: Distribution preserves provenance
The independent distribution SHALL retain applicable upstream copyright, license, and third-party notices.

#### Scenario: Inspect a release
- **WHEN** a user opens the release's acknowledgements and corresponding source
- **THEN** the Nook derivation and applicable component notices remain available
- **AND** the independent maintainer is distinguished from upstream

### Requirement: Separation retains a trusted update path
Existing supported installations SHALL have a verified signed update path to the independent distribution.

#### Scenario: Installed fork crosses the repository transition
- **GIVEN** an installation using the old release feed and trusted signing key
- **WHEN** it checks for the transition release
- **THEN** it can obtain and authenticate the intended update
- **AND** subsequent update checks reach the maintained feed

#### Scenario: Transition payload is untrusted
- **WHEN** the transition feed supplies a payload with an invalid update signature
- **THEN** the installation rejects it without replacing the installed application

### Requirement: Clean contributor build

The project SHALL let a contributor with the matching SDK, supported toolchain and signing identity build a verified local app from a clean checkout.

#### Scenario: Build after deleting generated outputs

- **GIVEN** a checkout with no previous build directory and the matching SDK available
- **WHEN** the contributor runs the documented local app build
- **THEN** it produces a signed app containing the engine identified by the checkout

#### Scenario: Rebuild with an incompatible SDK

- **GIVEN** a previously verified local app and an SDK with a different artifact digest
- **WHEN** the contributor attempts to replace the app using that SDK
- **THEN** the command reports the mismatch and the previous app remains usable

### Requirement: Reuse a prepared engine checkout

A contributor SHALL be able to apply a revised Bark engine recipe to an existing checkout of the same pinned Chromium and dependencies while retaining its incremental build outputs.

#### Scenario: Continue an interrupted recipe update

- **GIVEN** a prepared checkout where some files already match the destination recipe and the rest still match the starting recipe
- **WHEN** the contributor repeats the update
- **THEN** the resulting sources match the destination recipe and existing compiler outputs remain available for the next build

#### Scenario: Protect local source work

- **GIVEN** a local source edit that matches neither recipe
- **WHEN** the contributor requests the update
- **THEN** it identifies the conflicting source before replacing any files

### Requirement: Select the macOS SDK for an official engine build

A maintainer SHALL be able to build the optimized engine with the pinned Apple SDK installed separately from the selected Xcode.

#### Scenario: Xcode defaults to a different SDK

- **GIVEN** compatible build tools and a separate copy of the pinned SDK
- **WHEN** the maintainer selects that SDK for an official engine build
- **THEN** the compiled engine and its framework metadata identify the selected SDK
- **AND** Xcode keeps its existing default SDK

#### Scenario: Selected SDK has the wrong build

- **WHEN** the maintainer selects an SDK with the expected version and a different Apple build identifier
- **THEN** the build reports the mismatch before compiling or replacing existing outputs
