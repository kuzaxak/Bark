# Bark

Bark is a sidebar-first macOS browser. Spaces keep tabs and bookmark folders
together, and each space opens its pages in its assigned Chromium profile. The
window, sidebar, command palette and keyboard shortcuts are native Swift and
AppKit. Chromium renders the pages.

## Using Bark

Choose **Help → Bark Help** for a quick guide to the browser’s window controls.

- Switch spaces from the sidebar to return to the tabs for that space and profile.
- Open two pages in a split to work with both in one window. Select a pane to
  direct typing and page commands to it.
- Shift-click a link to open it in Peek. Escape returns focus to the source pane.
  Promote Peek to a split to keep the same live page and its edits.
- External links can open in a compact window. Choose **Open in Space** to move
  the page into the main window with its draft intact.

## Build and run

This branch builds a signed Intel developer app for macOS 15.5 and later.
Native Apple Silicon qualification and an official Bark download are pending.
The repository’s earlier releases are published under the Nook name.
[Earlier Nook releases](https://github.com/kuzaxak/Nook/releases)

Use a checkout containing `scripts/bark-check.py`, Xcode 26 with its Metal
toolchain, a local Developer ID Application signing identity, and the engine SDK
matching the checkout’s pin. The current runtime pin is for Intel. The engine
recipe also describes building an ARM64 SDK for qualification.
[Contributor setup](CONTRIBUTING.md#native-command-routing-and-signed-bark) ·
[Engine recipe](Runtime/Chromium/README.md#checkout-and-build)

From the repository root, supply the SDK directory or archive and your signing
identity. The build creates `build/Bark.app` from tracked sources and the SDK.

```fish
python3 scripts/bark-check.py engine --install --engine /path/to/Engine
set -lx BARK_SIGN_IDENTITY 'Developer ID Application: Your Name (TEAMID)'
python3 scripts/bark-check.py build
python3 scripts/bark-check.py smoke build/Bark.app
python3 scripts/bark-check.py launch build/Bark.app
```

The smoke test opens a local page and quits after the renderer acknowledges it.
The launch command leaves a separate disposable profile open for hands-on testing.
To keep a personal browsing session, open the signed app normally. Its local data
lives under `~/Library/Application Support/NookChromium`. Existing Nook users can
choose individual `.nookspace` files to import.

## How the browser fits together

The app owns the executable, menus and window layout. The engine owns Chromium
profiles, documents and renderer processes. A versioned C interface connects the
two. A shell change can use the pinned engine without rebuilding Chromium.
[App entry point](ChromiumApp) · [Swift window code](App/Chromium) ·
[Engine SDK](Packages/BarkEngine) · [Chromium integration](Runtime/Chromium)

The contributor guide lists package tests, AppKit command-routing checks and
signed-app walks for Peek, compact windows and installed updates.
[Contributing](CONTRIBUTING.md) · [Browser checks](Tests) ·
[Pull requests](https://github.com/kuzaxak/Nook/pulls)

## Origins and licensing

Bark is independently maintained and derives from Nook. The Nook name,
wordmark and original app icon are trademarks of Bain Gurley. The project code
uses GPL-3.0. Chromium and other third-party components retain their own licenses.
[Upstream Nook](https://github.com/nook-browser/Nook) · [License](LICENSE) ·
[Upstream trademark policy](TRADEMARK.md)
