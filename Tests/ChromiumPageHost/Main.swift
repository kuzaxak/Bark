// Licensed under GPL-3.0. See LICENSE.
#if BARK_CATALOG_FRAMEWORK
@testable import NookNativeShell
#endif
import AppKit
import BarcChromium
import NookWeb
import NookTabsCore
import NookBlocker
import NookSettings
import NookTweaks

/// Uses real package models and mocked C calls; no browser or URL is loaded.
@MainActor
private enum Native {
    static let first = UUID()
    static let second = UUID()
    static var profiles: [Int32: UUID] = [10: first]
    static var tabs: [Int32: [Int32]] = [10: [100]]
    static var groups: [Int32: UInt64] = [11: 2]
    static var activeTabs: [Int32: Int32] = [:]
    static var ending: Set<Int32> = []
    static var appLifetime: Set<Int32> = []
    static var nextTab: Int32 = 200
    static var pending: (barc_profile_window_callback?, UnsafeMutableRawPointer?)?
    static var openedFrom: [Int32] = []
    static var opens = 0
    static var creates = 0
    static var selected: Int32 = 10
    static var headerOwners: Set<Int32> = [10]
    private static var lastAttached: Int32 = 10
    static var attached: Int32 {
        get { lastAttached }
        set { lastAttached = newValue; headerOwners = newValue == 0 ? [] : [newValue] }
    }
    static var selectionCalls = 0
    static var windowCloses: [Int32] = []
    static var attachmentCalls = 0
    static var nativeCloses: [(Int32, Int32)] = []
    static var onObserve: ((Int32, Int32) -> Void)?
    static var onSelect: (() -> Int32)?
    static var onAttach: ((Int32) -> Int32)?
    static var observations: [UInt64: (BarcTabCallback?, UnsafeMutableRawPointer?, Int32, Int32)] = [:]
    static var nextObservation: UInt64 = 1
    static var pageHidden: [Int32: Int32] = [:]
    static var blankSnapshots = false
    static var rejectsObservation = false
    static var catalogAvailable = true
    static var onNavigate: ((Int32, Int32, String) -> Int32)?
    /// Web contents views supplied by each logical client.
    static var roots: [UInt64: UnsafeMutableRawPointer] = [:]
    static var pageViews: [Int32: NSView] = [:]
    static var viewless: Set<Int32> = []
    static var onPageView: ((Int32) -> Bool)?
    /// Calls to the old window's Peek card.
    static var peekCalls = 0
    /// Each Peek tab's source tab, in its own client.
    static var peekSources: [Int32: Int32] = [:]
    static var closesSelecting: [(tab: Int32, successor: Int32)] = []

    static func row(_ window: Int32) -> BarcDiscoveryWindow? {
        let group = groups[window] ?? 1
        let retained = appLifetime.contains { (groups[$0] ?? 1) == group }
        guard let profile = profiles[window], let list = tabs[window], !list.isEmpty || retained else { return nil }
        var row = BarcDiscoveryWindow()
        row.size = MemoryLayout<BarcDiscoveryWindow>.size
        row.window = window; row.physical_group = group
        row.active_tab = activeTabs[window].flatMap { list.contains($0) ? $0 : nil } ?? list.first ?? 0
        row.selected_client = selected; row.profile_kind = 0
        row.flags = (ending.contains(window) ? 32 : 0) | (list.isEmpty ? 128 : 0) | (retained ? 256 : 0)
        withUnsafeMutableBytes(of: &row.regular_profile_uuid) { buffer in
            for (i, byte) in profile.uuidString.utf8CString.enumerated() { buffer[i] = UInt8(bitPattern: byte) }
        }
        return row
    }
    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.profile_open_in_native_window = { owner, _, destination, callback, context in MainActor.assumeIsolated {
            precondition(destination == BARC_PROFILE_BLANK)
            Native.opens += 1; Native.openedFrom.append(owner); Native.pending = (callback, context)
        } }
        bridge.tab_create = { window, url, foreground in MainActor.assumeIsolated {
            precondition(String(cString: url!) == "about:blank" && foreground == 0)
            Native.creates += 1; Native.nextTab += 1; Native.tabs[window, default: []].append(Native.nextTab)
            return Native.nextTab
        } }
        bridge.window_tab_at = { window, index in MainActor.assumeIsolated {
            guard let list = Native.tabs[window], list.indices.contains(index) else { return 0 }
            return list[index]
        } }
        bridge.tab_copy_title = { window, tab, _, _ in MainActor.assumeIsolated {
            Native.tabs[window]?.contains(tab) == true && Native.profiles[window] != nil ? 1 : 0
        } }
        bridge.window_select = { window in MainActor.assumeIsolated {
            Native.selectionCalls += 1; Native.selected = window; return 1
        } }
        bridge.window_close = { window in MainActor.assumeIsolated {
            Native.windowCloses.append(window); Native.tabs[window] = nil; Native.profiles[window] = nil; return 1
        } }
        bridge.window_set_app_lifetime = { window in MainActor.assumeIsolated {
            guard Native.profiles[window] != nil else { return 0 }
            Native.appLifetime.insert(window); return 1
        } }
        bridge.window_set_page_hidden = { window, hidden in MainActor.assumeIsolated {
            guard Native.profiles[window] != nil else { return 0 }
            Native.pageHidden[window] = hidden; return 1
        } }
        bridge.window_attach_native_shell = { window, view in MainActor.assumeIsolated {
            Native.attachmentCalls += 1
            if let callback = Native.onAttach { return callback(window) }
            if view == nil { Native.headerOwners.remove(window) } else {
                Native.headerOwners.insert(window); Native.lastAttached = window
            }
            return 1
        } }
        bridge.window_native_shell_is_owned = { window, view in MainActor.assumeIsolated {
            guard let row = Native.row(window) else { return 0 }
            return Native.roots[row.physical_group] == view ? 1 : 0
        } }
        bridge.window_detach_native_shell_if_owned = { window, _ in MainActor.assumeIsolated {
            guard Native.headerOwners.contains(window) else { return 0 }
            Native.attachmentCalls += 1
            if let callback = Native.onAttach { return callback(window) }
            Native.headerOwners.remove(window); if Native.lastAttached == window { Native.lastAttached = 0 }; return 1
        } }
        bridge.tab_transfer_with_admission = { _, _, _, _, _ in 0 }
        bridge.window_new_peer_in_native_window = { _, _ in 0 }
        bridge.window_set_native_header = { _, _, _, _, _ in 0 }
        bridge.window_host_observe = { window, _, _ in MainActor.assumeIsolated { Native.profiles[window] != nil ? UInt64(window) : 0 } }
        bridge.window_host_unobserve = { _ in }
        bridge.tab_present_peek = { _, _, _, _, _, _, _ in MainActor.assumeIsolated { Native.peekCalls += 1; return 0 } }
        bridge.tab_is_peek_presented = { _, _, _, _, _, _, _ in MainActor.assumeIsolated { Native.peekCalls += 1; return 0 } }
        bridge.tab_hide_peek = { _, _, _, _, _, _, _ in MainActor.assumeIsolated { Native.peekCalls += 1; return 0 } }
        bridge.window_set_root_view = { window, view in MainActor.assumeIsolated {
            guard let view, let row = Native.row(window) else { return 0 }
            if let current = Native.roots[row.physical_group] { return current == view ? 1 : 0 }
            Native.roots[row.physical_group] = view
            return 1
        } }
        bridge.window_set_chrome = { window, _ in MainActor.assumeIsolated { Native.profiles[window] != nil ? 1 : 0 } }
        bridge.tab_native_view = { window, tab in
            let address: UInt = MainActor.assumeIsolated {
                guard Native.tabs[window]?.contains(tab) == true, !Native.viewless.contains(tab),
                      Native.onPageView?(window) != false else { return 0 }
                let view = Native.pageViews[tab] ?? NSView()
                Native.pageViews[tab] = view
                return UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque())
            }
            return UnsafeMutableRawPointer(bitPattern: address)
        }
        bridge.discovery_snapshot = { windows, capacity, tabRows, tabCapacity, output in MainActor.assumeIsolated {
            guard let output, output.pointee.size >= MemoryLayout<BarcDiscoverySnapshot>.size,
                  capacity == 0 || windows![0].size >= MemoryLayout<BarcDiscoveryWindow>.size,
                  tabCapacity == 0 || tabRows![0].size >= MemoryLayout<BarcDiscoveryTab>.size else {
                return Int32(BARC_DISCOVERY_READ_INVALID_ARGUMENT.rawValue)
            }
            guard Native.catalogAvailable else { return 2 }
            let rows = Native.profiles.keys.sorted().compactMap { Native.row($0) }
            let tabs = rows.flatMap { row in (Native.tabs[row.window] ?? []).map { tab in
                var entry = BarcDiscoveryTab()
                entry.size = MemoryLayout<BarcDiscoveryTab>.size; entry.window = row.window; entry.tab = tab
                if let source = Native.peekSources[tab] { entry.flags = BARC_DISCOVERY_TAB_PEEK.rawValue; entry.peek_source_tab = source }
                return entry
            } }
            output.pointee.window_count = rows.count; output.pointee.tab_count = tabs.count
            output.pointee.revision = 1
            guard capacity >= rows.count, tabCapacity >= tabs.count else { return 1 }
            for (index, row) in rows.enumerated() { windows?[index] = row }
            for (index, tab) in tabs.enumerated() { tabRows?[index] = tab }
            return 0
        } }
        bridge.tab_close_selecting = { observation, successor in MainActor.assumeIsolated {
            guard let entry = Native.observations[observation] else { return 0 }
            Native.closesSelecting.append((entry.3, successor)); return 1
        } }
        bridge.window_discovery_state = { window, output in MainActor.assumeIsolated {
            guard let output, output.pointee.size >= MemoryLayout<BarcDiscoveryWindow>.size,
                  let row = Native.row(window) else { return 0 }
            output.pointee = row; return 1
        } }
        bridge.discovery_observe = { _, _ in 1 }
        bridge.discovery_unobserve = { _ in }
        bridge.window_admit_discovered = { _, _ in 1 }
        bridge.window_private_session_uuid = { _, _, _ in 0 }
        bridge.tab_copy_launch_space = { _, _, _, _ in 0 }
        bridge.tab_application_pending = { _, _ in 0 }
        bridge.window_show = { _ in 0 }
        bridge.tab_observe = { window, tab, callback, context in MainActor.assumeIsolated {
            guard !Native.rejectsObservation else { return 0 }
            guard !Native.observations.values.contains(where: { $0.3 == tab }) else { return 0 }
            let token = Native.nextObservation; Native.nextObservation += 1
            Native.observations[token] = (callback, context, window, tab)
            (Native.blankSnapshots ? "about:blank" : "https://fixture.invalid/page-\(tab)").withCString {
                callback?(context, token, 0, window, tab, $0, nil, 0, 0)
            }
            Native.onObserve?(window, tab)
            return token
        } }
        bridge.tab_unobserve = { token in MainActor.assumeIsolated { Native.observations[token] = nil } }
        bridge.tab_observe_media = { _, _ in 1 }
        bridge.tab_observe_vault = { _, _ in 1 }
        bridge.tab_observe_vault_save = { _, _ in 1 }
        bridge.tab_observe_vault_passkeys = { _, _ in 1 }
        bridge.tab_enable_peek = { _, _ in 0 }
        bridge.blocker_set_tab_policy = { _, _, _, _, _ in 0 }
        bridge.tab_navigate = { window, tab, url in MainActor.assumeIsolated {
            guard let onNavigate = Native.onNavigate else { preconditionFailure("Host must not navigate during construction") }
            return onNavigate(window, tab, String(cString: url!))
        } }
        bridge.tab_go_back = { _, _ in 1 }; bridge.tab_go_forward = { _, _ in 1 }
        bridge.tab_reload = { _, _ in 1 }; bridge.tab_stop = { _, _ in 1 }
        bridge.tab_select = { window, tab in MainActor.assumeIsolated {
            Native.selectionCalls += 1
            if let callback = Native.onSelect { return callback() }
            Native.selected = window; Native.activeTabs[window] = tab; return 1
        } }
        bridge.tab_close = { window, tab in MainActor.assumeIsolated {
            Native.nativeCloses.append((window, tab)); return 1
        } }
        bridge.tab_capture_thumbnail = { _, _, _ in 0 }
        bridge.tab_clear_site_data = { _, _, _, _ in 0 }
        bridge.window_profile_uuid = { window, buffer, capacity in MainActor.assumeIsolated {
            guard let profile = Native.profiles[window] else { return 0 }
            let bytes = Array(profile.uuidString.utf8CString)
            if let buffer, capacity >= bytes.count {
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            }
            return bytes.count
        } }
        return bridge
    }

    static func opened(profile: UUID?, window: Int32 = 20, blank: Int32 = 200) {
        profiles[window] = profile ?? second; tabs[window] = [blank]
        let result = pending; pending = nil
        result?.0?(BARC_PROFILE_OK, window, result?.1)
    }

    static func emit(_ event: Int32, page: ChromiumPageNavigation, flags: UInt32 = 0) {
        if event == 7 && flags & 128 != 0 { ending.insert(page.nativeWindowID) }
        let entry = observations.first { $0.value.3 == page.nativeTabID }!
        entry.value.0?(entry.value.1, entry.key, event, page.nativeWindowID, page.nativeTabID, nil, nil, 0, flags)
    }
}

#if !BLOCKER_HOST_CHECKS
@MainActor private func lastPageKeepsItsWindow() throws {
    let profile = Profile(id: Native.first, engine: .chromium)
    let session = { PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "", isPrivate: false, controller: nil) }
    var shells: [NSView] = []
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    func mounted(client: Int32, tab: Int32, pages count: Int = 1, group: UInt64) -> (ChromiumNativePageHost, BrowserWindowState, [ChromiumPageNavigation]) {
        Native.profiles[client] = Native.first; Native.tabs[client] = [tab]; Native.groups[client] = group; Native.selected = client
        let host = ChromiumNativePageHost(bridge: Native.bridge)
        let window = BrowserWindowState(), shell = NSView()
        shells.append(shell)
        precondition(host.registerWindow(window, nativeOwner: client, shell: shell, initialBlankTab: tab))
        precondition(Native.appLifetime.contains(client), "A registered window belongs to the app")
        var pages: [ChromiumPageNavigation] = []
        for _ in 0..<count {
            _ = host.createPage(for: session(), profile: profile, in: window) { pages.append(try! $0.get() as! ChromiumPageNavigation) }
        }
        return (host, window, pages)
    }
    func close(_ page: ChromiumPageNavigation, client: Int32, event: Int32 = 7) {
        if event == 7 { Native.tabs[client]?.removeAll { $0 == page.nativeTabID } }
        Native.emit(event, page: page)
    }

    let (only, window, onlyPages) = mounted(client: 70, tab: 700, group: 70)
    let before = Native.creates, opens = Native.opens
    var outcomes: [PageCloseOutcome] = []
    only.closePage(onlyPages[0]) { outcomes.append($0) }
    precondition(Native.creates == before, "Closing the last page reserves no blank")
    close(onlyPages[0], client: 70)
    precondition(outcomes.isEmpty, "The close is answered after the native callback returns")
    drain()
    precondition(outcomes == [.closed])
    precondition((Native.row(70)?.flags ?? 0) & 128 != 0, "The emptied client stays")
    var next: ChromiumPageNavigation!
    _ = only.createPage(for: session(), profile: profile, in: window) { next = try! $0.get() as? ChromiumPageNavigation }
    precondition(next.nativeWindowID == 70 && Native.creates == before + 1 && Native.opens == opens,
                 "The next page goes into the emptied client")

    let (refusing, _, refusingPages) = mounted(client: 71, tab: 710, group: 71)
    let beforeRefused = Native.creates
    var refused: [PageCloseOutcome] = []
    refusing.closePage(refusingPages[0]) { refused.append($0) }
    close(refusingPages[0], client: 71, event: 8)
    precondition(refused == [.cancelled] && Native.creates == beforeRefused, "A refused close keeps its page and adds none")

    // Every page closing leaves the client for the app's next page.
    let (siblings, siblingWindow, siblingPages) = mounted(client: 72, tab: 720, pages: 2, group: 72)
    let beforeSiblings = Native.creates
    siblings.closePage(siblingPages[0]) { _ in }
    siblings.closePage(siblingPages[1]) { _ in }
    close(siblingPages[0], client: 72); close(siblingPages[1], client: 72); drain()
    precondition(Native.creates == beforeSiblings && Native.row(72) != nil)
    var refill: ChromiumPageNavigation!
    _ = siblings.createPage(for: session(), profile: profile, in: siblingWindow) { refill = try! $0.get() as? ChromiumPageNavigation }
    precondition(refill.nativeWindowID == 72)

    // Surplus empty clients close; one client per profile, and the selected one, stay.
    Native.profiles[75] = Native.first; Native.tabs[75] = []; Native.groups[75] = 70
    Native.profiles[76] = Native.second; Native.tabs[76] = []; Native.groups[76] = 70
    Native.profiles[77] = Native.second; Native.tabs[77] = []; Native.groups[77] = 70
    Native.selected = 77
    Native.windowCloses = []
    let stale = Native.bridge.readSnapshot()!
    Native.tabs[75] = [750]
    only.closeSurplusClients(in: window, snapshot: stale)
    precondition(Native.windowCloses == [76], "A client that gained a tab since the snapshot stays")
    Native.tabs[75] = []
    Native.windowCloses = []
    only.closeSurplusClients(in: window, snapshot: Native.bridge.readSnapshot()!)
    precondition(Native.windowCloses == [75], "Only unselected empty duplicates close")
    precondition(Native.row(70) != nil && Native.row(77) != nil)

    // A tab with a Peek over it in its own client closes the Peek first, its source shown next, then itself.
    for cancelled in [false, true] {
        let client: Int32 = cancelled ? 79 : 78
        let (pair, _, pairPages) = mounted(client: client, tab: client * 10, pages: 2, group: UInt64(client))
        let source = pairPages[0], peek = pairPages[1]
        Native.peekSources = [peek.nativeTabID: source.nativeTabID]
        Native.closesSelecting = []; Native.nativeCloses = []
        var outcomes: [PageCloseOutcome] = []
        pair.closePage(source) { outcomes.append($0) }
        precondition(Native.closesSelecting.map(\.tab) == [peek.nativeTabID] && Native.closesSelecting.first?.successor == source.nativeTabID
                     && !Native.nativeCloses.contains { $0.1 == source.nativeTabID } && outcomes.isEmpty,
                     "closing a tab with a Peek closes the Peek first, showing its source next: \(Native.closesSelecting)")
        if cancelled {
            close(peek, client: client, event: 8); drain()
            precondition(outcomes == [.cancelled] && !Native.nativeCloses.contains { $0.1 == source.nativeTabID },
                         "a cancelled Peek close keeps both")
        } else {
            close(peek, client: client); drain()
            precondition(Native.nativeCloses.contains { $0.1 == source.nativeTabID } && outcomes.isEmpty, "then the tab closes")
            close(source, client: client); drain()
            precondition(outcomes == [.closed])
        }
        Native.peekSources = [:]
    }

    for client: Int32 in [70, 71, 72, 75, 76, 77, 78, 79] { Native.profiles[client] = nil; Native.tabs[client] = nil }
    Native.appLifetime = []
    Native.selected = 10
    print("Chromium last-page checks PASS")
}
#endif

#if !BLOCKER_HOST_CHECKS
/// In host mode the window's root view holds the sidebar and the selected page; none of the old
/// path's sidebar, header or hidden-page calls reach Chromium.
@MainActor private func hostWindowPresents() throws {
    let profile = Profile(id: Native.first, engine: .chromium)
    Native.profiles[80] = Native.first; Native.tabs[80] = [800]; Native.groups[80] = 80; Native.selected = 80
    let page800 = FocusableHostPage(), page801 = FocusableHostPage()
    Native.pageViews = [800: page800, 801: page801]
    let attachments = Native.attachmentCalls
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    let window = BrowserWindowState(), shell: NSView = MoveCounter()
    precondition(host.registerWindow(window, nativeOwner: 80, shell: shell, initialBlankTab: 800))
    let root = shell.superview?.superview as? ChromiumWindowRoot
    precondition(root?.holdsSidebar(shell) == true, "A host window's root view holds the sidebar")
    var page: ChromiumPageNavigation!
    _ = host.createPage(for: PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "", isPrivate: false, controller: nil),
                        profile: profile, in: window) { page = try! $0.get() as? ChromiumPageNavigation }
    precondition(page.nativeWindowID == 80 && page.nativeTabID == 800)
    precondition(host.acceptNativeSelection(page, in: window), "The selected page is accepted")
    precondition(page800.isDescendant(of: root!) && root!.shownTab == 800, "The root shows the selected page")
    precondition(host.isNativeSelection(page, in: window), "The host window's client shows the sidebar and its page")
    Native.tabs[80] = [800, 801]
    var second: ChromiumPageNavigation!
    _ = host.createPage(for: PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "", isPrivate: false, controller: nil),
                        profile: profile, in: window) { second = try! $0.get() as? ChromiumPageNavigation }
    if second.nativeTabID != 801 { Native.tabs[80] = [800, second.nativeTabID]; Native.pageViews[second.nativeTabID] = page801 }
    precondition(host.selectPage(second, in: window), "Selecting another page succeeds")
    precondition(page801.isDescendant(of: root!) && page800.superview == nil, "The root shows the newly selected page instead")
    host.setPageHidden(true, in: window)
    precondition(page801.isHidden && Native.pageHidden[80] == nil, "An empty space hides the page in the root, not in Chromium")
    host.setPageHidden(false, in: window)
    precondition(!page801.isHidden)
    let bar = NSView()
    precondition(host.setPageHeader(bar, replacing: nil, height: 40, in: window) && bar.isDescendant(of: root!),
                 "The top bar goes into the root above the page")
    precondition(host.setPageHeader(nil, replacing: bar, height: 0, in: window) && bar.superview == nil)
    precondition(Native.attachmentCalls == attachments, "Host mode never attaches the sidebar through Chromium")
    let probe = shell as! MoveCounter
    let frame = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    frame.isReleasedWhenClosed = false
    frame.contentView = root
    defer { frame.contentView = nil }
    let moves = probe.moves
    precondition(moves == (1, 1), "the sidebar went into the root once, and the root into its window once: \(moves)")

    let opens = Native.opens
    Native.groups[81] = 80
    let page810 = NSView()
    Native.pageViews[810] = page810
    var other: ChromiumPageNavigation!
    _ = host.createPage(for: PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "", isPrivate: false, controller: nil),
                        profile: Profile(id: Native.second, engine: .chromium), in: window) { other = try? $0.get() as? ChromiumPageNavigation }
    precondition(Native.opens == opens + 1 && Native.openedFrom.last == 80, "a page of another profile joins that profile to the window")
    Native.opened(profile: Native.second, window: 81, blank: 810)
    precondition(other?.nativeWindowID == 81 && other?.nativeTabID == 810, "its page is the new client's")
    for _ in 0..<5 {
        precondition(host.selectPage(other, in: window) && Native.selected == 81 && root!.client == 81
                     && page810.isDescendant(of: root!) && page801.superview == nil && host.isNativeSelection(other, in: window),
                     "switching to the other profile's page shows it in the same window")
        precondition(host.selectPage(second, in: window) && Native.selected == 80 && root!.client == 80
                     && page801.isDescendant(of: root!) && page810.superview == nil && host.isNativeSelection(second, in: window), "and back")
    }
    precondition(Native.attachmentCalls == attachments, "a switch never attaches or detaches a shell")
    precondition(probe.moves == moves, "the sidebar never leaves its window across ten switches: \(probe.moves)")
    Native.viewless.insert(810)
    precondition(!host.selectPage(other, in: window) && Native.selected == 80 && page801.isDescendant(of: root!),
                 "a page with no view is not shown, and the selection goes back")
    precondition(probe.moves == moves && root!.holdsSidebar(shell), "the sidebar stays through the rollback: \(probe.moves)")
    Native.viewless.remove(810)

    try hostWindowPeek(host: host, window: window, root: root!, source: second, page: page, sources: (page801, page800))

    let third = UUID()
    Native.groups[82] = 80
    precondition(host.emptySpaceClient(in: window, profile: third, open: true) == nil && Native.opens == opens + 2
                 && Native.openedFrom.last == 80, "an empty space of a profile the window lacks opens that profile's client")
    Native.opened(profile: third, window: 82, blank: 820)
    precondition(Native.nativeCloses.last.map { $0 == (82, 820) } == true, "the new client's blank closes")
    Native.tabs[82] = []
    let selections = Native.selectionCalls
    precondition(host.emptySpaceClient(in: window, profile: third, open: true) == 82 && Native.selected == 82
                 && Native.selectionCalls == selections + 1, "the empty space's client is selected")
    host.setPageHidden(true, in: window)
    precondition(root!.shownTab == second.nativeTabID && page801.isHidden && Native.pageHidden[82] == nil,
                 "no page is placed for it, and the page shown is hidden")
    precondition(Native.attachmentCalls == attachments && probe.moves == moves, "the sidebar stays")
    host.setPageHidden(false, in: window)
    precondition(host.selectPage(second, in: window) && Native.selected == 80 && !page801.isHidden, "back to the first profile's page")
    Native.profiles[82] = nil; Native.tabs[82] = nil
    try hostWindowSplits(host: host, window: window, root: root!, pages: [page, second], other: other, sidebar: probe, profile: profile)
    Native.profiles[81] = nil; Native.tabs[81] = nil
    Native.pageViews = [:]; Native.viewless = []
    Native.profiles[80] = nil; Native.tabs[80] = nil; Native.appLifetime = []; Native.selected = 10
    print("Chromium host window checks PASS")
}

/// A Peek in a Bark window is laid out by the root: no call reaches the old window's card, the
/// generation names the pair and its two views, and hiding then showing again keeps the page.
@MainActor private func hostWindowPeek(host: ChromiumNativePageHost, window: BrowserWindowState, root: ChromiumWindowRoot,
                                       source: ChromiumPageNavigation, page: ChromiumPageNavigation,
                                       sources views: (source: NSView, page: NSView)) throws {
    precondition(host.selectPage(source, in: window) && views.source.isDescendant(of: root))
    let header = NSView(), actions = NSView(), calls = Native.peekCalls
    var dismissed = 0
    let generation = host.presentPeek(source: source, page: page, header: header, actions: actions,
                                      dismiss: { dismissed += 1 }, in: window)
    func shown(_ generation: UInt64, header: NSView = header, actions: NSView = actions) -> Bool {
        host.isPeekPresented(sourceWindow: source.nativeWindowID, sourceTab: source.nativeTabID, peekWindow: page.nativeWindowID,
                             peekTab: page.nativeTabID, generation: generation, header: header, actions: actions, in: window)
    }
    precondition(generation != 0 && shown(generation) && views.page.isDescendant(of: root) && views.source.isDescendant(of: root),
                 "the root shows the Peek over its source")
    precondition(Native.activeTabs[page.nativeWindowID] == page.nativeTabID,
                 "the Peek owns native commands even when there is no AppKit input event")
    precondition(!shown(generation &+ 1) && !shown(generation, header: NSView()) && !shown(generation, actions: NSView()),
                 "only that generation with those views is shown")
    precondition(!host.isPeekPresented(sourceWindow: source.nativeWindowID, sourceTab: page.nativeTabID, peekWindow: page.nativeWindowID,
                                       peekTab: source.nativeTabID, generation: generation, header: header, actions: actions, in: window),
                 "and only that pair")
    host.hidePeek(sourceWindow: source.nativeWindowID, sourceTab: source.nativeTabID, peekWindow: page.nativeWindowID, peekTab: page.nativeTabID,
                  generation: generation, header: header, actions: actions, in: window)
    precondition(!shown(generation) && views.page.superview == nil && views.source.isDescendant(of: root), "hiding takes the card down")
    precondition(host.selectPage(source, in: window))
    let again = host.presentPeek(source: source, page: page, header: header, actions: actions, dismiss: { dismissed += 1 }, in: window)
    precondition(again != 0 && again != generation && shown(again) && views.page.isDescendant(of: root), "shown again with the same page")
    host.hidePeek(sourceWindow: source.nativeWindowID, sourceTab: source.nativeTabID, peekWindow: page.nativeWindowID, peekTab: page.nativeTabID,
                  generation: generation, header: header, actions: actions, in: window)
    precondition(shown(again), "a stale generation hides nothing")
    host.hidePeek(sourceWindow: source.nativeWindowID, sourceTab: source.nativeTabID, peekWindow: page.nativeWindowID, peekTab: page.nativeTabID,
                  generation: again, header: header, actions: actions, in: window)
    precondition(!shown(again) && Native.peekCalls == calls && dismissed == 0, "no call reached the old window's card")
}

private final class FocusableHostPage: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor private func dividerKey(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: false, keyCode: 0)!
}

/// Counts how often the sidebar entered a superview and a window.
private final class MoveCounter: NSView {
    private(set) var moves = (superview: 0, window: 0)
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); moves.superview += 1 }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moves.window += 1 }
}

/// A Bark window lays out a split's panes itself from the model's record: no call reaches Chromium's
/// own split, the panes are the window's page views, and the record's focus is Chromium's selection.
@MainActor private func hostWindowSplits(host: ChromiumNativePageHost, window: BrowserWindowState, root: ChromiumWindowRoot,
                                         pages: [ChromiumPageNavigation], other: ChromiumPageNavigation, sidebar: MoveCounter,
                                         profile: Profile) throws {
    precondition(host.laysOutSplits(in: window), "a Bark window lays out its own split")
    let before = Native.tabs[80] ?? []
    Native.tabs[80] = before + [802]
    let page802 = NSView()
    Native.pageViews[802] = page802
    var third: ChromiumPageNavigation!
    _ = host.createPage(for: PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "", isPrivate: false, controller: nil),
                        profile: profile, in: window) { third = try! $0.get() as? ChromiumPageNavigation }
    if third.nativeTabID != 802 { Native.tabs[80] = before + [third.nativeTabID]; Native.pageViews[third.nativeTabID] = page802 }
    let thirdTab = third.nativeTabID
    let ids = [UUID(), UUID(), UUID()]
    let all: [ChromiumPageNavigation] = pages + [third!]
    let navigations = Dictionary(uniqueKeysWithValues: zip(ids, all))
    let views = [pages[0].nativeTabID, pages[1].nativeTabID, thirdTab].map { Native.pageViews[$0]! }
    precondition(host.needsInitialSplitRestore(in: window), "a fresh Bark window restores its saved split on first show")
    let record = SplitRecord(Array(ids.prefix(2)), orientation: .horizontal, dividers: [0.4])!
    precondition(host.applyHostSplit(record, navigations: navigations, activeItemID: ids[0], in: window, isCurrent: { true }),
                 "two panes are shown")
    precondition(root.split == .init(panes: [.init(client: 80, tab: pages[0].nativeTabID), .init(client: 80, tab: pages[1].nativeTabID)],
                                     vertical: false, dividers: [0.4], focused: pages[0].nativeTabID)
                 && views[0].isDescendant(of: root) && views[1].isDescendant(of: root), "the root shows both pages with the record's divider")
    precondition(Native.activeTabs[80] == pages[0].nativeTabID && Native.selected == 80, "the focused pane is Chromium's selection")
    precondition(!host.needsInitialSplitRestore(in: window), "shown once, it is not restored again")
    precondition(host.hostShowsSplit(record, navigations: navigations, activeItemID: ids[0], in: window), "the record and its focus are what shows")
    precondition(!host.hostShowsSplit(record, navigations: navigations, activeItemID: ids[1], in: window), "another focus is not")
    precondition(!host.hostShowsSplit(SplitRecord(Array(ids.prefix(2)), dividers: [0.6])!, navigations: navigations, activeItemID: ids[0], in: window),
                 "other dividers are not")
    precondition(!host.hostShowsSplit(nil, navigations: navigations, activeItemID: ids[0], in: window), "and no split is not")

    window.split = record
    var finished = 0
    root.dividerMoved = { index, position, length in
        host.moveSplitDivider(index, to: position, length: length, in: window)
    }
    root.dividerReleased = { finished += 1 }
    defer {
        root.dividerMoved = nil
        root.dividerReleased = nil
    }
    let frame = root.window!
    let horizontal = root.splitDividers[0]
    precondition(host.splitResizeRoot(in: frame) === root)
    precondition(horizontal.isAccessibilityElement() && horizontal.accessibilityRole() == .splitter)
    precondition(horizontal.isAccessibilitySelectorAllowed(#selector(NSView.accessibilityPerformIncrement)))
    precondition(horizontal.isAccessibilitySelectorAllowed(#selector(NSView.accessibilityPerformDecrement)))
    precondition(horizontal.accessibilityOrientation() == .vertical)
    precondition(horizontal.accessibilityValue() as? Double == 40)
    precondition((horizontal.accessibilityMinValue() as! Double) < 40 && (horizontal.accessibilityMaxValue() as! Double) > 40)
    root.focusSplitDivider()
    precondition(frame.firstResponder === horizontal)
    let leftWidth = views[0].frame.width
    horizontal.keyDown(with: dividerKey(String(UnicodeScalar(NSRightArrowFunctionKey)!)))
    precondition(window.split!.dividers[0] > 0.4 && views[0].frame.width > leftWidth && finished == 1)
    precondition(frame.firstResponder === horizontal && root.split?.focused == pages[0].nativeTabID)
    precondition(horizontal.accessibilityPerformDecrement() && finished == 2)
    precondition(abs(window.split!.dividers[0] - 0.4) < 0.0001)
    horizontal.keyDown(with: dividerKey("\u{1b}"))
    precondition(frame.firstResponder === views[0], "Escape returns focus to the selected page")

    let containers = views.prefix(2).map { $0.superview }
    precondition(host.applyHostSplit(record, navigations: navigations, activeItemID: ids[1], in: window, isCurrent: { true })
                 && root.split?.focused == pages[1].nativeTabID && Native.activeTabs[80] == pages[1].nativeTabID
                 && views.prefix(2).map { $0.superview } == containers,
                 "focusing the other pane selects its tab in Chromium and moves no pane")
    precondition(host.showSplitDividers(SplitRecord(Array(ids.prefix(2)), dividers: [0.7])!, in: window) && root.split?.dividers == [0.7]
                 && root.split?.focused == pages[1].nativeTabID, "a divider move re-frames the panes and keeps the focus")

    let three = SplitRecord(ids, orientation: .vertical)!
    precondition(host.applyHostSplit(three, navigations: navigations, activeItemID: ids[2], in: window, isCurrent: { true })
                 && root.split?.panes.count == 3 && root.split?.vertical == true && root.split?.focused == thirdTab
                 && views.allSatisfy { $0.isDescendant(of: root) }, "a third pane, stacked")

    window.split = three
    let stacked = root.splitDividers
    precondition(stacked.count == 2 && stacked[0].accessibilityOrientation() == .horizontal)
    root.focusSplitDivider()
    stacked[0].keyDown(with: dividerKey("\t"))
    precondition(frame.firstResponder === stacked[1], "Tab focuses the next divider")
    stacked[1].keyDown(with: dividerKey("\t", modifiers: .shift))
    precondition(frame.firstResponder === stacked[0], "Shift-Tab focuses the previous divider")
    let topHeight = views[0].frame.height
    stacked[0].keyDown(with: dividerKey(String(UnicodeScalar(NSDownArrowFunctionKey)!)))
    precondition(window.split!.dividers[0] > three.dividers[0] && views[0].frame.height > topHeight && finished == 3)
    precondition(root.split?.focused == thirdTab && Native.activeTabs[80] == thirdTab)
    let max = stacked[0].accessibilityMaxValue() as! Double
    for _ in 0..<20 { _ = stacked[0].accessibilityPerformIncrement() }
    precondition(abs((stacked[0].accessibilityValue() as! Double) - max) < 0.0001)
    precondition(!stacked[0].accessibilityPerformIncrement(), "Increment is unavailable at the upper bound")

    host.showModelSplit([ids[0], ids[1], ids[2], nil], vertical: true, dividers: [0.25, 0.5, 0.75], focused: ids[2],
                        page: { navigations[$0] }, in: window)
    precondition(root.split?.panes.last == .some(nil) && root.split?.panes.count == 4, "Add Split View's empty pane follows the model")
    precondition(host.splitResizeRoot(in: frame) == nil, "No resize command is offered while filling Add Split View")
    host.showModelSplit(three.itemIDs, vertical: true, dividers: three.dividers.map { CGFloat($0) }, focused: ids[2],
                        page: { navigations[$0] }, in: window)
    precondition(root.split?.panes.count == 3 && !root.split!.panes.contains(nil), "and goes with it")
    host.showModelSplit([ids[0], UUID()], vertical: false, dividers: [0.5], focused: ids[0], page: { navigations[$0] }, in: window)
    precondition(root.split?.panes.count == 3, "a pane whose page does not exist yet waits for the preparation")

    let otherID = UUID()
    var mixed = navigations
    mixed[otherID] = other
    let otherView = Native.pageViews[other.nativeTabID]!
    let sidebarMoves = sidebar.moves
    let pair = SplitRecord([ids[0], otherID], orientation: .horizontal, dividers: [0.5])!
    precondition(host.applyHostSplit(pair, navigations: mixed, activeItemID: ids[0], in: window, isCurrent: { true })
                 && root.split?.panes == [.init(client: 80, tab: pages[0].nativeTabID), .init(client: 81, tab: other.nativeTabID)]
                 && views[0].isDescendant(of: root) && otherView.isDescendant(of: root), "a split of two profiles' pages shows both")
    let mixedContainers = [views[0].superview, otherView.superview]
    for _ in 0..<3 {
        precondition(host.applyHostSplit(pair, navigations: mixed, activeItemID: otherID, in: window, isCurrent: { true })
                     && Native.selected == 81 && root.client == 81 && root.split?.focused == other.nativeTabID,
                     "focusing the other profile's pane selects its client")
        precondition(host.applyHostSplit(pair, navigations: mixed, activeItemID: ids[0], in: window, isCurrent: { true })
                     && Native.selected == 80 && root.client == 80 && root.split?.focused == pages[0].nativeTabID, "and back")
    }
    precondition([views[0].superview, otherView.superview] == mixedContainers && sidebar.moves == sidebarMoves,
                 "focus going between the profiles moves no pane and no sidebar")
    let four = SplitRecord([ids[0], otherID, ids[1], ids[2]], orientation: .vertical)!
    precondition(host.applyHostSplit(four, navigations: mixed, activeItemID: otherID, in: window, isCurrent: { true })
                 && root.split?.panes.compactMap { $0?.client } == [80, 81, 80, 80] && root.client == 81
                 && host.hostShowsSplit(four, navigations: mixed, activeItemID: otherID, in: window), "four panes of two profiles")
    host.showModelSplit(four.itemIDs, vertical: true, dividers: [0.2, 0.5, 0.8], focused: otherID, page: { mixed[$0] }, in: window)
    precondition(root.split?.dividers == [0.2, 0.5, 0.8] && root.split?.panes.count == 4, "the shell's link follows a mixed split")
    precondition(host.showSplitDividers(SplitRecord([ids[0], otherID, ids[1], ids[2]], orientation: .vertical, dividers: [0.1, 0.5, 0.9])!, in: window)
                 && root.split?.dividers == [0.1, 0.5, 0.9], "a divider move re-frames a mixed split")
    precondition(host.applyHostSplit(three, navigations: navigations, activeItemID: ids[2], in: window, isCurrent: { true })
                 && root.split?.panes.count == 3 && otherView.superview == nil && root.client == 80, "back to the three pages of one profile")

    let shown = root.split
    precondition(!host.applyHostSplit(record, navigations: navigations, activeItemID: ids[0], in: window, isCurrent: { false })
                 && root.split == shown, "a superseded request changes nothing")

    precondition(host.applyHostSplit(nil, navigations: navigations, activeItemID: ids[2], in: window, isCurrent: { true })
                 && root.split == nil && root.shownTab == thirdTab && views[2].isDescendant(of: root) && !views[0].isDescendant(of: root),
                 "ending the split leaves the focused page alone")
    precondition(host.hostShowsSplit(nil, navigations: navigations, activeItemID: ids[2], in: window))
    host.showModelSplit(nil, vertical: false, dividers: [], focused: ids[2], page: { navigations[$0] }, in: window)
    precondition(root.split == nil && root.shownTab == thirdTab, "no split in the model, none in the window")
    Native.tabs[80] = before; Native.pageViews[thirdTab] = nil
    print("Chromium Bark window split checks PASS")
}

@main
private enum HostChecks {
    @MainActor static func main() throws {
        let host = ChromiumNativePageHost(bridge: Native.bridge)
        let window = BrowserWindowState()
        let shell = NSView()
        precondition(host.registerWindow(window, nativeOwner: 10, shell: shell, initialBlankTab: 100))
        let firstProfile = Profile(id: Native.first, engine: .chromium)
        let secondProfile = Profile(id: Native.second, engine: .chromium)
        func session() -> PageSession {
            PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "", isPrivate: false, controller: nil)
        }
        var original: ChromiumPageNavigation!
        _ = host.createPage(for: session(), profile: firstProfile, in: window) {
            original = try! $0.get() as? ChromiumPageNavigation
        }
        precondition(original.nativeTabID == 100 && Native.creates == 0)
        precondition(host.canAdoptPage(original, in: window))
        // The empty-space panel covers the page Chromium keeps selected.
        let root = shell.superview?.superview as! ChromiumWindowRoot
        precondition(!root.pageHidden && root.holdsSidebar(shell))
        host.setPageHidden(true, in: window)
        precondition(root.pageHidden)
        host.setPageHidden(false, in: window)
        precondition(!root.pageHidden && host.laysOutSplits(in: window))
        host.setPageHidden(true, in: BrowserWindowState(id: window.id))
        precondition(!root.pageHidden, "Only the registered model window decides")
        let reservedHost = ChromiumNativePageHost(bridge: Native.bridge)
        let reservedWindow = BrowserWindowState(), reservedShell = NSView()
        precondition(!reservedHost.registerWindow(reservedWindow, nativeOwner: 10, shell: reservedShell))
        Native.profiles[12] = Native.first; Native.tabs[12] = [120]; Native.groups[12] = 12
        precondition(reservedHost.registerWindow(reservedWindow, nativeOwner: 12, shell: reservedShell, initialBlankTab: 120))
        let beforeReserved = Native.nextObservation
        if case .success = reservedHost.bindExistingPage(nativeWindow: 12, tab: 120, profile: firstProfile, in: reservedWindow) {
            preconditionFailure("Reserved app factory blank was stolen")
        }
        precondition(Native.nextObservation == beforeReserved && Native.nativeCloses.isEmpty)
        precondition(!host.canAdoptPage(original, in: BrowserWindowState(id: window.id)))
        precondition(Native.selected == 10 && Native.creates == 0 && Native.opens == 0)
        Native.tabs[10] = []
        precondition(!host.canAdoptPage(original, in: window), "Native membership must be current")
        Native.tabs[10] = [100]

        var cancelledDelivered = false
        let cancel = host.createPage(for: session(), profile: secondProfile, in: window) { result in
            if case .failure = result { cancelledDelivered = true }
        }
        var first: ChromiumPageNavigation!
        _ = host.createPage(for: session(), profile: secondProfile, in: window) { first = try! $0.get() as? ChromiumPageNavigation }
        var second: ChromiumPageNavigation!
        _ = host.createPage(for: session(), profile: secondProfile, in: window) { second = try! $0.get() as? ChromiumPageNavigation }
        cancel()
        precondition(Native.opens == 1 && first == nil)
        Native.opened(profile: nil)
        precondition(cancelledDelivered && first.nativeTabID == 200 && second.nativeTabID == 201 && Native.creates == 1)
        cancel() // Completion has already happened; cancellation is inert.

        // Existing app-owned adapters are reused without a second observer.
        let ownedCount = Native.observations.count
        let owned = try host.bindExistingPage(nativeWindow: 10, tab: 100, profile: firstProfile, in: window).get()
        precondition(owned.navigation === original && Native.observations.count == ownedCount)
        owned.finish(adopted: false); owned.finish(adopted: false)
        precondition(host.canAdoptPage(original, in: window))

        let beforeCreates = Native.creates, beforeOpens = Native.opens
        Native.tabs[10, default: []].append(contentsOf: [500, 501, 502])
        let firstAttempt = try host.bindExistingPage(nativeWindow: 10, tab: 500, profile: firstProfile, in: window).get()
        let nested = try host.bindExistingPage(nativeWindow: 10, tab: 500, profile: firstProfile, in: window).get()
        precondition(firstAttempt.navigation === nested.navigation)
        precondition(firstAttempt.navigation.state.url?.absoluteString == "https://fixture.invalid/page-500")
        nested.finish(adopted: true)
        firstAttempt.finish(adopted: false)
        firstAttempt.finish(adopted: false)
        precondition(host.canAdoptPage(nested.navigation, in: window), "Outer rejection killed a nested adoption")
        precondition(Native.observations.count == ownedCount + 1)

        let rejected = try host.bindExistingPage(nativeWindow: 10, tab: 501, profile: firstProfile, in: window).get()
        rejected.finish(adopted: false)
        precondition(!host.canAdoptPage(rejected.navigation, in: window))
        precondition(Native.observations.count == ownedCount + 1)
        let retry = try host.bindExistingPage(nativeWindow: 10, tab: 501, profile: firstProfile, in: window).get()
        precondition(retry.navigation !== rejected.navigation)
        retry.finish(adopted: false)
        precondition(Native.observations.count == ownedCount + 1)
        var abandoned: ChromiumExistingPageBinding? = try host.bindExistingPage(
            nativeWindow: 10, tab: 502, profile: firstProfile, in: window).get()
        precondition(abandoned != nil)
        abandoned = nil
        precondition(Native.observations.count == ownedCount + 1)
        precondition(Native.nativeCloses.isEmpty && Native.creates == beforeCreates && Native.opens == beforeOpens)

        // Current profile and owner are required even if an announcement was valid earlier.
        if case .success = host.bindExistingPage(nativeWindow: 20, tab: 500, profile: firstProfile, in: window) {
            preconditionFailure("A foreign native owner/profile was admitted")
        }
        Native.tabs[10]?.removeAll { $0 == 500 }
        precondition(!host.canAdoptPage(nested.navigation, in: window))
        Native.tabs[10]?.append(500)

        // Reject a transfer reported during initial observation, without closing it.
        Native.onObserve = { native, tab in
            guard tab == 503 else { return }
            Native.tabs[native]?.removeAll { $0 == tab }
            Native.profiles[11] = Native.first
            Native.tabs[11, default: []].append(tab)
            let entry = Native.observations.first { $0.value.3 == tab }!
            entry.value.0?(entry.value.1, entry.key, 6, 11, tab, nil, nil, 0, 0)
        }
        Native.tabs[10]?.append(503)
        if case .success = host.bindExistingPage(nativeWindow: 10, tab: 503, profile: firstProfile, in: window) {
            preconditionFailure("An initial owner transfer was ignored")
        }
        Native.onObserve = nil
        precondition(Native.nativeCloses.isEmpty && Native.observations.count == ownedCount + 1)

        Native.tabs[10]?.append(504)
        let pendingClose = try host.bindExistingPage(nativeWindow: 10, tab: 504, profile: firstProfile, in: window).get()
        var pendingOutcome: PageCloseOutcome?
        host.closePage(pendingClose.navigation) { pendingOutcome = $0 }
        pendingClose.finish(adopted: false)
        precondition(pendingOutcome == nil && Native.observations.count == ownedCount + 2)
        Native.emit(8, page: pendingClose.navigation)
        precondition(pendingOutcome == .cancelled && Native.observations.count == ownedCount + 1)

        // A live same-profile transfer must not carry this product sidebar
        // into an unregistered physical/native owner.
        func moveObservedPage(_ page: ChromiumPageNavigation, to owner: Int32) {
            for native in Array(Native.tabs.keys) { Native.tabs[native]?.removeAll { $0 == page.nativeTabID } }
            Native.tabs[owner, default: []].append(page.nativeTabID)
            let entry = Native.observations.first { $0.value.3 == page.nativeTabID }!
            page.state.url!.absoluteString.withCString {
                entry.value.0?(entry.value.1, entry.key, 6, owner, page.nativeTabID, $0, nil, 0, 0)
            }
        }
        moveObservedPage(nested.navigation, to: 11) // 11 has the same real profile UUID as 10.
        let beforeSelection = Native.selectionCalls, beforeAttachment = Native.attachmentCalls
        precondition(!host.selectPage(nested.navigation, in: window))
        precondition(Native.selectionCalls == beforeSelection && Native.attachmentCalls == beforeAttachment)
        precondition(Native.selected == 10 && root.holdsSidebar(shell))
        moveObservedPage(nested.navigation, to: 10)

        // Transfer during native selection is revalidated before any sidebar detach.
        Native.onSelect = {
            Native.onSelect = nil
            moveObservedPage(nested.navigation, to: 11)
            return 1
        }
        precondition(!host.selectPage(nested.navigation, in: window))
        precondition(Native.attachmentCalls == beforeAttachment && root.holdsSidebar(shell))
        moveObservedPage(nested.navigation, to: 10)

        // The normal supported same-model-window profile switch still mounts.
        precondition(host.selectPage(first, in: window))
        precondition(Native.selected == 20 && root.holdsSidebar(shell))
        precondition(host.selectPage(original, in: window))
        precondition(Native.selected == 10 && root.holdsSidebar(shell))

        // Runtime supersession must never restore the earlier native selection.
        Native.onSelect = {
            Native.onSelect = nil
            precondition(host.selectPage(first, in: window))
            return 0
        }
        precondition(!host.selectPage(original, in: window))
        precondition(Native.selected == 20 && root.holdsSidebar(shell))

        // A nested selection while resolving the web view supersedes the outer page.
        Native.onPageView = { _ in
            Native.onPageView = nil
            precondition(host.selectPage(second, in: window))
            return false
        }
        precondition(!host.selectPage(original, in: window))
        precondition(Native.selected == 20 && root.shownTab == second.nativeTabID && root.holdsSidebar(shell))

        // A missing view restores the previous selected client and its visible page.
        Native.viewless.insert(original.nativeTabID)
        precondition(!host.selectPage(original, in: window))
        precondition(Native.selected == 20 && root.shownTab == second.nativeTabID)
        Native.viewless.remove(original.nativeTabID)

        var outcomes: [PageCloseOutcome] = []
        host.closePage(first) { outcomes.append($0) }
        precondition(outcomes.isEmpty, "Dispatch acceptance is not CLOSED")
        precondition(!host.canAdoptPage(first, in: window), "Pending close is not adoption admission")
        Native.emit(8, page: first)
        precondition(outcomes == [.cancelled] && !first.isClosed)
        precondition(host.canAdoptPage(first, in: window))
        host.closePage(first) { outcomes.append($0) }
        Native.emit(7, page: first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(outcomes == [.cancelled, .closed] && first.isClosed)
        precondition(!host.selectPage(first, in: window))
        host.closePage(first) { outcomes.append($0) }
        precondition(outcomes == [.cancelled, .closed, .closed])
        // If all requests cancel during open, deliver exactly one real late
        // resource for package cleanup, not a successful imaginary close.
        let thirdProfile = Profile(engine: .chromium)
        var late: ChromiumPageNavigation!
        let cancelLate = host.createPage(for: session(), profile: thirdProfile, in: window) {
            late = try! $0.get() as? ChromiumPageNavigation
        }
        cancelLate()
        Native.opened(profile: thirdProfile.id, window: 30, blank: 300)
        precondition(late.nativeTabID == 300)
        var lateClosed = false
        host.closePage(late) { lateClosed = $0 == .closed }
        precondition(!lateClosed)
        Native.emit(7, page: late)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(lateClosed)

        // A dead original logical Browser is not reused as the shared root.
        Native.profiles[20] = nil; Native.tabs[20] = nil
        Native.profiles[30] = nil; Native.tabs[30] = nil
        let fourthProfile = Profile(engine: .chromium)
        var fourth: ChromiumPageNavigation!
        _ = host.createPage(for: session(), profile: fourthProfile, in: window) {
            fourth = try! $0.get() as? ChromiumPageNavigation
        }
        precondition(Native.pending != nil && Native.openedFrom.last != 20)
        Native.opened(profile: fourthProfile.id, window: 40, blank: 400)
        precondition(fourth.nativeTabID == 400)
        var ended: [PageCloseOutcome] = []
        host.closePage(fourth) { ended.append($0) }
        Native.emit(7, page: fourth, flags: 128)
        host.closePage(fourth) { ended.append($0) }
        precondition(ended == [.ownerEnded, .ownerEnded])
        precondition(!host.selectPage(fourth, in: window))
        Native.tabs[40]?.append(401)
        let beforeEnding = Native.nextObservation, beforeEndingCloses = Native.nativeCloses.count
        if case .success = host.bindExistingPage(nativeWindow: 40, tab: 401, profile: fourthProfile, in: window) {
            preconditionFailure("Known ending logical owner admitted another page")
        }
        precondition(Native.nextObservation == beforeEnding && Native.nativeCloses.count == beforeEndingCloses)
        try checkAuthoritativeGroups()
        try checkActualModelAdoption()
        print("Chromium page host checks passed")
        try lastPageKeepsItsWindow()
        try hostWindowPresents()
    }
}


#endif

private struct AdoptionNoTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

/// Exercise the concrete host with the actual package adoption path. All page
/// URLs are observer snapshots; the mocked navigation call rejects any load.
@MainActor
private func checkActualModelAdoption() throws {
    let suite = "NookExistingPageHost-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let settings = NookSettingsService(kagiTokenStore: AdoptionNoTokenStore(), userDefaults: defaults)
    let registry = WindowRegistry(), window = BrowserWindowState()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings, storageDirectory: directory.appendingPathComponent("Filters")),
        sponsorBlock: SponsorBlockManager(settings: settings), siteRouting: SiteRoutingManager(settings: settings),
        profileEngine: .chromium, directory: directory.appendingPathComponent("Tabs"))
    registry.register(window)
    registry.setActive(window)
    tabs.attach(window: window)
    let space = window.spaceID!, profile = tabs.profile(forSpace: space)!
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let shell = NSView()
    Native.groups[90] = 90
    Native.profiles[90] = profile.id
    Native.tabs[90] = [900, 901, 902]
    precondition(host.registerWindow(window, nativeOwner: 90, shell: shell, initialBlankTab: 900))
    let beforeCreates = Native.creates, beforeOpens = Native.opens, beforeCloses = Native.nativeCloses.count
    let outer = try host.bindExistingPage(nativeWindow: 90, tab: 901, profile: profile, in: window).get()
    var admitted: UUID?
    Native.onSelect = {
        Native.onSelect = nil
        let nested = try! host.bindExistingPage(nativeWindow: 90, tab: 901, profile: profile, in: window).get()
        admitted = tabs.adoptNativePage(nested.navigation, through: host, in: window, spaceID: space, select: false)
        nested.finish(adopted: admitted != nil)
        return 0 // The outer foreground selection is superseded/refused.
    }
    let refused = tabs.adoptNativePage(outer.navigation, through: host, in: window, spaceID: space, select: true)
    outer.finish(adopted: refused != nil)
    precondition(refused == nil && admitted != nil)
    precondition(tabs.session(for: admitted!)?.isUnloaded == false && host.canAdoptPage(outer.navigation, in: window))
    precondition(tabs.adoptNativePage(outer.navigation, through: host, in: window, spaceID: space, select: false) == admitted)
    precondition(tabs.session(for: admitted!)?.url.absoluteString == "https://fixture.invalid/page-901")
    precondition(Native.creates == beforeCreates && Native.opens == beforeOpens && Native.nativeCloses.count == beforeCloses)
    Native.emit(7, page: outer.navigation, flags: 128)
    precondition(tabs.tree.item(admitted!) != nil && tabs.session(for: admitted!)?.isUnloaded == true)
    if case .success = host.bindExistingPage(nativeWindow: 90, tab: 902, profile: profile, in: window) {
        preconditionFailure("Owner-ended event admitted another existing native page")
    }
    precondition(Native.creates == beforeCreates && Native.opens == beforeOpens && Native.nativeCloses.count == beforeCloses)
}

/// No production client mirror: every guard reads the fake native C row.
@MainActor
private func checkAuthoritativeGroups() throws {
    let profile = Profile(engine: .chromium)
    for owner: Int32 in [120, 121, 122] {
        Native.profiles[owner] = profile.id; Native.tabs[owner] = [owner * 10]
        Native.groups[owner] = 50
    }
    Native.selected = 120; Native.attached = 120
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    let window = BrowserWindowState(), shell = NSView()
    precondition(host.registerWindow(window, nativeOwner: 120, shell: shell))
    let binding = try host.bindExistingPage(nativeWindow: 121, tab: 1210, profile: profile, in: window).get()
    binding.finish(adopted: true)
    let page = binding.navigation
    precondition(host.canAdoptPage(page, in: window), "Extra same-profile client needs no registration")
    let selectCount = Native.selectionCalls, attachCount = Native.attachmentCalls
    precondition(!host.acceptNativeSelection(page, in: window))
    precondition(!host.isNativeSelection(page, in: window))
    precondition(Native.selectionCalls == selectCount && Native.attachmentCalls == attachCount)
    Native.selected = 121
    precondition(host.acceptNativeSelection(page, in: window))
    precondition(host.isNativeSelection(page, in: window) && Native.selectionCalls == selectCount)

    // A third client selected by native code while fetching a page wins.
    let root = shell.superview?.superview as! ChromiumWindowRoot
    let third = try host.bindExistingPage(nativeWindow: 122, tab: 1220, profile: profile, in: window).get()
    third.finish(adopted: true)
    Native.onPageView = { _ in
        Native.onPageView = nil
        Native.selected = 122
        return false
    }
    precondition(!host.selectPage(page, in: window) && Native.selected == 122)
    let beforeReflection = Native.selectionCalls
    precondition(host.acceptNativeSelection(third.navigation, in: window))
    precondition(Native.selectionCalls == beforeReflection && root.shownTab == 1220 && root.holdsSidebar(shell))

    Native.viewless.insert(page.nativeTabID)
    precondition(!host.selectPage(page, in: window))
    precondition(Native.selected == 122 && root.shownTab == 1220 && root.holdsSidebar(shell))

    // The engine can select an exact tab before its view becomes available.
    // The root still displays the former tab, so nil layout cannot be admitted.
    Native.selected = 121
    precondition(Native.row(121)?.active_tab == page.nativeTabID)
    precondition(!host.isNativeSelection(page, in: window), "Selection must include its mounted page view")
    let activeID = UUID()
    precondition(!host.hostShowsSplit(nil, navigations: [activeID: page], activeItemID: activeID, in: window))
    precondition(!host.hostShowsSplit(nil, navigations: [:], activeItemID: activeID, in: window))
    precondition(!host.applyHostSplit(nil, navigations: [activeID: page], activeItemID: activeID, in: window, isCurrent: { true }))
    precondition(host.needsInitialSplitRestore(in: window) && root.shownTab == 1220)

    Native.viewless.remove(page.nativeTabID)
    precondition(host.applyHostSplit(nil, navigations: [activeID: page], activeItemID: activeID, in: window, isCurrent: { true }))
    precondition(host.isNativeSelection(page, in: window) && !host.needsInitialSplitRestore(in: window))
    let displaced = NSView()
    displaced.addSubview(Native.pageViews[page.nativeTabID]!)
    precondition(root.shownTab == page.nativeTabID && !host.isNativeSelection(page, in: window),
                 "The tab ID alone does not prove that the root still holds the view")
    precondition(host.acceptNativeSelection(page, in: window))

    // Transfer inside one group reuses the same observation/adapter.
    func move(to owner: Int32) {
        Native.tabs[page.nativeWindowID]?.removeAll { $0 == page.nativeTabID }
        Native.tabs[owner, default: []].append(page.nativeTabID)
        let entry = Native.observations.first { $0.value.3 == page.nativeTabID }!
        entry.value.0?(entry.value.1, entry.key, 6, owner, page.nativeTabID, nil, nil, 0, 0)
    }
    move(to: 122)
    let reused = try host.bindExistingPage(nativeWindow: 122, tab: 1210, profile: profile, in: window).get()
    precondition(reused.navigation === page); reused.finish(adopted: true)
    precondition(host.canAdoptPage(page, in: window))

    // Death of the original logical client leaves the physical mount usable.
    Native.profiles[120] = nil; Native.tabs[120] = nil
    Native.selected = 122; Native.activeTabs[122] = page.nativeTabID
    precondition(host.acceptNativeSelection(page, in: window))
    let surviving = Native.bridge.readSnapshot()!
    precondition(!host.unregisterWindow(window, absentFrom: surviving))

    // A move to another physical group is neither destruction nor authority to
    // move product UI. Releasing the absent group must retain this observation.
    Native.profiles[123] = profile.id; Native.tabs[123] = [1230]; Native.groups[123] = 51
    move(to: 123)
    precondition(!host.canAdoptPage(page, in: window))
    let beforeForeign = Native.selectionCalls
    precondition(!host.selectPage(page, in: window))
    let destination = BrowserWindowState(), destinationShell = NSView()
    precondition(host.registerWindow(destination, nativeOwner: 123, shell: destinationShell))
    let rejectedMove = try host.bindExistingPage(nativeWindow: 123, tab: page.nativeTabID, profile: profile, in: destination).get()
    precondition(rejectedMove.navigation === page)
    rejectedMove.finish(adopted: false)
    precondition(!host.canAdoptPage(page, in: destination))
    let outerMove = try host.bindExistingPage(nativeWindow: 123, tab: page.nativeTabID, profile: profile, in: destination).get()
    let nestedMove = try host.bindExistingPage(nativeWindow: 123, tab: page.nativeTabID, profile: profile, in: destination).get()
    nestedMove.finish(adopted: true); outerMove.finish(adopted: false)
    precondition(host.canAdoptPage(page, in: destination), "Rejected outer move reverted nested admission")
    // Refusal after native close starts must not change ownership behind the
    // pending terminal callback. Cancellation leaves the same adapter reusable.
    host.closePage(page) { _ in }
    if case .success = host.bindExistingPage(nativeWindow: 123, tab: page.nativeTabID, profile: profile, in: window) {
        preconditionFailure("Pending close admitted a transfer")
    }
    Native.emit(8, page: page)
    precondition(host.canAdoptPage(page, in: destination))
    let beforeCleanupCloses = Native.nativeCloses.count
    Native.profiles[121] = nil; Native.tabs[121] = nil
    Native.profiles[122] = nil; Native.tabs[122] = nil
    precondition(host.unregisterWindow(window, absentFrom: Native.bridge.readSnapshot()!))
    precondition(!page.isClosed && Native.observations.values.contains { $0.3 == page.nativeTabID })
    precondition(Native.selectionCalls == beforeForeign && Native.nativeCloses.count == beforeCleanupCloses)
    Native.emit(7, page: page, flags: 128)
    precondition(page.isClosed)
}

#if BLOCKER_HOST_CHECKS
@MainActor private enum BlockerNative {
    struct Work { let window: Int32; let generation: UInt64; let callback: BarcBlockerCallback; let context: UnsafeMutableRawPointer? }
    static var work: [Work] = []
    static var revision: UInt64 = 0, generation: UInt64 = 0, required: UInt64 = 0
    static var enabled = false
    static var prepared: Set<Int32> = []
    static var policy: [(Int32, Int32, Int32)] = []
    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.blocker_publish_rules = { _, _, generation, callback, context in
            MainActor.assumeIsolated {
                guard let callback else { return 0 }
                BlockerNative.work.append(Work(window: 0, generation: generation, callback: callback, context: context)); return 1
            }
        }
        bridge.blocker_set_policy = { value, required, _, _ in MainActor.assumeIsolated { BlockerNative.enabled = value == 1; BlockerNative.required = required; return 1 } }
        bridge.blocker_prepare = { window, callback, context in MainActor.assumeIsolated {
            guard Native.profiles[window] != nil, let callback else { return 0 }
            if (window == 20 && !BlockerNative.prepared.contains(20)) ||
                (BlockerNative.enabled && BlockerNative.generation != BlockerNative.required) {
                BlockerNative.work.append(Work(window: window, generation: 0, callback: callback, context: context))
            } else {
                BlockerNative.prepared.insert(window)
                callback(context, BlockerNative.enabled ? BlockerNative.revision : 0, Int32(BARC_BLOCKER_READY.rawValue))
            }
            return 1
        } }
        bridge.blocker_set_tab_policy = { window, tab, oauth, _, _ in MainActor.assumeIsolated {
            BlockerNative.policy.append((window, tab, oauth)); return Native.tabs[window]?.contains(tab) == true ? 1 : 0
        } }
        bridge.blocker_state = { window, output in MainActor.assumeIsolated {
            guard let output, output.pointee.size >= MemoryLayout<BarcBlockerState>.size, Native.profiles[window] != nil else { return 0 }
            let size = output.pointee.size
            output.pointee = BarcBlockerState(); output.pointee.size = size; output.pointee.context_id = UInt64(window)
            output.pointee.publication_revision = BlockerNative.revision
            output.pointee.installed_revision = BlockerNative.prepared.contains(window) ? BlockerNative.revision : 0
            output.pointee.source_generation = BlockerNative.generation
            output.pointee.required_source_generation = BlockerNative.required
            output.pointee.ready = !BlockerNative.enabled || (BlockerNative.generation == BlockerNative.required && BlockerNative.prepared.contains(window)) ? 1 : 0
            output.pointee.requested_policy = BlockerNative.enabled ? 1 : 0
            return 1
        } }
        return bridge
    }
    static func finish(_ result: BarcBlockerResult) {
        let next = work.removeFirst()
        if result == BARC_BLOCKER_READY {
            if next.window == 0 { revision += 1; generation = next.generation }
            else { prepared.insert(next.window) }
        }
        next.callback(next.context, revision, Int32(result.rawValue))
        if next.window == 0, result == BARC_BLOCKER_READY {
            let ready = work.filter { $0.window != 0 && $0.window != 20 }
            work.removeAll { $0.window != 0 && $0.window != 20 }
            for request in ready {
                prepared.insert(request.window)
                request.callback(request.context, revision, Int32(BARC_BLOCKER_READY.rawValue))
            }
        }
    }
    static func emit(_ event: Int32, window: Int32, tab: Int32) {
        let entry = Native.observations.first { $0.value.2 == window && $0.value.3 == tab }!
        if event == 7 { Native.tabs[window]?.removeAll { $0 == tab } }
        entry.value.0?(entry.value.1, entry.key, event, window, tab, nil, nil, 0, 0)
    }
}

@MainActor private func blockerDrain() async {
    for _ in 0..<8 { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
}

@main private enum BlockerHostChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlockerHost-\(UUID())")
        let suite = "BlockerHost-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let filters = directory.appendingPathComponent("Filters")
        try FileManager.default.createDirectory(at: filters.appendingPathComponent(".etags"), withIntermediateDirectories: true)
        for (index, list) in FilterListManager.defaultLists.enumerated() {
            try (index == 0 ? "||ads.test^$script" : "! synthetic").write(to: filters.appendingPathComponent(list.filename), atomically: true, encoding: .utf8)
        }
        for list in FilterListManager.defaultLists + FilterListManager.optionalLists {
            try String(Date().timeIntervalSince1970).write(to: filters.appendingPathComponent(".etags/\(list.filename).checked"), atomically: true, encoding: .utf8)
        }
        let settings = NookSettingsService(kagiTokenStore: AdoptionNoTokenStore(), userDefaults: defaults,
            boostStore: .init(fileURL: directory.appendingPathComponent("Boosts.json")))
        settings.adBlockerEnabled = true; settings.adBlockerWhitelist = []; settings.enabledOptionalFilterLists = []
        let manager = ContentBlockerManager(settings: settings, storageDirectory: filters, nativeNetworkBlocking: true)
        defer { manager.setEnabled(false); settings.flushBoosts() }
        manager.setEnabled(true); await manager.activationTask?.value
        precondition(manager.networkRules != nil)
        let registry = WindowRegistry(), window = BrowserWindowState(), shell = NSView()
        let tabsDirectory = directory.appendingPathComponent("Tabs")
        var tree = TabTree(); tree.createSpace(id: Native.first, name: "Work", icon: "house", accentHex: "#123456", after: nil)
        tree.createSpace(id: Native.second, name: "Personal", icon: "house", accentHex: "#654321", after: Native.first)
        var device = DeviceState(); device.firstLaunchCompleted = true
        let store = TabStore(directory: tabsDirectory); store.save(tree, device); store.flush()
        let tabs = TabsController(settings: settings, windowRegistry: registry, blocker: manager,
            sponsorBlock: SponsorBlockManager(settings: settings), siteRouting: SiteRoutingManager(settings: settings),
            profileEngine: .chromium, directory: tabsDirectory)
        registry.register(window); registry.setActive(window); window.spaceID = Native.first
        tabs.attach(window: window, restoringSavedState: false)
        Native.profiles = [10: Native.first]; Native.tabs = [10: [100]]; Native.groups = [:]
        Native.selected = 10; Native.attached = 10; Native.ending = []; Native.observations = [:]
        Native.blankSnapshots = true; Native.onObserve = nil; Native.onSelect = nil; Native.onAttach = nil
        let blocker = ChromiumContentBlocker(bridge: BlockerNative.bridge, manager: manager)
        let host = ChromiumNativePageHost(bridge: Native.bridge)
        precondition(host.configureBlocker(blocker))
        precondition(!host.configureBlocker(blocker))
        let occupied = ChromiumNativePageHost(bridge: Native.bridge)
        precondition(occupied.registerWindow(window, nativeOwner: 10, shell: shell))
        precondition(!occupied.configureBlocker(blocker))
        tabs.nativePageHost = host
        precondition(host.registerWindow(window, nativeOwner: 10, shell: shell, initialBlankTab: 100))
        var loads: [(Int32, Int32, String)] = []
        Native.onNavigate = { loads.append(($0, $1, $2)); return 1 }
        let creates = Native.creates
        let id = tabs.open(url: URL(string: "https://ads.test/first")!, in: window, placement: .newTab)!
        await blockerDrain()
        let session = tabs.session(for: id)!
        precondition(loads.isEmpty && Native.creates == creates && session.navigation == nil && BlockerNative.work.filter({ $0.window == 0 }).count == 1)
        session.isOAuthFlow = true
        BlockerNative.finish(BARC_BLOCKER_READY); await blockerDrain()
        precondition(loads.count == 1 && loads[0].2 == "https://ads.test/first")
        precondition(BlockerNative.policy.last?.2 == 1 && session.navigation != nil)

        // Fresh-profile failure owns its untouched blank through a cancelled close.
        window.spaceID = Native.second
        let retryID = tabs.open(url: URL(string: "https://ads.test/second")!, in: window, placement: .background)!
        let retrySession = tabs.ensureSession(for: retryID)!, profile = tabs.profile(forSpace: Native.second)!
        var failures = 0, successes = 0
        _ = host.createPage(for: retrySession, profile: profile, in: window) { result in
            if case .failure = result { failures += 1 } else { successes += 1 }
        }
        precondition(Native.pending != nil)
        Native.opened(profile: profile.id, window: 20, blank: 200); await blockerDrain()
        precondition(BlockerNative.work.count == 1 && successes == 0 && loads.count == 1)
        BlockerNative.finish(BARC_BLOCKER_INVALID_RULES); await blockerDrain()
        precondition(failures == 1 && successes == 0 && Native.nativeCloses.last?.1 == 200)
        BlockerNative.emit(8, window: 20, tab: 200)
        let opens = Native.opens
        _ = host.createPage(for: retrySession, profile: profile, in: window) { result in
            if case .success(let page) = result { successes += 1; page.load(URL(string: "https://ads.test/retry")!) }
            else { failures += 1 }
        }
        precondition(Native.opens == opens && successes == 0)
        manager.setEnabled(false); precondition(blocker.synchronize())
        BlockerNative.emit(7, window: 20, tab: 200); await blockerDrain()
        precondition(Native.opens == opens && BlockerNative.work.map(\.window) == [20], "The retry reuses the emptied client")
        BlockerNative.finish(BARC_BLOCKER_READY); await blockerDrain()
        precondition(successes == 1 && failures == 1 && loads.count == 2)
        precondition(loads[1].0 == 20 && loads[1].2 == "https://ads.test/retry")
        // Cancellation before readiness never allocates or returns a page,
        // including the disabled-policy path.
        let beforeCancelCreates = Native.creates
        var cancelledCompletions = 0
        let cancel = host.createPage(for: retrySession, profile: profile, in: window) { result in
            guard case .failure = result else { preconditionFailure("Cancelled request escaped") }
            cancelledCompletions += 1
        }
        cancel(); await blockerDrain()
        precondition(cancelledCompletions == 1 && Native.creates == beforeCancelCreates && loads.count == 2)

        // Every makePage can fail observation. Keep the exact factory blank
        // reserved instead of dropping its Batch or claiming dispatched close.
        Native.ending.insert(20)
        Native.rejectsObservation = true
        var observeFailures = 0
        _ = host.createPage(for: retrySession, profile: profile, in: window) { result in
            guard case .failure = result else { preconditionFailure("Observation unexpectedly admitted") }
            observeFailures += 1
        }
        Native.opened(profile: profile.id, window: 22, blank: 220); await blockerDrain()
        precondition(observeFailures == 1 && Native.tabs[22] == [220] && loads.count == 2)
        let beforeRetry = Native.opens
        _ = host.createPage(for: retrySession, profile: profile, in: window) { _ in observeFailures += 1 }
        precondition(Native.opens == beforeRetry && observeFailures == 1)
        // Authoritative disappearance settles the old ownership claim; an
        // explicit request can proceed, with no timer or replacement factory.
        Native.profiles[22] = nil; Native.tabs[22] = nil
        Native.catalogAvailable = false
        _ = host.createPage(for: retrySession, profile: profile, in: window) { _ in observeFailures += 1 }
        precondition(Native.opens == beforeRetry && observeFailures == 1)
        Native.catalogAvailable = true
        Native.rejectsObservation = false
        _ = host.createPage(for: retrySession, profile: profile, in: window) { result in
            guard case .success = result else { preconditionFailure("Retry failed") }
            successes += 1
        }
        precondition(Native.opens == beforeRetry + 1)
        Native.opened(profile: profile.id, window: 23, blank: 230); await blockerDrain()
        precondition(successes == 2 && observeFailures == 3 && loads.count == 2)
        // A coalesced cohort owns every blank before its first callback. A
        // reentrant cancellation of its peer cannot return or load that page.
        let beforeBatchCreates = Native.creates
        var firstBatch = 0, secondBatch = 0
        var cancelSecond: (() -> Void)?
        _ = host.createPage(for: retrySession, profile: profile, in: window) { result in
            guard case .success = result else { preconditionFailure("First cohort page failed") }
            precondition(Native.creates == beforeBatchCreates + 2)
            firstBatch += 1; cancelSecond?()
        }
        cancelSecond = host.createPage(for: retrySession, profile: profile, in: window) { result in
            guard case .failure = result else { preconditionFailure("Cancelled cohort page escaped") }
            secondBatch += 1
        }
        await blockerDrain()
        precondition(firstBatch == 1 && secondBatch == 1 && loads.count == 2)
        // Even disabled blocking revalidates the actual registered model after
        // the async boundary; removing it cannot create or return a late page.
        let beforeRetirementCreates = Native.creates
        var retiredFailures = 0
        let firstProfile = tabs.profile(forSpace: Native.first)!
        _ = host.createPage(for: session, profile: firstProfile, in: window) { result in
            guard case .failure = result else { preconditionFailure("Retired model received a page") }
            retiredFailures += 1
        }
        registry.unregister(window.id)
        await blockerDrain()
        precondition(retiredFailures == 1 && Native.creates == beforeRetirementCreates && loads.count == 2)
        print("Chromium blocker host gate checks PASS")
    }
}
#endif
