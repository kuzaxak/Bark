# Changelog

## Unreleased

### Moving from Nook to Bark on macOS

Bark 2.0.0 moves web pages to Chromium 158. The sidebar, spaces, split panes and command bar are native macOS controls. The release targets macOS 15.5 or later and has separate downloads for Apple Silicon and Intel.

Bark's upgrade from Nook uses the existing update feed and respects your automatic update preference. If Nook 1.5.4 has never checked for updates, choose **Check for Updates** once. The first update, Nook 1.5.5, selects the correct Bark download for your Mac. The next update replaces the application you normally open. To bring bookmarks and folders with you, choose **Export Space…** for each space in Nook before that second update, then import them in **Bark → Settings → Spaces**. Bark opens its existing Chromium profile if you have used it on this Mac. Otherwise it starts a new profile and you sign in to websites again.

Bark starts with its own iCloud data. Existing bookmarks, shared spaces and invitations stay in Nook. To bring a space across, export it as a `.nookspace` file and import it in Bark. In a Bark build with iCloud support, choose **Settings → Spaces → iCloud Sync → Enable Sync** on each Mac, then choose which spaces to sync. Until you enable sync, your bookmarks stay on that Mac.

### Added

- Google Calendar favorites show your next meeting from macOS Calendar, as in Arc: "now" under the icon while one runs, and "in 5m" when the next starts within the hour. Resting the pointer on the favorite shows a timeline from the current hour through the next six hours, side by side where events overlap, with a + for a new event; clicking an event opens its day in the favorite. Nook never asks for Calendar access on its own: the first card offers Connect Calendar, and says where to allow it in System Settings if it was turned down. Declined and all-day events never count as the next meeting
- A Join row under the favorites, as in Arc, from ten minutes before a meeting with a Google Meet, Zoom, Teams or Webex link until it ends: Join opens the call in a new tab, and the close button hides it until that meeting ends
- Gmail favorites show a red dot while the inbox has unread mail, as in Arc, and resting the pointer on one shows the newest unread email, with a + to compose; clicking the email opens it in the favorite. Nook reads Gmail's unread feed every two minutes with the favorite's own sign-in, sends it only Google's cookies, and keeps what it reads in memory only. Settings → Appearance → Show meetings and mail on favorites turns meetings and mail off and stops all reading; with Show previews when hovering favorites off, the Gmail and Calendar cards don't open, and the countdown, dot and Join row stay. Private windows and the Agent space never show them
- A mini player above the space bar, as in Arc: when a tab in the window, in any space, plays audio or video and you switch away from it, the bar shows the site's icon, Previous, Play/Pause, Next and Mute. It works on any site, with a player embedded in a page such as a YouTube or Spotify frame in an article, and with audio a page plays without showing a player. Previous and Next run the site's own media controls, or YouTube's buttons, and are greyed out where there are none, and clicking the icon goes back to the tab. The bar stays while the tab is paused, passes to a tab that starts playing, goes when the tab closes or leaves its media, and the × that appears on hover dismisses it. Mute shows when the page muted its own player too, and turns that back on. Muted clips looping on news pages, notification sounds such as Gmail's, private windows' tabs in other windows, the Agent space and Peek never show in it

### Fixed

- The space bar at the bottom of the sidebar shows which space is current, as in Arc: that space's icon or emoji is at full strength and the others are faded and grey, hovering one brings it part way back, and a swipe between spaces cross-fades them
- The sidebar button beside the window's traffic lights sits a little more than one light's gap past them, as in Arc. On macOS 26, whose lights are larger and further apart, it no longer touches the green button. On macOS 15 it stays where it was in the sidebar, and the hidden sidebar's floating panel now puts it there too instead of 8 points further right

## 1.5.4

A page with a certificate that is not valid, such as a device opened by its IP address, says why and can be opened anyway, as in Safari, instead of showing a blank tab.

### Fixed

- A page whose certificate isn't valid, such as a device opened by its IP address, shows This Connection Is Not Private with the reason instead of a blank tab, as in Safari: Show Details says why, and Visit This Website opens it after you confirm. The choice is remembered for that certificate, or until you quit in a private window, and a changed certificate warns again. Local network devices use the same page instead of a separate prompt

## 1.5.3

Spaces sync between your Macs through iCloud, also between Macs on different iCloud accounts, split view works as in Arc, USB security keys work for passkeys, and pages can translate with an AI model.

### Added

- OpenAI and Anthropic providers for the AI assistant: Settings → AI → Providers takes each one's API key, kept in the Keychain, and Models fetches the models it offers
- Pages can translate with an AI model instead of Apple's on-device translation: Settings → AI → Translation picks the provider and model, a few batches go at once, text the model fails on is translated on this Mac with a line saying why, and private windows always translate on this Mac. Translations are kept per profile for 30 days, so menus and footers a site repeats are not sent again; clearing history or website data, or Clear Translation Cache, removes them
- The sidebar's address shows "Translation Available" under the URL when a page is in another language, as in Arc; click it to translate
- Spaces can be exported to a `.nookspace` file and imported as a new space in any profile: Export Space… in a space's right-click menu or Settings → Spaces, Import Space… in the File menu or Settings → Spaces, or open the file from Finder; the file holds the space's look, favorites, pinned tabs and open tabs, never logins, cookies or history, only web links come in, and imported tabs load when you open them
- Press and hold Back or Forward to list the pages that way, as in Safari and Arc
- USB security keys such as a YubiKey work for passkeys: Nook talks to the key itself over FIDO2, as Chrome and Firefox do, asks for the key's PIN when the site or the key needs it, and lists the accounts when the key holds several; with Pawl Vault connected the prompt asks which to use. The prompt sits over its tab only, appears only for the page you are looking at, and after you cancel it the page cannot bring it back until it navigates. Settings → Privacy → Security keys (USB) turns it off
- Add Split View (⌃⇧=, "split" in the command bar, or New Split in the sidebar's + menu) puts an empty pane beside the current tab, or after the last pane of a split, with the command bar over it, as in Arc: pick a tab, or type an address or a search, to fill it; Escape leaves the window as it was
- Split view holds up to four tabs, side by side or stacked, as in Arc: each pane's split button moves it, adds an empty pane beside it, separates its tab from the split, or converts the split to vertical or horizontal, and every divider drags; a window reopens with its panes as they were
- Spaces sync between your Macs through iCloud, as in Arc: Settings → Spaces or a space's right-click menu sets each space to Off, Favorites & Pinned (its favorites, pinned tabs and folders) or Everything (also its open tabs, their order and the tabs opened from them), and existing spaces start Off. A space from another Mac joins the profile with the same name, or a new one by that name, and its tabs load when you open them. Logins, cookies, history, site data, Boosts, private windows and the Agent space never sync, names, addresses and titles are end-to-end encrypted with your iCloud keys, Off on one Mac leaves the space in iCloud and on your other Macs, and deleting a space deletes it from iCloud. Settings → Spaces shows the iCloud account, the last sync and any error, with Sync Now; a build not signed for iCloud says so and works as before
- Settings → Spaces → In iCloud lists every space the iCloud account holds, from any Mac: its profile, how many items it has, when it last changed and on which kind of Mac, such as iMac or MacBook Pro, and whether it is syncing here, Off on this Mac, arriving or has an error. Each one can be synced here at Favorites & Pinned or Everything, stopped here, or removed from iCloud, which deletes it on the Macs that sync it and leaves it Off on this one. A space whose copy on this Mac is Off stays as it is and shows as Off on this Mac instead of being passed over without a word
- Settings → Spaces → iCloud Sync shows the account ID this Mac syncs with, the same on every Mac signed in to that iCloud account, says that spaces sync only between such Macs, and has Copy Sync Report, which copies what the last sync did with each record by id, type, level and time, without names, addresses or titles
- Spaces sync between Macs on different iCloud accounts: the Mac that joins shows its invite code in Settings → Spaces → iCloud Sync, and on the sharing Mac Invite with Code… takes that code, invites that iCloud account and copies the link to send it. Only the accounts invited can join, and Settings lists them, by name or account ID, with whether they have joined, with Stop Sharing. On the other Mac, open the link or paste it in Join Shared Sync…, and Nook asks first, naming the owner: Join and Move moves the spaces that Mac already syncs in with theirs, Join Without Moving turns them Off there and leaves them to its own iCloud account. That Mac then syncs the shared spaces both ways, encrypted as before, and its other Macs on the same account are offered the same sync without a link. Their copy in its own iCloud account stays, marked as moved, so its other Macs on that account turn them Off and keep them; Remove Old Copy deletes it there, naming the Macs that synced it. Leave Shared Sync, or the owner stopping sharing, keeps every space on that Mac and turns it Off. The status says whether this Mac syncs its own account, shares it with how many people, or joined whose sync. Opening a link this Mac isn't invited to, or whose sharing stopped, shows an alert that says so, with Copy Invite Code for this Mac's invite code

### Fixed

- Cmd+W closes the tab instead of the window on Russian and other non-Latin keyboard layouts, and in any window with a tab; it closes the command bar or a Peek when one is open, as in Arc, a held Cmd+W stops at the empty window, and the File menu lists Close Tab and Close Window
- Shortcuts and menu commands act on the Peek when one is open, as in Arc: reload, Back and Forward, find, zoom, Copy URL, print, the address in the command bar, translate, mute, picture in picture, Web Inspector and the developer tools no longer reach the tab behind it
- Moving a space off a profile no other space uses no longer forces deleting it: Move and Keep Profile leaves it in Settings → Profiles with its logins, cookies and history, ready for a space or an imported .nookspace file to use again
- A link opened in the background (Command-click, middle click, Open Link in New Tab) loads at once and fills in its title and icon, as in Arc, instead of waiting until you select it
- The + menu at the bottom of the sidebar names each item beside its icon and shows the New Tab shortcut
- Right-click on Back or Forward lists the pages that way, nearest first, with their titles and icons, instead of the toolbar's Icon and Text menu
- A two-finger swipe over the sidebar switches spaces whatever System Settings → Trackpad → Swipe between pages is set to; a mouse's tilt wheel or Shift-scroll moves one space per flick, over the tab list too
- A sidebar swipe cut short, by switching apps or clicking mid-swipe or by resting the fingers, settles back on its space instead of leaving Nook ignoring clicks until the next scroll
- Turning Developer Mode off (Control-D, the site controls or Settings) closes the right panel in every window where it showed Console, Network, Blocker or Perf; the Agent tab stays open
- A Web Inspector docked to a page stays beside it when the window resizes, the Developer Mode bar or right panel opens, or you switch tabs or split and come back, and the page fills its pane again when the inspector closes or undocks, instead of leaving a grey band below it
- The AI assistant says when a reply stops at Max Output Tokens instead of showing a blank or cut-off answer
- Settings → AI → Providers shows a Test result only under the provider that was tested, instead of under every provider, and clears it when that provider's key, address or switch changes
- Dragging a tab from the sidebar onto the page splits the window again, as in Arc: pressing a tab no longer selects it, so the dragged tab goes beside the current one, and the zone under the pointer says what the drop does: open on that half of the page, add beside the pane's nearer edge, move a pane there, or replace the pane once four show; text dragged inside a page no longer brings up the split zones

## 1.5.2

Links from other apps can open in the current space, as in Arc, and ClickUp lists scroll smoothly.

### Added

- Links from other apps can open in the current space instead of a mini window: Settings → Air Traffic Control, as in Arc

### Fixed

- ClickUp lists scroll smoothly: Nook rewrites one ClickUp chat style that made WebKit restyle the whole page for every new row

## 1.5.1

One-time codes from Pawl Vault, an offer to become the default browser, segment-by-segment address completion, editable word stops, and fixes for Peek, the command bar and deleted profiles.

### Added

- Pawl Vault one-time codes: click a verification-code field (or press ↓ in it) to pick an account with a one-time code, and Nook fills the current code, one digit per box when the site splits it; the form is never submitted and codes are never kept
- Default browser: Settings → General shows whether Nook is your default browser and makes it one with a click; Nook offers it at launch until you agree, and asks again 30 days after Not Now

### Changed

- The command bar's top row says where Return opens: this tab, a new tab below the named one, or the top of Tabs
- Word stops can be changed in Settings → General; history search splits words at the same characters as ⌥→ and Control-W, so `_` now stays inside a word
- The command bar's grey completion finishes only the host or path segment you are typing, as in Firefox; Return opens exactly the bold and grey text, typing `/` offers the next segment, ⌫ removes the grey text first, and deeper pages stay in the list

### Fixed

- Deleting a profile deletes its history and its command bar entries too
- Cmd+T opens the command bar over a Peek, as in Arc
- "What's new in Nook" opens this fork's release notes instead of upstream's

## 1.5.0

The first release of this fork: it builds for Intel and Apple silicon, updates from its own releases, and works more like Arc.

### Added

- Pawl Vault passwords and passkeys (Settings → Privacy → Passwords, off by default): pick an account under a login field, save a new password after signing in, sign in and register with passkeys; Nook checks the vault's code signature, keeps no credentials, and asks again only for saves or after 15 minutes
- Profiles pane, as in Arc (Settings → Profiles): add, rename and delete profiles; each sets its search engine, its download location (Downloads, a chosen folder, or ask every time starting where the last file went) and clears its website data
- Kagi Session Link: paste it in Settings → General and Kagi searches are signed in from every space; the token stays in the Keychain and out of history and tabs; Settings links to Kagi's page that shows it
- Search suggestions from Kagi when Kagi is the search engine
- Peek, as in Arc: links a page opens in a new tab and Shift-clicked links open over the page with back, forward, reload and Copy URL, and Close, Open as Tab and Open in Split View beside it; each tab keeps its own Peek and shows its icon in the sidebar (Settings → General → Peek)
- Split view, as in Arc: each pane has its own toolbar above the page; the split row has one menu for the pair; drop a dragged tab on the left or right half of the page to split
- Developer Mode, as in Arc: Ctrl+D turns it on for the current site; its bar replaces the toolbar, and its tools work from the bar with shortcuts (⌥⌘N Network, ⌥⌘G Performance, ⇧⌘2 Copy Screenshot, ⌥⌘P Portrait, ⌥⌘J Console); the lock opens Site Controls
- Cmd+Shift+D moves the address and navigation buttons between the sidebar and a toolbar above the page
- History index for the command bar: every visited page stays findable, ranked by frecency (Settings → Privacy → History); secret and tracking parameters (token, code, state, session, utm_*, fbclid, gclid) are dropped
- Command bar keys from zsh and fish: → or Ctrl+E takes the grey completion, ⌥→ takes one word, Ctrl+W and ⌥⌫ delete a word, Ctrl+U clears, Ctrl+N/P move
- Command bar: arrows no longer rewrite what you typed; Tab on a row narrows the field to its site; ⌘↩ opens in the background and keeps the bar open; ⇧↩ opens in split view
- Command bar rows show the title over a short address; hold ⌘ for the full one
- Command bar finds sidebar folders and renamed pinned links by word; Tab on a folder searches inside it, Return shows it in the sidebar
- Command bar scopes: `t ` lists tabs by space, `h ` or Ctrl+R lists history, `> ` lists actions; commands such as Copy Current URL, Pin to Space or Move to Space run from the bar with their shortcuts shown
- Command bar developer shortcuts: `loc` or `127` lists local servers one row per port; keywords such as `gh owner/repo` open their address (Settings → General → URL Shortcuts)
- New bindable actions: Pin to Space, Add to Favorites, Add to Folder, Move to Space, Rename Tab, Translate Page, Toggle Extension Library, Manage Extensions, Toggle Dark Mode, Toggle Developer Mode for Site
- Normal tabs not seen for 3 days are archived to Reopen Closed Tab (12 hours to 30 days in Settings → General → Tabs)
- Favorites are shared by spaces that use the same profile; opening one keeps you in the current space
- The space switcher shows each space's icon or initial instead of dots; choose the icon in Settings → Spaces
- Control-Tab shows up to 20 recent tabs in rows, with each tab's Peek; arrows, Ctrl+F/B/N/P and Return work while it is open
- Copy URL buttons in the sidebar, the toolbar and Peek, with ⇧⌘C in their tooltips

### Changed

- Universal build for Apple silicon and Intel, with its own bundle id
- Updates come from this fork's GitHub releases, signed with the fork's key; a version tag builds, signs with Developer ID, notarizes and publishes the release
- New tabs open ungrouped, below the selected tab's folder (Settings → General → Tabs); tabs opened from a pinned tab, a favorite or a folder land in Tabs; a run of background links keeps click order
- Option to stop nesting link tabs under their opener; Back still returns to the opener
- Duplicate Tab keeps the copy next to the original, in Pinned, Favorites or the same folder
- Tabs inside folders are bookmarks: closing one ends its page and keeps it, as a pinned tab does; Cmd+D bookmarks a tab or turns a bookmark back into a normal tab
- Rename as in Arc: double-click a tab or folder; the name starts selected, Enter or clicking away saves, Esc cancels
- Long tab and folder names fade at the end and show in full on hover; denser tab rows; the sidebar keeps the selected tab in view
- The command bar has a soft glow around it and gives the keyboard back to the page when it closes
- Toolbar text follows the page's colour, so titles stay readable on dark pages
- Settings: footers read from the leading edge, the update toggles work, clearer AI, history and shortcut rows, visible Kagi and URL Shortcut fields
- An empty Favorites area is one row tall

### Fixed

- The passkey sheet no longer takes the Return that submitted a sign-up form as Continue
- The quit confirmation no longer opens behind Settings
- The toolbar's Copy URL button stays under the pointer
- The iOS target builds again

## 1.4.0

### Added

- Space themes with colors, texture and light or dark
- Space icons and emoji
- Library: swipe past the first space
- Control-Tab switches between recent tabs
- Download history and previews
- Tidy Downloads
- Link previews on Shift-hover
- Boosts
- Portrait capture
- Developer Mode per site

### Changed

- Sidebar snaps to its default width, drag to hide
- Address bar edits in place
- Split view panes resize
- Tidier tab titles
- Pages scroll at 120 Hz
- Smoother space switching

### Fixed

- Microphone and camera for websites
- Bugs

### Thanks

- @Fenrur, @AbdulRehman-18, @autaut03, @QusaiiSaleem

## 1.3.0

### Added

- Profiles: spaces can share logins
- Ctrl+1 to 9 switch spaces, new Spaces menu
- Fuller page context menu
- Arc import keeps folders, order, favorites, colors and extensions

### Changed

- Next and Previous Space on Cmd+Opt+arrows
- Cleaner Shortcuts settings
- Runs on macOS 15.5 again

### Fixed

- MCP tools with OpenAI-compatible providers
- Bugs

### Thanks

- @zannagh, @QusaiiSaleem, @Fenrur, @sean0407

## 1.2.4

### Added

- Reddit feeds sort by Hot

### Fixed

- Bitwarden popup not opening
- Bugs

## 1.2.3

### Added

- Pull Requests live folder for GitHub
- Pull request card on GitHub favorites
- Seek bar and time on the PiP player

### Changed

- Command bar: top row is what Return does, better matching
- Air Traffic Control rules cover subdomains
- Floating video remembers its size and place
- Pages ask before opening another app

### Fixed

- PiP controls not showing until clicked
- Outside links to a routed site opening in the mini window
- Bugs

## 1.2.2

### Changed

- Faster Launch (up to 3x faster in testing)
- Background tabs use less memory
- Escape closes Peek
- Performance pass: memory, CPU and energy measured against other browsers

### Fixed

- Escape leaving full screen
- High CPU on some sites
- Pinned tab reset arrow moving on hover
- Bugs

## 1.2.1

### Added

- Return to Tab button on PiP and the media bar

### Changed

- Removed LiquidGlass styling. It did not match our calm browser philosophy.
- Improved Spaces switch speed and loading logic.
- Settings sidebar redesigned
- YouTube and Social Media merged into Tweaks

### Fixed

- Favicons not updating when a site changes its icon
- Crash when swiping to a space with a split view
- Bugs

## 1.2.0

### Added

- Links skip redirect pages
- Ad-blocked pages tell you they are blocked and allow you to access anyway
- Going back on a linked tab returns you to the previous tab
- Dragging PiP video into sidebar docks it

### Changed

- Liquid Glass styling
- PiP controls moved to page menu
- Sleeping tabs keep history

### Fixed

- YouTube detecting ad blocker
- X hiding posts with videos
- Password managers not working in Peek and mini
- Bugs

## 1.1.1

### Added

- Ask Nook, the AI chat in the sidebar, can run on Apple Intelligence on your Mac with no API key. It becomes the default when no other provider is set up. It answers questions about the page
- Links you open from a tab now nest under it, and new tabs open right below the tab you're on
- Back, forward and reload moved up beside the window buttons
- Liquid Glass throughout the sidebar, History and Downloads, Peek and Ask Nook
- PDF controls to zoom, print, save or open the file in Preview. Cmd+P prints any page, and a page's own print button works now
- Settings > Appearance > Hide border lets the page sit flush against the window (#370)

### Changed

- Peek opens on its own only for links from favorites and pinned tabs to another site. Option-click still peeks any link. On a regular tab, a link that would open a new window opens a new tab
- Peek is a little smaller, with close, split and new tab in one glass group on its left
- Peek and the sign-in window run like a normal tab now, with the full ad blocker, site tweaks, downloads and page dialogs
- Sidebar PiP only picks up a playing landscape video with sound, which keeps Shorts, reels and feed autoplay out. The player's title and progress bars no longer show in the sidebar
- The sidebar has a minimum width so back, forward and reload always fit
- Ask Nook shows its reply as it's written

### Fixed

- Videos on YouTube, Facebook and Instagram flashed black for single frames
- The top of a web page dragged the window, and text there couldn't be selected
- The window buttons now hide with the sidebar and stay hidden after leaving full screen
- Peek could draw the page cut off at the top and left
- Email, phone and other app links did nothing. They open in their app now
- The Settings button in Ask Nook and every Space Settings shortcut and menu item did nothing
- Gemini 3 failed after its first tool call, and GPT-5 and o-series models failed through the OpenAI-compatible provider
- Save Image could send the site's cookies along to wherever the image redirected
- In History, the time filter never refreshed and deleting a row lost your place. History older than 100 days is now cleared in every space; before, only the space Nook opened in was cleared
- In Downloads, Move to Trash opened Finder, and the download indicator could show the wrong download

## 1.1.0

Nook is being revived!

The bundle identifier has changed, so the updater in 1.0.x cannot install the latest version. Download the DMG and replace Nook in Applications to launch it.

The latest release requires macOS 26.

- Reworked and improved tab management
- Spaces and Profiles are simplified and combined now
- Enhanced the built-in adblocking system
- Added custom tweaks for YouTube and Social Media sites
- Improved split view
- PiP is more Arc-like (WIP, tested mainly on YouTube)
- Passkeys work through password managers. iCloud Keychain passkeys are still unavailable for now
- Performed multiple passes to harden security
