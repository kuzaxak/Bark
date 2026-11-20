# Chromium 158 upgrade design

## Context

The previous rehearsal used 156.0.8078.80 and 156.0.8078.105. All 291 patches applied to both revisions, although both browser PGO profiles and V8 changed. Build 123 provides a signed 156.0.8078.80 test baseline on both architectures. The milestone jump to 158 exposed 44 file-level patch conflicts before compilation.

## Goals / Non-Goals

Keep the existing Swift shell, C bridge and per-architecture distribution model. The qualification boundary is the engine update. Changes to profile storage formats, sync policy and release channels belong to their respective projects.

## Decisions

- **Use the generally released Mac Stable build.** Google announced 158.0.8127.36/.37 for desktop on November 17. The selected .37 source tag resolves to `b8c2be851f62f6a394ec57955d7f31335d7cb6d4`. The 159 entry is an Early Stable rollout. [Stable release](https://chromereleases.googleblog.com/2026/11/stable-channel-update-for-desktop_01699533288.html) · [Early Stable release](https://chromereleases.googleblog.com/2026/11/early-stable-update-for-desktop_01707050408.html)
- **Rehearse before syncing dependencies.** Replay Bark’s mounts and patches in a temporary Git index at the old and new commits. For conflicts, compare upstream 156, Bark’s revision of that file, and pristine 158. Apply the corrected recipe to a dedicated checkout and verify the resulting tree. Normal development checkouts and historical signed SDKs can stay in use. [Engine upgrade guide](../../../Runtime/Chromium/README.md#upgrade-the-chromium-revision)
- **Verify inputs from the selected revision.** Bind the engine to the exact tag, the two downloaded and decompressed macOS PGO profiles, and the V8 revision and builtins profile. The existing external depot_tools parsed the target’s DEPS. Upstream 158 supports the pinned universal SDK 26.5 (25F70) on both architectures.
- **Preserve both upstream and Bark behavior.** Port Bark’s new-tab and popup routing to the new disposition values, retain upstream first-frame input handling, and revalidate tab, window and profile ownership when presenting and accepting Web Store consent. Port compile-time API changes in mounted engine code as the build exposes them.

## Risks / Trade-offs

Clean patch application cannot detect a changed C++ signature or a UI action reaching the wrong profile. Compile and link the engine and browser tests, then exercise the host-sensitive paths on each architecture. A cross-build verifies compilation, while native checks establish execution.

## Migration Plan

Keep M158 on a qualification branch. Produce and verify each SDK and its matching signed Bark candidate before changing distribution pins. Use build 123 as the comparison app with a separate copy of the test profile. Preserve the pre-upgrade copy for rollback because Chromium may migrate data on first launch.
