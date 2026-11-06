# Cross-frame profile fixture (E5)

Use disposable Work and Personal profiles with different extension markers, set through this extension's ordinary options UI. No additional host permission is needed: both loopback ports match the existing `http://127.0.0.1/*` permission. Content scripts now run in all matching frames.

From the repository root, serve the same site directory in two terminals:

```fish
python3 -m http.server 8769 --bind 127.0.0.1 --directory Runtime/ChromiumTests/Fixtures/site
```

```fish
python3 -m http.server 8770 --bind 127.0.0.1 --directory Runtime/ChromiumTests/Fixtures/site
```

For each profile, call `chrome.runtime.sendMessage({type: 'reset-observations'})` from its extension document and retain `observationId`. Then navigate one regular tab to `http://127.0.0.1:8769/frames.html`. The top document and same-origin child use port 8769; the cross-origin child uses port 8770. Wait for all three `data-barc-frame-probe` attributes to contain successful receipts. Errors or missing receipts are failures, not evidence of isolation.

Call `assertProfileFixture` from that profile's extension document with:

- `marker`: its nonempty Work or Personal marker;
- `observationId`: the reset reply;
- `expectedFrames`: exactly three independently established current frame identities, each containing `role` (`top`, `same-origin`, `cross-origin`), `tabId`, `windowId`, `frameId`, `documentId`, `origin`, and exact `url`;
- `forbiddenTabIds`, `forbiddenWindowIds`, `forbiddenDocumentIds`: real identities from the other profile (and private context where available).

The native host must independently establish expected/current and foreign profile ownership from the actual RenderFrameHosts. Use the pinned Chromium `extensions::ExtensionApiFrameIdMap::GetFrameId(RenderFrameHost*)` and `GetDocumentId(RenderFrameHost*).ToString()` mapping (or a separately verified equivalent). CDP frame IDs are not the extension API's numeric frame IDs; do not substitute them. Do not derive expectations by copying the worker's actual event history. Missing native identity evidence keeps the runtime case unqualified. Reloading creates new document IDs; refresh expectations accordingly. Repeat in Personal with its own marker, IDs and reset, then verify Work's marker remains Work.

Each content script sends a unique request, receives the worker's storage marker and browser-provided `MessageSender` identity, and acknowledges that exact receipt from the same sender document. Only completed round-trips enter the existing bounded event history. A worker restart invalidates unfinished receipts; reset/repeat rather than accepting partial observations. This fixture does not qualify ordinary installation, browser profile binding, real frame dispatch, or compatibility until exercised in the actual runtime.
