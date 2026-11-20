## Context

The universal Nook updater remains the first hop for existing installations. The Chromium shell shares its sidebar tree across regular windows and uses native page identifiers for keyboard commands.

## Decisions

- Keep the signed universal app on the deployed legacy URL. Its updater selects the canonical Bark feed by hardware architecture, including Apple Silicon running a translated process. Keep the transition source at a pinned commit on `release/1.5.5`. Use `main` for integration and `release/2.0` for Chromium fixes.
- Resolve Clear candidates from the live tree and all windows that own it. Retain the whole trail rooted at a protected page and recheck protection after asynchronous page release.
- Keep chat grants in memory. Key each grant by the browser or a configured external server. Keep URLhaus download validation and change its upper bound independently of other lists.
- Query the zoom controller through the existing versioned page-command table. Recheck the targeted window, document and page after dispatch. Draw a timed label in the active pane's overlay and announce the percentage to accessibility clients.

## Release

Run the package and native shell checks in GitHub Actions. Package both architecture-specific SDKs against the same bridge source and qualify each signed update on native hardware before making it available through Latest. Track release execution in the Chromium upgrade task list.
