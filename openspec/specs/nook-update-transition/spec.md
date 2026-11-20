# nook-update-transition Specification

## Purpose
Existing Nook users can move to the native Bark release for their Mac through the updater they already use.

## Requirements

### Requirement: Nook onboarding preserves the desktop

Nook 1.5.5 SHALL present incomplete onboarding with other applications retaining their visibility.

#### Scenario: Start Nook with another app visible

- **WHEN** the user opens Nook before finishing onboarding with a visible window from another app
- **THEN** Nook brings onboarding forward and the other app remains visible

### Requirement: Existing installations reach the native Bark release

The deployed Nook update URL SHALL deliver the signed universal transition. The transition SHALL select the Bark update feed for the physical Mac's architecture and honor the existing automatic update preference.

#### Scenario: Apple Silicon running a translated Nook

- **GIVEN** an Apple Silicon Mac running a translated copy of Nook 1.5.4
- **WHEN** the installed updater follows its original feed and the transition checks again
- **THEN** it receives Nook 1.5.5 first and the Apple Silicon Bark release next

#### Scenario: Intel Mac follows the original URL after the rename

- **GIVEN** Nook is installed on Intel with the original repository name in its update URL
- **WHEN** the user requests both updates
- **THEN** Nook receives the universal transition and then the Intel Bark release
