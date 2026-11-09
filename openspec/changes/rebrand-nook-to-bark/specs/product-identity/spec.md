# Product identity

## Purpose

Present Bark as a coherent independent browser through its name, original visual identity, public destinations, and accurate acknowledgements.

## ADDED Requirements

### Requirement: Consistent product name
The application SHALL identify itself as Bark on user-facing product surfaces.

#### Scenario: Fresh installation
- **WHEN** a user installs and opens the release
- **THEN** Finder, the Dock, app menus, About, onboarding, settings, and update UI identify the product as Bark
- **AND** permission descriptions use Bark where the application name is included

#### Scenario: Inspect legacy references
- **WHEN** a user encounters Nook in the shipped product or its documentation
- **THEN** the reference is explicitly historical, attribution, import guidance, or legacy compatibility terminology
- **AND** it does not present Nook as the current product or support owner

### Requirement: Original Bark visual identity
The application SHALL use the selected original Bark mark for its product logo and app icon.

#### Scenario: Inspect shipping artwork
- **WHEN** production and development builds are inspected in Finder, the Dock, About, onboarding, and installer artwork
- **THEN** each uses the approved Bark asset variant
- **AND** the development icon is distinguishable from production
- **AND** the former Nook mark is not used as the Bark product identity

### Requirement: Recognizable rendered icons
Bark's shipped icons SHALL remain identifiable and unclipped at supported system sizes and appearances.

#### Scenario: Small-size appearance review
- **WHEN** the app icon is rendered at small Dock/Finder sizes and the supported light, dark, and tinted appearances
- **THEN** its silhouette remains recognizable and no intended content is clipped
- **AND** the result matches the approved asset review

### Requirement: Independent public identity
Bark's public product pages SHALL identify the independent maintainer and the correct source, support, and download destinations.

#### Scenario: Read the project landing page
- **WHEN** a user follows the README's download and issue links
- **THEN** they reach Bark's maintained release and support destinations
- **AND** attribution links to Nook are labeled as upstream history

### Requirement: Preserve acknowledgements
The rebrand SHALL preserve applicable copyright, license, and third-party attribution notices.

#### Scenario: Compare before and after branding
- **WHEN** the rebranded source and acknowledgements are reviewed
- **THEN** prior authorship and license notices remain attributable to their original owners
- **AND** Bark branding does not imply ownership of the Nook trademarks or endorsement by upstream
