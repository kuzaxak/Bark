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
