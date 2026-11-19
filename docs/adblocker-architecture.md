# Bark’s Chromium content blocker

Bark filters requests and page content through its embedded Chromium engine. The
Swift shell manages settings and filter sources. Chromium applies the accepted
policy to requests and documents.

## From filter lists to Chromium

- [FilterListManager](../Packages/NookBlocker/Sources/NookBlocker/FilterListManager.swift)
  starts with bundled default snapshots, reads the enabled optional lists, and
  refreshes cached lists on their own expiry schedules. The app supplies the
  cache directory. Use [refresh-filter-lists.sh](../scripts/refresh-filter-lists.sh)
  to refresh the checked-in snapshots. The preprocessor selects the desktop
  `env_chromium` and `ext_ublock` branches on Intel and Apple Silicon.
- [ContentBlockerManager](../Packages/NookBlocker/Sources/NookBlocker/ContentBlockerManager.swift)
  builds a serialized adblock-rust matcher off the main actor and publishes an
  immutable result for the current source generation. Slow or cancelled builds
  cannot publish over newer settings. Its domain allowlist matches subdomains.
  Temporary disabling, OAuth exemptions, and continuing past a blocked page
  are scoped to the owning tab.
- [ChromiumContentBlocker](../App/Chromium/ChromiumContentBlocker.swift)
  sends the bytes and policy through the Bark SDK bridge. Chromium owns
  installation and readiness for each regular or off-the-record context. The
  shell waits for the required policy before admitting an initial navigation
  for a context that needs blocking.
- [NativeContentBlocker](../Runtime/Chromium/bark/browser/content_blocking/native_content_blocker.cc)
  uses the Rust matcher for request decisions and supplies document cosmetic
  rules to the Chromium renderer. Plain hide selectors and supported CSS style
  actions apply there. The renderer executes supported scriptlets with the
  bundled scriptlet resources, scoped to the intended document. Keep trusted
  list metadata intact when changing sources. It controls permission to use
  trusted scriptlets.

## Current limits

The network path uses a block/allow decision. It does not implement filter-list
response rewriting or resource substitution for `$redirect`, `$csp`,
`$replace`, or `$header`. The cosmetic path supports CSS selectors and plain
CSS style actions. It skips removal actions and non-CSS procedural operators
such as `:has-text()` and `:upward()`. The Swift package still parses
`$removeparam` and `urlskip=` rules, but Chromium does not currently use that
navigation rewrite path.

The Swift app links the [NookAdblock XCFramework](../Nook/ThirdParty/AdblockRustFFI/)
for rule preparation and diagnostics. The Chromium recipe builds and links the
native matcher. A change to the serialization format or shared scriptlet
resources needs both the shell and the engine tested together. See the
[Chromium recipe](../Runtime/Chromium/README.md) for locked builds.

## Checks

```fish
swift test --package-path Packages/NookBlocker
python3 -B scripts/bark-check.py blocker
node scripts/check-scriptlet-globals.mjs
```

The package tests cover rule export and cache reuse, source-generation races,
and per-page exceptions. The shell harness exercises policy publication, context
readiness, and page admission through a simulated SDK bridge. The scriptlet
check verifies that the renderer defines the globals used by the bundled scriptlets. For end-to-end request,
cosmetic, and WebSocket coverage, use the
[guarded Chromium browser test runner](../Runtime/Chromium/README.md) with a
matching host-only build and the filter
`'BarcNativeBlockerBrowserTest.*:BarcNativeCosmeticCacheBrowserTest.*:BarcNativeCosmeticPrerenderBrowserTest.*:BarcNativeWebSocketBrowserTest.*'`.
