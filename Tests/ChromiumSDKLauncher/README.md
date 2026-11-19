# Run official browser regressions on Apple Silicon

After the official engine build links `bark_browser_tests`, package the test runtime from its completed GN output. Package from an idle build directory to keep the manifest and its inputs consistent.

```fish
set chromium_src /path/to/chromium/src
set handoff (mktemp -d)
set published_engine /path/to/published/arm64/Engine
mkdir "$handoff/sdk-metadata"
cp "$published_engine/SHA256SUMS" "$handoff/sdk-metadata/"; or exit 1
python3 -B scripts/package-chromium-tests.py "$chromium_src/out/Barc-arm64-official" \
    --arch arm64 --fixture-source Runtime/Chromium/bark/test/barc_bridge_browsertest.mm \
    --output "$handoff/BarkBrowserTests-arm64.tar.gz"; or exit 1
cd "$handoff"
shasum -a 256 BarkBrowserTests-arm64.tar.gz > SHA256SUMS
```

Send the archive, checksum and `sdk-metadata` directory alongside the Bark source with the matching ARM SDK pin. The archive includes GN’s runtime dependencies, Chromium version, and integrated bundle metadata. The packaged manifest records SHA-256 digests for the linked test executable and framework. The optional fixture source checks that the installed Chromium overlay matches the reviewed source at export. Use it after a completed exact-source build. Those bytes describe the installed overlay and do not prove which source the compiler used. Packaging verifies the raw SDK is a background-only refusal stub before including its bundle. Keep the extracted `src/out/Barc-arm64-official` layout so the launcher and executable can find their frameworks and test data.

On the native Apple Silicon Mac, verify and unpack the archive into a fresh directory. From the matching Bark source, use the exact-case runner with an idle desktop. The guarded launcher checks the native architecture and the host-only marker of the test executable and both linked frameworks before execution, and uses the shared screen guard and a disposable profile.

```fish
cd /path/to/handoff
shasum -a 256 -c SHA256SUMS; or exit 1
set sdk_metadata (pwd)/sdk-metadata
set staged (mktemp -d)
tar -xzf BarkBrowserTests-arm64.tar.gz -C "$staged"; or exit 1
cd /path/to/matching/Bark/source
python3 -B Tests/ChromiumSDKLauncher/run_browser_cases.py \
    --sdk-metadata "$sdk_metadata" \
    --checkout "$staged/src" \
    --binary "$staged/src/out/Barc-arm64-official/bark_browser_tests" \
    --summary "$staged/shared-pawl.json" \
    --fixture-source Runtime/Chromium/bark/test/barc_bridge_browsertest.mm \
    BarcSharedPawlBrowserTest.VaultSaveRefusesMountedPrivateProfile \
    BarcSharedPawlBrowserTest.VaultRequestsRetireWhenSelectedHostPageChanges
```

Before launch, the runner checks both framework copies against the SDK checksum list and verifies that list against the checkout’s native SDK pin. The receiver needs only this list from the SDK. The runner also verifies the linked images against the packaged test manifest. With `--fixture-source`, it requires that manifest and the expected fixture digest. The runner requires one successful result for each named test. An unmatched test, a retry, or an incomplete summary fails qualification. Retain the summary with the producer revision and archive digest. Packaging and marker checks do not establish a native ARM test pass or shipping app signature.

To qualify the raw launcher separately on its native architecture, run
`python3 -B Tests/ChromiumSDKLauncher/check.py "$staged/src/out/Barc-arm64-official" --arch arm64`.
That check inspects the raw and integrated metadata, Mach-O slice, and imports before exercising the refusal path.
