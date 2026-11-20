# Chromium 158 upgrade

The implementation branch is `codex/bark-chromium-158`. The signed comparison build is Bark 1.5.4 (123), recorded at `codex/bark-1.5.4-123`. Both desktops are reserved for the maintainer’s interactive checks.

## 1. Select and pin upstream

- [x] 1.1 Verify the generally released Mac Stable tag 158.0.8127.37 and source commit `b8c2be851f62f6a394ec57955d7f31335d7cb6d4` for both architectures.
- [x] 1.2 Verify the two browser PGO objects and the V8 builtins profile against their upstream storage checksums. Pin the consumer-visible bytes, validate the macOS SDK and parse the target DEPS with the selected external depot_tools. Recorded in `447a33c3`.

## 2. Port the recipe and record the repeatable flow

- [x] 2.1 Provide a repository command for checking patches at a specific upstream commit. Exercise success and conflict with staged edits, unstaged edits and build outputs present. Record the command in the [upgrade guide](../../../Runtime/Chromium/README.md#upgrade-the-chromium-revision). Recorded in `a67e263f`.
- [x] 2.2 Compare the original recipe against 156 and 158. All 291 original patches applied to 156. The initial 158 pass identified 44 conflicting paths. Resolve those conflicts, remove superseded patches and adapt the mounted sources for verified API changes. Recorded in `5ef283bb` and `ae73eccb`.
- [x] 2.3 Replay the port on the exact 158 commit, verify the patch budget, and run the recipe tests. Final rehearsal applied 289 patches and 90 mounted files. The stack has 978 hunks and 12,579 added lines. Of 62 recipe tests, 59 passed and 3 were skipped. The standalone SDK launcher returned its expected refusal status.

## 3. Build each candidate

- [ ] 3.1 Complete the pinned dependency sync, hooks and exact prepared-tree comparison on Intel. The target source is checked out and the x86_64 Rust matcher compiled.
- [ ] 3.2 Compile and link the M158 Intel engine, packaging target and Bark browser tests. Resolve remaining compile or link failures and repeat the patch budget and replay checks after recipe edits.
- [ ] 3.3 Compile and link the corresponding Apple Silicon targets. Record where compilation ran. Native execution on the ARM Mac is pending access to that host.
- [ ] 3.4 Produce the candidate SDK and signed app for each architecture. Verify the embedded engine revision, bridge headers, SDK identity, architecture and host-only launcher from the packaged candidate.

## 4. Qualify the signed candidates

- [ ] 4.1 Run the native engine regressions on each architecture. Cover the Google account chooser, Web Store approval and cancellation, Pawl password and OTP ownership, and superseded profile selection. Record any skipped cases by architecture.
- [ ] 4.2 Exercise normal startup, first input, a profile switch with a pending permission prompt, an extension installation in the intended space, Cmd-click opening a background tab in the second space of a shared profile (P7), and a warm tab switch in each signed app. Record which candidate and architecture passed before distribution pins are promoted.
