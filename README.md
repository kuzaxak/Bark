# Bark

Bark is a sidebar-first macOS browser. Spaces keep tabs and bookmark folders
together, and each space opens its pages in its assigned Chromium profile. The
window, sidebar, command palette and keyboard shortcuts are native Swift and
AppKit. Chromium renders the pages.

## Install a signed build

Open the DMG for your Mac, drag **Bark** into **Applications**, eject the image,
and open Bark from Applications. Installing and running the signed app requires
only macOS. Bark keeps tabs, bookmarks and website
sign-ins in `~/Library/Application Support/NookChromium`. An existing Bark
profile on that Mac opens automatically. You can quit and reopen the app to
check that your session persists. On a Mac where you have only used Arc, Chrome
or the older WebKit-based Nook, Bark creates its own profile. To bring over
bookmarks and history from Arc or Chrome, choose **Bark → Import from Another
Browser…** and select the source. Sign in to websites again after importing.
You can keep **Nook.app** installed alongside **Bark.app**. To bring a space
you exported from Nook into Bark, choose **Settings → Spaces → Import Space**
and select the destination profile. The developer commands `bark-check.py smoke`
and `bark-check.py launch` use temporary profiles for testing.

This branch builds separate signed developer apps for Intel and Apple Silicon
on macOS 15.5 and later. Both have rendered a test page on native hardware.
An official Bark download is pending.
To check a signed app against its SDK and source, follow the
[verification guide](CONTRIBUTING.md#verify-a-signed-app-on-another-mac).
The repository’s earlier releases are published under the Nook name.
[Earlier Nook releases](https://github.com/kuzaxak/Bark/releases)

## Using Bark

Choose **Help → Bark Help** for a quick guide to the browser’s window controls.

- Switch spaces from the sidebar to return to the tabs for that space and profile.
  Opening a bookmark inside a collapsed folder shows the active bookmark beneath
  the folder. Selecting another tab hides that row again.
- Hold Control and press Tab to preview recent tabs. Press Shift+Tab while
  holding Control to move backward. Release Control to switch to the highlighted
  tab. A quick Control+Tab switches directly to the previous tab.
- In **Settings → General → Performance**, set **On Startup** to **Last Tab Only**
  to restore the pages shown in your saved windows and splits. Background tabs
  load when you select them.
- Choose **View → Hide Sidebar** or **Show Sidebar** for the current window.
  The menu shows your configured shortcut, Command+S by default.
- Choose **View → Show Toolbar** to move the address and navigation controls
  above the page. Choose **View → Hide Toolbar** to return them to the sidebar.
- Choose **View → Open Command Bar** and type a folder name. Use the full path
  beneath each result to distinguish folders with the same name. Select a
  result to reveal that folder in the sidebar. To search this profile’s
  browsing history, type `h`, a space, and your search term.
- To inspect an HTTPS certificate, open **Site Controls** beside the address and
  choose **Secure**. Click **Close** or press Command+W to return to the same tab.
- To change HTTPS warnings for a profile, choose **Settings → Profiles**, select
  the profile, then open **Secure Connections**. Chromium shows the connection
  settings for that profile.
- Open two pages in a split to work with both in one window. Select a pane to
  direct typing and page commands to it. For keyboard resizing, choose
  **View → Resize Split Panes**, use the arrow keys, and press Escape to
  return to the selected page.
- Shift-click a link, or focus it and press Shift+Return, to open it in Peek.
  Escape returns focus to the source pane. Use **Add Split View** (Control+Shift+= by
  default) to keep the preview and its edits in a second pane.
- External links can open in a compact window. Choose **Open in Space** to keep
  the page and its draft in the main window. For a site popup with a live
  opener, the default destination is the window and space of the opening tab.

### Website passwords

Open **Bark → Settings → Privacy → Passwords** and choose **Pawl Vault** under
**Password provider**. Open Pawl Vault, unlock the database that holds your
login, then choose **Check Connection** in Bark. The signed Pawl Vault 0.1.3
(build 10) test release accepts Bark. Build 7 accepts the legacy Nook client.

On a website with a matching vault entry, click the password field and select
your account from the Pawl menu beneath it. Bark asks Pawl for the password
or one-time code after you select an entry. The same unlocked vault serves all
Bark profiles. With Pawl build 10, open Pawl to save new logins or update
passwords.

On engines with exclusive provider support, Settings shows the **Active
provider**. Quit and reopen Bark after changing providers. With Pawl active,
locking or closing the vault pauses fills. Selecting **Chromium** and reopening
Bark restores access to Chromium's existing logins. Older engines show a
notice that Pawl and Chromium are both active.
[Provider integration design](openspec/changes/select-pawl-vault-provider/design.md)

### Connect an MCP client

To let a local tool control Bark, open **Settings → Developer**, turn on
**Developer Mode**, then enable **Allow agents to control this browser**.
Configure the tool with the HTTP endpoint `http://127.0.0.1:47823/mcp`
and a bearer token from the file shown in Settings. Bark identifies this
server as `bark-dev`. Turning off Browser Control stops the server.

To connect Bark’s assistant to an MCP server, open **Settings → AI** and use **MCP Servers**. Bark sends its app name and version when it connects.

### Sync bookmarks between Macs

In a Bark build with iCloud support, open **Settings → Spaces → iCloud Sync**
and choose **Enable Sync** on each Mac. Macs on the same iCloud account can
use its synced spaces directly. Choose **Favorites & Pinned** for a space to sync its bookmarks,
folders and their order. **Everything** also syncs its open tabs. **Off**
keeps a space local to that Mac if it has never been uploaded.

For two different iCloud accounts, use the controls in **Settings → Spaces**.

1. On the Mac joining the shared spaces, click **Copy** beside **Invite code**
   and send the code to the owner.
2. On the owner's Mac, choose **Invite with Code…** and paste the code.
   Send the resulting iCloud link back to the invited Mac.
3. On the invited Mac, paste the link into **Join Shared Sync…** and confirm.
   If this Mac already syncs spaces of its own, Bark asks whether to move them
   into the shared sync. **Join Without Moving** keeps them in their original
   account and turns off their sync on this Mac. Both accounts can edit the
   shared spaces.

The owner can look up an invite code from a different iCloud account in
Production. Issuing the link currently stops there. Bark's production
container still needs Apple's `cloudkit.share` record type.

Bark starts with a fresh iCloud dataset. Existing Nook cloud bookmarks and
invitations stay in Nook. Turning sync off on a Mac keeps its local bookmarks.
To bring a space over, choose **Settings → Spaces → Import Space**, open its
`.nookspace` file and choose the destination profile. Bark adds a new local
space. You can enable sync for it separately.

## Build and run

To compile the native window and sidebar without installing an engine, run
`python3 -B scripts/bark-check.py shell --arch arm64` or select `x86_64`.
This checks the Release app executable and Swift framework. Running the browser
also requires the matching Chromium SDK.

Use a checkout containing `scripts/bark-check.py`, Xcode 26 with its Metal
toolchain, a local Developer ID Application signing identity, and the engine SDK
matching the checkout’s pin for your Mac. The two developer SDKs share the same
public headers. For an optimized SDK, the publisher also supplies the receipt
digests in `Packages/BarkEngine`. With those files in your checkout, add
`--require-official` to the commands below to verify the optimized build.
[Contributor setup](CONTRIBUTING.md#native-command-routing-and-signed-bark) ·
[Engine recipe](Runtime/Chromium/README.md#checkout-and-build)

With the matching SDK archive, you can build and sign Bark from the app
sources alone. The example uses Python 3.13 to unpack the SDK archive.
Run these commands from the repository root and supply your SDK and signing
identity. The build creates `build/Bark.app`.

```fish
python3.13 scripts/bark-check.py engine --install --engine /path/to/BarkSDK.tar.gz
set -lx BARK_SIGN_IDENTITY 'Developer ID Application: Your Name (TEAMID)'
python3 scripts/bark-check.py build
python3 scripts/bark-check.py smoke build/Bark.app
python3 scripts/bark-check.py launch build/Bark.app
```

The `smoke` and `launch` commands create temporary profiles and remove them
when they finish. `smoke` quits after Chromium renders its local test page.
`launch` keeps the test window open until you quit. Sparkle update rehearsals
use a separately identified test app.

For everyday testing with your saved Bark data, open the installed Bark app from
Applications. A Finder launch uses your persistent profile under
`~/Library/Application Support/NookChromium`. To give someone the same signed
app, package it in a disk image.
Select the architecture used to build it.

```fish
python3 scripts/bark-check.py dmg build/Bark.app --arch arm64 --output ~/Downloads/Bark-macOS-arm64.dmg
```

In a signed build with a configured update feed, use **Bark → Check for Updates**
for a manual check. Under **Settings → General** you can also turn on automatic
checks and, when the build allows it, automatic downloads.

## How the browser fits together

The app owns the executable, menus and window layout. The engine owns Chromium
profiles, documents and renderer processes. The Swift shell compiles against
the public C headers in `Packages/BarkEngine`. Publishing the SDK supplies the
framework version for each architecture. At startup, Bark’s launcher opens
that exact version inside the app, checks its bridge version,
header digest and function table size, then passes the table to the Swift shell.
A change to the sidebar or command palette can use the same pinned engine.
Bark can import bookmarks and history from another browser on request.
Open **Help → Report a Problem…** to report a crash. On build 124 or if Bark quits, use the issue form in any browser. Include the approximate time, your time zone, what you clicked, and whether other tabs stayed open. **Help → Build Information** shows the app build, Chromium version and architecture. [Report a Bark problem](https://github.com/kuzaxak/Bark/issues/new?template=bug-report.yml)
[App entry point](ChromiumApp) · [Swift window code](App/Chromium) ·
[Engine SDK](Packages/BarkEngine) · [Chromium integration](Runtime/Chromium)

The contributor guide lists package tests, AppKit command-routing checks and
signed-app walks for Peek, compact windows and installed updates.
[Contributing](CONTRIBUTING.md) · [Browser checks](Tests) ·
[Pull requests](https://github.com/kuzaxak/Bark/pulls)

## Origins and licensing

Bark is independently maintained and derives from Nook. The Nook name,
wordmark and original app icon are trademarks of Bain Gurley. The project code
uses GPL-3.0. Chromium and other third-party components retain their own licenses.
[Upstream Nook](https://github.com/nook-browser/Nook) · [License](LICENSE) ·
[Upstream trademark policy](TRADEMARK.md)
