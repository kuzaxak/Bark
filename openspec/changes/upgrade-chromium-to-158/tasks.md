# Chromium 158 upgrade

The Chromium release branch is `release/2.0`. Nook transition changes live on `release/1.5.5`. Both integrate into `main`. The signed comparison build is Bark 1.5.4 (123), recorded at `codex/bark-1.5.4-123`. Both desktops are reserved for the maintainer’s interactive checks.

## 1. Select and pin upstream

- [x] 1.1 Verify the generally released Mac Stable tag 158.0.8127.37 and source commit `b8c2be851f62f6a394ec57955d7f31335d7cb6d4` for both architectures.
- [x] 1.2 Verify the two browser PGO objects and the V8 builtins profile against their upstream storage checksums. Pin the consumer-visible bytes, validate the macOS SDK and parse the target DEPS with the selected external depot_tools. Recorded in `447a33c3`.

## 2. Port the recipe and record the repeatable flow

- [x] 2.1 Provide a repository command for checking patches at a specific upstream commit. Exercise success and conflict with staged edits, unstaged edits and build outputs present. Record the command in the [upgrade guide](../../../Runtime/Chromium/README.md#upgrade-the-chromium-revision). Recorded in `a67e263f`.
- [x] 2.2 Compare the original recipe against 156 and 158. All 291 original patches applied to 156. The initial 158 pass identified 44 conflicting paths. Resolve those conflicts, remove superseded patches and adapt the mounted sources for verified API changes. Recorded in `5ef283bb` and `ae73eccb`.
- [x] 2.3 Replay the port on the exact 158 commit, verify the patch budget, and run the recipe tests. Final rehearsal applied 289 patches and 90 mounted files. The stack has 978 hunks and 12,579 added lines. Of 62 recipe tests, 59 passed and 3 were skipped. The standalone SDK launcher returned its expected refusal status.

## 3. Build each candidate

- [x] 3.1 Complete the pinned dependency sync, hooks and exact prepared-tree comparison on Intel. The prepared tree matched all 289 patches and 90 mounted files at Chromium 158.0.8127.37. The x86_64 Rust matcher compiled.
- [ ] 3.2 Compile and link the M158 Intel engine, packaging target and Bark browser tests. Resolve remaining compile or link failures and repeat the patch budget and replay checks after recipe edits. Developer GN generation passed on Intel with Xcode 26.3 and macOS SDK 26.2. The developer compile was stopped without errors to prioritize the official x64 build with macOS SDK 26.5 (25F70). Official GN generation passed, the pinned Intel PGO and V8 profiles matched, and Clang began the PGO build.
- [ ] 3.3 Compile and link the corresponding Apple Silicon targets. Record where compilation ran. The Intel Actions runner cross-compiles the ARM target. Native ARM qualification runs on a hosted macOS runner.
- [ ] 3.4 Produce the candidate SDK and signed app for each architecture. Verify the embedded engine revision, bridge headers, SDK identity, architecture and host-only launcher from the packaged candidate.

## 4. Qualify the signed candidates

- [ ] 4.1 Run the native engine regressions on each architecture. Cover the Google account chooser, Web Store approval and cancellation, Pawl password and OTP ownership, and superseded profile selection. Record any skipped cases by architecture.
- [ ] 4.2 Exercise normal startup, first input, a profile switch with a pending permission prompt, an extension installation in the intended space, Cmd-click opening a background tab in the second space of a shared profile (P7), and a warm tab switch in each signed app. Record which candidate and architecture passed before distribution pins are promoted.

## 5. Release Bark 2.0.0 to existing Nook users

- [x] 5.1 Reserve the deployed Nook build sequence for the two-hop upgrade. Xcode resolves Bark 2.0.0 (202611200002) after Nook 1.5.4 (202611050920) and the universal Nook 1.5.5 transition (202611200001).
- [ ] 5.2 Build, sign and notarize the universal Nook 1.5.5 transition from the released Nook source with the original update key. Verify that standard and renamed installations can reach their native Bark appcast. Preserve automatic update preferences and access to Export Space.
- [ ] 5.3 Exercise both signed updates from a copy of the published Nook 1.5.4 on each processor. Check existing install path, relaunch, physical processor under Rosetta, preserved on-disk Nook data and the next Bark update. Keep the public feed on the previous release until qualification passes.
- [ ] 5.4 Promote both official SDK pins and receipts. Archive the implemented OpenSpec, integrate the reviewed changes into `main` in `kuzaxak/Bark` and push. Preserve a source ref for the transition.
- [ ] 5.5 Publish the qualified Apple Silicon and Intel DMGs, both Bark appcasts, and legacy `appcast.xml` together on GitHub Latest. Verify the original Nook installation URL, both Bark feeds and their immutable signed download URLs after publication.

## 6. Compile and qualify in GitHub Actions

- [x] 6.1 Stop standalone local compilation, retain its verified M158 checkout and use the connected `nook-release` runner for official PGO builds. The official Intel compile reached 1,505 actions locally before it was stopped. Both architectures still require a linked release build.
- [x] 6.2 Keep Chromium source and incremental outputs on the runner. Cache the verified SDK pair in Actions using the release recipe, target inputs and toolchain fingerprint. Revalidate restored artifacts before signing. [Build and cache procedure](../../../CONTRIBUTING.md#release-bark-200-from-github-actions)
- [x] 6.3 Prepare the universal Nook transition at `815c69d0` on `release/1.5.5` and the tag-triggered workflow for signing, native hosted tests and publication. Actual notarization, native execution and delivery remain tracked above.
