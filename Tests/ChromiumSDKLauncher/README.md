# Run official browser regressions on Apple Silicon

To verify the helper apps in an installed candidate on its native Mac, run
`python3 -B Tests/ChromiumSDKLauncher/check_helper_roles.py --app /Applications/Bark.app`.
The check verifies Bark's signature and runs each packaged helper in place
with window-server access, child processes, network and file writes denied.
Each helper must return its direct-launch refusal. Run the same command
without `--app` to exercise both accepted and refused subprocess roles against
the C and C++ entry point header.

After the official engine build links `bark_browser_tests`, package the test runtime from its completed GN output. Package from an idle build directory to keep the manifest and its inputs consistent.

```fish
set chromium_src /path/to/chromium/src
set handoff (mktemp -d)
set published_engine /path/to/published/arm64/Engine
mkdir "$handoff/sdk-metadata"
cp "$published_engine/SHA256SUMS" "$handoff/sdk-metadata/"; or exit 1
python3 -B scripts/package-chromium-tests.py "$chromium_src/out/Barc-arm64-official" \
    --arch arm64 --fixture-tree Runtime/Chromium/bark/test \
    --output "$handoff/BarkBrowserTests-arm64.tar.gz"; or exit 1
cd "$handoff"
shasum -a 256 BarkBrowserTests-arm64.tar.gz > SHA256SUMS
```

Send the archive, checksum and `sdk-metadata` directory alongside the Bark source with the matching ARM SDK pin. The archive includes GN’s runtime dependencies, Chromium version, and integrated bundle metadata. The packaged manifest records SHA-256 digests for the linked test executable and framework. For qualification use `--fixture-tree` after a completed exact-source build. The test executable contains a linked receipt covering every Bark test translation unit, its GN target and receipt generator. The same GN inventory drives compilation and verification. When adding a test-local header, list it under `support` in `browser_test_sources.json`. The packager compares that receipt with the reviewed source, so an old executable cannot acquire current proof just by updating the overlay. This test-only receipt does not change the runtime SDK pin. Packaging verifies the raw SDK is a background-only refusal stub before including its bundle. Keep the extracted `src/out/Barc-arm64-official` layout so the launcher and executable can find their frameworks and test data.

Use the producer's paired source snapshot if the transfer includes one. For an
ordinary checkout at the same engine recipe, first stage the Intel and ARM64
official pins and shared headers with [the paired metadata command](../../Runtime/Chromium/README.md#upgrade-a-bridge-shared-by-two-pinned-architectures).
A developer pin from the same source revision cannot verify an official test
runtime. If the transfer includes the complete official SDK archive, you can
use the checksum list from the verified, installed SDK instead of copying the
list separately. Use the [signed-walk Python](../../CONTRIBUTING.md#run-the-signed-ui-walks)
to install the archive:

```fish
cd /path/to/matching/Bark/source
"$BARK_WALK_PYTHON" -B scripts/bark-check.py engine --arch arm64 --require-official \
    --engine /path/to/BarkSDK-arm64.tar.gz --install; or exit 1
set sdk_pin (python3 -B scripts/chromium_sdk_layout.py digest Packages/BarkEngine arm64); or exit 1
set sdk_metadata "$HOME/Library/Caches/BarkSDK/$sdk_pin/Engine"
```

On the native Apple Silicon Mac, verify and unpack the test archive into a fresh directory. From the matching Bark source, use the exact-case runner with an idle desktop. The guarded launcher checks the native architecture and the host-only marker of the test executable and both linked frameworks before execution, and uses the shared screen guard and a disposable profile.

```fish
cd /path/to/handoff
shasum -a 256 -c SHA256SUMS; or exit 1
if not set -q sdk_metadata
    set sdk_metadata (pwd)/sdk-metadata
end
set staged (mktemp -d)
tar -xzf BarkBrowserTests-arm64.tar.gz -C "$staged"; or exit 1
cd /path/to/matching/Bark/source
python3 -B Tests/ChromiumSDKLauncher/run_browser_cases.py \
    --sdk-metadata "$sdk_metadata" \
    --checkout "$staged/src" \
    --binary "$staged/src/out/Barc-arm64-official/bark_browser_tests" \
    --summary "$staged/browser-cases.json" \
    --fixture-tree Runtime/Chromium/bark/test \
    BarcSharedPawlBrowserTest.VaultSaveRefusesMountedPrivateProfile \
    BarcSharedPawlBrowserTest.VaultRequestsRetireWhenSelectedHostPageChanges \
    BarkWindowHostBrowserTest.SpaceSwitchRestoresSelectedParkedContentsOnMount \
    BarcExtensionStorageBrowserTest.EscalatedReenableConsentRemainsWithOriginalLogicalOwner
```

Before launch, the runner checks both framework copies against the SDK checksum list and verifies that list against the checkout’s native SDK pin. The receiver needs only this list from the SDK. The runner also verifies the linked images against the packaged test manifest. The exact-case runner requires the complete linked-source receipt and defaults to the current checkout’s `Runtime/Chromium/bark/test`. It verifies every requested name against the executable’s GoogleTest list before taking the screen, then requires one successful result for each case. An unmatched test, a retry, or an incomplete summary fails qualification. Existing archives without a linked receipt can still be used with the general browser runner for historical checks. Retain the summary with the producer revision and archive digest. Packaging and marker checks do not establish a native ARM test pass or shipping app signature.

To qualify the raw launcher separately on its native architecture, run
`python3 -B Tests/ChromiumSDKLauncher/check.py "$staged/src/out/Barc-arm64-official" --arch arm64`.
That check inspects the raw and integrated metadata, Mach-O slice, and imports before exercising the refusal path.
