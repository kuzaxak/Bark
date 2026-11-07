import AppKit
import BarcChromium
import Foundation
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
import NookWeb

/// Actual catalog reader/coordinator/host/package models; only C calls are
/// synthetic. No browser, network request or native presentation is executed.
@MainActor private enum Native {
    static let work = UUID(), personal = UUID()
    static var windows: [Int32: BarcDiscoveryWindow] = [:]
    static var tabs: [BarcDiscoveryTab] = []
    static var shells: [Int32: UnsafeMutableRawPointer] = [:]
    static var observers: [UInt64: (ChromiumNavigationAPI.Callback?, UnsafeMutableRawPointer?, Int32, Int32)] = [:]
    static var nextToken: UInt64 = 10
    static var callback: BarcDiscoveryCallback?
    static var context: UnsafeMutableRawPointer?
    static var revision: UInt64 = 1
    static var attachments = 0
    static var membershipChecks = 0
    static var snapshotReads = 0
    static var admitted: [Int32] = []
    static var shown: [Int32] = []
    static var privateIDs: [Int32: UUID] = [:]
    static var privateIdentityReads = 0
    static var allowPrivateCreate = false
    static var rejectNextObservation = false
    static var onRejectedObserve: ((Int32, Int32) -> Void)?
    static var allowFailedPrivateClose = false
    static var failedPrivateCloses: [(Int32, Int32)] = []
    static var privateCreatedClients: [Int32] = []
    static var restoring = false
    static var restoredURLs: [String] = []
    static var onShow: ((Int32) -> Int32)?
    static var onCloseWindow: ((Int32) -> Int32)?
    static var savedRequests: [(UUID, ChromiumCreatedPageAdmission.SavedCallback?, UnsafeMutableRawPointer?)] = []
    static var privateCallback: (@convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void)?
    static var privateContext: UnsafeMutableRawPointer?
    static func copyPrivateID(_ window: Int32, _ output: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
        privateIdentityReads += 1
        guard windows[window]?.profile_kind == BARC_DISCOVERY_GUEST.rawValue, let id = privateIDs[window] else { return 0 }
        let bytes = id.uuidString.utf8CString
        if let output, capacity >= bytes.count { for (i, byte) in bytes.enumerated() { output[i] = byte } }
        return bytes.count
    }

    static func window(_ id: Int32, group: UInt64, profile: UUID?, kind: UInt32 = 0,
                       profileKind: UInt32 = 0, flags: UInt32 = 4, active: Int32) -> BarcDiscoveryWindow {
        var row = BarcDiscoveryWindow()
        row.window = id; row.physical_group = group; row.active_tab = active
        row.selected_client = id; row.kind = kind; row.profile_kind = profileKind; row.flags = flags
        if let profile {
            withUnsafeMutableBytes(of: &row.regular_profile_uuid) { buffer in
                for (index, byte) in profile.uuidString.utf8CString.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
            }
        }
        return row
    }
    static func tab(_ id: Int32, window: Int32, opener: Int32 = 0, flags: UInt32 = 0) -> BarcDiscoveryTab {
        var row = BarcDiscoveryTab()
        row.tab = id; row.window = window; row.opener_tab = opener; row.flags = flags
        return row
    }
    static func publish() {
        revision += 1
        callback?(context, 1, revision)
    }
    static var discovery: ChromiumDiscoveryAPI {
        ChromiumDiscoveryAPI(read: { windowRows, windowCapacity, tabRows, tabCapacity, size in MainActor.assumeIsolated {
            Native.snapshotReads += 1
            let rows = Native.windows.values.sorted { $0.window < $1.window }
            size?.pointee = BarcDiscoverySnapshot(revision: Native.revision, window_count: rows.count, tab_count: Native.tabs.count)
            guard windowCapacity >= rows.count, tabCapacity >= Native.tabs.count else { return 1 }
            for (index, row) in rows.enumerated() { windowRows?[index] = row }
            for (index, row) in Native.tabs.enumerated() { tabRows?[index] = row }
            return 0
        } }, state: { id, result in MainActor.assumeIsolated {
            guard let row = Native.windows[id] else { return 0 }
            result?.pointee = row; return 1
        } }, observe: { callback, context in MainActor.assumeIsolated {
            Native.callback = callback; Native.context = context; return 1
        } }, unobserve: { _ in MainActor.assumeIsolated {
            Native.callback = nil; Native.context = nil
        } }, admit: { window, view in MainActor.assumeIsolated {
            guard Native.shells[window] == view else { return 0 }
            Native.admitted.append(window)
            Native.windows[window]?.flags &= ~UInt32(BARC_DISCOVERY_AWAITING_ADMISSION.rawValue)
            return 1 // Preserve the caller's inactive/active intent.
        } }, privateUUID: { window, output, capacity in MainActor.assumeIsolated {
            Native.copyPrivateID(window, output, capacity)
        } }, show: { window in MainActor.assumeIsolated {
            precondition(Native.shells[window] != nil && Native.windows[window]?.selected_client == window)
            Native.shown.append(window); return Native.onShow?(window) ?? 1
        } })
    }
    static var host: ChromiumPageHostAPI {
        ChromiumPageHostAPI(open: { _, _, _, _, _ in preconditionFailure("Discovery created a browser") },
            create: { client, _, foreground in MainActor.assumeIsolated {
                precondition(Native.allowPrivateCreate && Native.privateIDs[client] != nil && foreground == 0)
                let tab = Int32(9000 + Native.privateCreatedClients.count)
                Native.privateCreatedClients.append(client); Native.tabs.append(Native.tab(tab, window: client))
                return tab
            } },
            tabAt: { window, index in MainActor.assumeIsolated {
                let rows = Native.tabs.filter { $0.window == window }
                return rows.indices.contains(index) ? rows[index].tab : 0
            } }, tabTitle: { window, tab, _, _ in MainActor.assumeIsolated {
                Native.membershipChecks += 1
                return Native.tabs.contains { $0.window == window && $0.tab == tab } ? 1 : 0
            } }, selectWindow: { _ in preconditionFailure("Discovery focused a window") },
            closeWindow: { window in MainActor.assumeIsolated {
                guard Native.restoring, let close = Native.onCloseWindow else { preconditionFailure("Discovery closed native contents") }
                return close(window)
            } },
            attach: { window, view in MainActor.assumeIsolated {
                Native.attachments += 1; Native.shells[window] = view
                return Native.onAttach?(window) ?? 1
            } }, shellIsOwned: { window, view in MainActor.assumeIsolated {
                Native.windows[window] != nil && Native.shells[window] == view ? 1 : 0
            } }, detachIfOwned: { window, view in MainActor.assumeIsolated {
                guard view != nil, Native.windows[window] != nil, Native.shells[window] == view else { return 0 }
                Native.shells[window] = nil; return 1
            } })
    }
    static var navigation: ChromiumNavigationAPI {
        ChromiumNavigationAPI(observe: { window, tab, callback, context in MainActor.assumeIsolated {
            if Native.rejectNextObservation {
                Native.rejectNextObservation = false
                Native.onRejectedObserve?(window, tab); Native.onRejectedObserve = nil
                return 0
            }
            let token = Native.nextToken; Native.nextToken += 1
            Native.observers[token] = (callback, context, window, tab)
            (Native.restoring ? "about:blank" : "https://fixture.invalid/live-\(tab)").withCString {
                callback?(context, token, 0, window, tab, $0, nil, 0, 0)
            }
            return token
        } }, unobserve: { token in MainActor.assumeIsolated { Native.observers[token] = nil } },
            navigate: { window, tab, url in MainActor.assumeIsolated {
                precondition(Native.restoring && Native.tabs.contains { $0.window == window && $0.tab == tab })
                Native.restoredURLs.append(String(cString: url!)); return 1
            } },
            back: { _, _ in 1 }, forward: { _, _ in 1 }, reload: { _, _ in preconditionFailure("Existing page was reloaded") },
            stop: { _, _ in preconditionFailure("Existing page was stopped") },
            select: { window, tab in MainActor.assumeIsolated {
                precondition(Native.restoring && Native.tabs.contains { $0.window == window && $0.tab == tab })
                Native.windows[window]?.active_tab = tab; return 1
            } },
            close: { window, tab in MainActor.assumeIsolated {
                precondition((Native.allowFailedPrivateClose && Native.privateIDs[window] != nil || Native.restoring) && Native.tabs.contains { $0.window == window && $0.tab == tab })
                Native.failedPrivateCloses.append((window, tab)); Native.tabs.removeAll { $0.window == window && $0.tab == tab }; return 1
            } },
            captureThumbnail: { _, _, _ in 0 },
            clearSiteData: { _, _, _, _ in 0 }, profileUUID: { window, output, capacity in MainActor.assumeIsolated {
                guard let row = Native.windows[window], let profile = ChromiumDiscoveryAPI.profileID(row) else { return 0 }
                let bytes = profile.uuidString.utf8CString
                if let output, capacity >= bytes.count {
                    for (index, byte) in bytes.enumerated() { output[index] = byte }
                }
                return bytes.count
            } }, privateSessionUUID: { window, output, capacity in MainActor.assumeIsolated {
                Native.copyPrivateID(window, output, capacity)
            } })
    }
    static var onAttach: ((Int32) -> Int32)?
    static func move(_ tab: Int32, to window: Int32) {
        tabs.removeAll { $0.tab == tab }; tabs.append(Self.tab(tab, window: window, flags: 2))
        windows[window]?.active_tab = tab
        let entries = observers.filter { $0.value.3 == tab }
        for (token, entry) in entries {
            observers[token] = (entry.0, entry.1, window, tab)
            entry.0?(entry.1, token, 6, window, tab, nil, nil, 0, 0)
        }
    }
    static func end(_ window: Int32) {
        for (token, value) in observers.filter({ $0.value.2 == window }) {
            value.0?(value.1, token, 7, window, value.3, nil, nil, 0, 128)
            observers[token] = nil
        }
        windows[window] = nil
        tabs.removeAll { $0.window == window }
        shells[window] = nil
    }
}

private struct NoTokens: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@main private enum Checks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcCatalog-\(UUID())")
        let suite = "BarcCatalog-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var tree = TabTree()
        tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
        tree.createSpace(id: Native.personal, name: "Personal", icon: "house", accentHex: "#123456", after: Native.work)
        var device = DeviceState(); device.firstLaunchCompleted = true
        let store = TabStore(directory: root); store.save(tree, device); store.flush()
        let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
        let registry = WindowRegistry()
        var focusChanges = 0
        registry.onActiveWindowChange = { _ in focusChanges += 1 }
        let tabs = TabsController(settings: settings, windowRegistry: registry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
        let host = ChromiumNativePageHost(api: Native.host, navigationAPI: Native.navigation, discoveryAPI: Native.discovery)
        tabs.nativePageHost = host
        registry.onWindowClose = { [weak tabs, weak registry] id in
            guard let tabs, let registry else { return }
            if let window = registry.windows[id], tabs.device.windows.contains(where: { $0.id == id }) { tabs.detach(window: window) }
        }
        var shellCount = 0
        var utilities: Set<Int32> = [80]
        let admission = ChromiumCreatedPageAdmission(api: Native.discovery, host: host, tabs: tabs,
            registry: registry, isUtility: { utilities.contains($0) }, makeShell: { _ in shellCount += 1; return NSView() })
        let catalog = ChromiumWindowCatalog(api: Native.discovery)
        catalog.onSnapshot = { admission.apply($0) }
        precondition(catalog.start())

        // Origin alone never blacklists future non-factory tabs in a window.
        Native.windows[10] = Native.window(10, group: 1, profile: Native.work, flags: 1 | 4 | 8 | 16, active: 101)
        Native.tabs = [Native.tab(100, window: 10, flags: 2), Native.tab(101, window: 10), Native.tab(102, window: 10), Native.tab(103, window: 10)]
        Native.publish()
        precondition(shellCount == 1 && registry.windows.count == 1)
        let first = registry.allWindows.first!
        let selected = tabs.selectedSession(in: first)!
        precondition((selected.navigation as! ChromiumPageNavigation).nativeTabID == 101)
        precondition(Native.observers.values.allSatisfy { $0.3 != 100 })
        precondition(Native.admitted == [10] && registry.activeWindowId == first.id)
        let initialTree = tabs.tree, initialDevice = tabs.device, initialAttachments = Native.attachments
        let membershipsBeforeUnchanged = Native.membershipChecks
        Native.publish()
        precondition(Native.membershipChecks == membershipsBeforeUnchanged + 1,
                     "Stable background tabs must not each validate native membership")
        precondition(tabs.tree == initialTree && tabs.device == initialDevice && Native.attachments == initialAttachments)

        // A selected page in a new inactive physical window does not focus it.
        Native.windows[30] = Native.window(30, group: 3, profile: Native.work, flags: 4 | 16, active: 300)
        Native.tabs.append(Native.tab(300, window: 30))
        Native.publish()
        precondition(shellCount == 2 && registry.windows.count == 2 && registry.activeWindowId == first.id)
        let inactive = registry.allWindows.first { $0 !== first }!
        precondition((tabs.selectedSession(in: inactive)?.navigation as? ChromiumPageNavigation)?.nativeTabID == 300)

        // Extra logical clients share the existing product state/shell. Batch
        // opener ordering is resolved without another renderer or native focus.
        Native.windows[10]?.selected_client = 20
        Native.windows[10]?.flags &= ~UInt32(BARC_DISCOVERY_SELECTED_CLIENT.rawValue)
        Native.windows[20] = Native.window(20, group: 1, profile: Native.personal, flags: 1 | 4, active: 210)
        Native.tabs += [Native.tab(210, window: 20, opener: 200), Native.tab(200, window: 20)]
        Native.publish()
        precondition(shellCount == 2 && registry.windows.count == 2 && first.spaceID == Native.personal)
        let child = tabs.selectedSession(in: first)!
        let parent = tabs.sessions.first { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == 200 }!
        precondition(tabs.opener(of: child.itemID) == parent.itemID)

        // Settings, utility windows or another app can be key. Keep last
        // product routing; no repeated selection publication or native focus.
        let settledTree = tabs.tree, settledDevice = tabs.device, settledAttachments = Native.attachments
        for id in Array(Native.windows.keys) { Native.windows[id]?.flags &= ~UInt32(BARC_DISCOVERY_PHYSICAL_ACTIVE.rawValue) }
        Native.publish()
        precondition(registry.activeWindowId == first.id && focusChanges == 1)
        precondition(tabs.tree == settledTree && tabs.device == settledDevice && Native.attachments == settledAttachments)
        for id in Array(Native.windows.keys) where Native.windows[id]?.physical_group == 1 {
            Native.windows[id]?.flags |= UInt32(BARC_DISCOVERY_PHYSICAL_ACTIVE.rawValue)
        }
        Native.publish()

        // Popup/private/unknown/utility/factory-only groups remain untouched.
        Native.windows[50] = Native.window(50, group: 5, profile: Native.personal, kind: 1, active: 500)
        Native.windows[60] = Native.window(60, group: 6, profile: nil, profileKind: 2, active: 600)
        Native.windows[70] = Native.window(70, group: 7, profile: Native.work, flags: 4 | 8, active: 700)
        Native.windows[80] = Native.window(80, group: 8, profile: Native.personal, flags: 4 | 8, active: 800)
        Native.windows[90] = Native.window(90, group: 9, profile: UUID(), active: 900)
        Native.tabs += [Native.tab(500, window: 50), Native.tab(600, window: 60), Native.tab(700, window: 70, flags: 2),
            Native.tab(800, window: 80), Native.tab(900, window: 90), Native.tab(220, window: 20, opener: 500)]
        Native.publish()
        precondition(shellCount == 2 && registry.windows.count == 2)
        precondition(tabs.sessions.contains { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == 220 })
        precondition(!Native.admitted.contains(50) && !Native.admitted.contains(60) && !Native.admitted.contains(80))
        utilities.remove(80) // A released utility group's future non-factory page is eligible.
        Native.publish()
        precondition(shellCount == 3 && registry.windows.count == 3)

        // Native-origin cross-physical transfer preserves the exact modeled
        // session, adapter and item, including a previously claimed factory tab.
        let movedSession = selected
        let movedPage = movedSession.navigation as! ChromiumPageNavigation
        let movedItem = movedSession.itemID, savedTree = tabs.tree, observedCount = Native.observers.count
        Native.move(101, to: 30)
        Native.publish()
        precondition(tabs.session(for: movedItem) === movedSession && movedSession.navigation === movedPage)
        precondition(inactive.selectedItemID == movedItem && tabs.tree == savedTree)
        precondition(Native.observers.count == observedCount && movedPage.nativeWindowID == 30)

        // A last-tab source disappears while its live page enters a newly
        // created physical group. Destination admission precedes source detach.
        Native.windows[31] = Native.window(31, group: 31, profile: Native.work, flags: 4 | 16, active: 101)
        Native.move(101, to: 31)
        Native.end(30) // Only the remaining 300 resource ends, never the moved page.
        Native.publish()
        let destination = registry.allWindows.first { $0.selectedItemID == movedItem }!
        precondition(registry.windows[inactive.id] == nil && destination !== inactive)
        precondition(!tabs.device.windows.contains { $0.id == inactive.id })
        precondition(tabs.session(for: movedItem) === movedSession && !movedPage.isClosed)
        precondition(movedSession.navigation === movedPage && tabs.tree == savedTree)

        // A header callback transfers again before the outer snapshot can
        // publish. The next invalidation reconciles the actual owner, no focus,
        // new observation, reload or rollback to the obsolete destination.
        Native.windows[32] = Native.window(32, group: 32, profile: Native.work, flags: 4 | 16, active: 320)
        Native.tabs.append(Native.tab(320, window: 32))
        Native.windows[33] = Native.window(33, group: 33, profile: Native.work, flags: 4 | 16, active: 101)
        Native.move(101, to: 33)
        Native.end(31)
        Native.onAttach = { owner in
            guard owner == 33 else { return 1 }
            Native.onAttach = nil
            Native.move(101, to: 32)
            Native.windows[33] = nil
            return 0
        }
        Native.publish(); Native.publish()
        let finalOwner = registry.allWindows.first { $0.selectedItemID == movedItem }!
        precondition(finalOwner !== destination && movedPage.nativeWindowID == 32)
        precondition(tabs.session(for: movedItem) === movedSession && movedSession.navigation === movedPage)
        precondition(tabs.sessions.filter { $0.navigation === movedPage }.count == 1)
        precondition(tabs.tree.item(movedItem) == savedTree.item(movedItem))

        // Losing an original logical client does not destroy its physical group.
        let shellsBeforeLogicalEnd = shellCount
        Native.end(10); Native.publish()
        precondition(registry.windows[first.id] === first && shellCount == shellsBeforeLogicalEnd)
        let savedItems = Set(tabs.tree.items.keys)
        Native.end(30); Native.publish()
        precondition(registry.windows[inactive.id] == nil && Set(tabs.tree.items.keys) == savedItems)
        precondition(!tabs.device.windows.contains { $0.id == inactive.id })
        catalog.stop()
        precondition(Native.callback == nil)
        for window in Array(Native.windows.keys) { Native.end(window) }
        tabs.saveNow()
        try checkOnlySourceTransfer()
        try checkPrivateSessions()
        try checkSavedWindowRestoration()
        print("Chromium catalog admission checks passed")
    }
}

/// Source was the sole product window: admission must register the destination
/// before detach decides whether to retain the last saved window record.
@MainActor private func checkOnlySourceTransfer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcLastTransfer-\(UUID())")
    let suite = "BarcLastTransfer-\(UUID())", registry = WindowRegistry()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(api: Native.host, navigationAPI: Native.navigation, discoveryAPI: Native.discovery)
    tabs.nativePageHost = host
    registry.onWindowClose = { id in
        if let window = registry.windows[id], tabs.device.windows.contains(where: { $0.id == id }) { tabs.detach(window: window) }
    }
    let admission = ChromiumCreatedPageAdmission(api: Native.discovery, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    Native.windows[501] = Native.window(501, group: 501, profile: Native.work, active: 5010)
    Native.tabs = [Native.tab(5010, window: 501)]
    admission.apply(Native.discovery.readSnapshot()!)
    let source = registry.allWindows.first!, session = tabs.selectedSession(in: registry.allWindows.first!)!
    let page = session.navigation as! ChromiumPageNavigation, item = session.itemID
    precondition(registry.windows.count == 1 && tabs.device.windows.contains { $0.id == source.id })
    Native.windows[502] = Native.window(502, group: 502, profile: Native.work, active: 5010)
    Native.move(5010, to: 502); Native.end(501)
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(registry.windows.count == 1 && registry.windows[source.id] == nil)
    precondition(tabs.device.windows.count == 1 && !tabs.device.windows.contains { $0.id == source.id })
    precondition(tabs.selectedSession(in: registry.allWindows.first!) === session && session.navigation === page)
    precondition(tabs.tree.item(item) != nil && !page.isClosed)
    Native.end(502); tabs.saveNow()
}

/// Private identity/admission uses the same real host/model, never regular
/// metadata or persistent factories. Native calls remain deterministic stubs.
@MainActor private func checkPrivateSessions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcPrivateCatalog-\(UUID())")
    let suite = "BarcPrivateCatalog-\(UUID())", registry = WindowRegistry()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var tree = TabTree(); tree.createSpace(id: Native.work, name: "Work", icon: "house", accentHex: "#123456", after: nil)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(api: Native.host, navigationAPI: Native.navigation, discoveryAPI: Native.discovery)
    tabs.nativePageHost = host
    registry.onWindowClose = { id in if let window = registry.windows[id] { tabs.detach(window: window) } }
    let admission = ChromiumCreatedPageAdmission(api: Native.discovery, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    let a = UUID(), b = UUID()
    func add(_ window: Int32, session: UUID?, factory: Bool = false) {
        Native.windows[window] = Native.window(window, group: UInt64(window), profile: nil,
            profileKind: BARC_DISCOVERY_GUEST.rawValue, flags: 4 | (factory ? 8 : 16), active: window * 10)
        Native.tabs.append(Native.tab(window * 10, window: window, flags: factory ? 2 : 0))
        Native.privateIDs[window] = session
    }
    add(701, session: a); add(702, session: b); add(703, session: nil) // Stock Guest is not a Barc session.
    Native.windows[704] = Native.window(704, group: 704, profile: nil, profileKind: BARC_DISCOVERY_INCOGNITO.rawValue, active: 7040)
    Native.tabs.append(Native.tab(7040, window: 704))
    let originalTree = tabs.tree, originalDevice = tabs.device
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(registry.windows.count == 2 && tabs.privateWindows.count == 2)
    let source = tabs.privateWindows.first { $0.ephemeralProfile?.id == a }!
    let originalSession = tabs.selectedSession(in: source)!, page = originalSession.navigation as! ChromiumPageNavigation
    precondition(page.isPrivateSession && originalSession.isPrivate && originalSession.profile?.webKitDataStore == nil)
    add(711, session: a)
    Native.tabs[Native.tabs.firstIndex { $0.tab == 7110 }!].opener_tab = 7010
    admission.apply(Native.discovery.readSnapshot()!)
    let child = tabs.privateWindows.first { $0 !== source && $0.ephemeralProfile?.id == a }!
    precondition(child.ephemeralProfile === source.ephemeralProfile && registry.windows.count == 3)
    let item = originalSession.itemID
    Native.move(7010, to: 711); Native.end(701)
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(registry.windows[source.id] == nil && tabs.session(for: item) === originalSession)
    precondition(tabs.selectedSession(in: child) === originalSession && originalSession.navigation === page && !page.isClosed)
    registry.setActive(child)
    let privateTarget = admission.browserTarget(kind: 1, regularProfile: nil)
    precondition(privateTarget?.window == page.nativeWindowID && privateTarget?.regularProfile == nil)
    precondition(admission.browserTarget(kind: 0, regularProfile: a) == nil)

    precondition(tabs.tree == originalTree && tabs.device == originalDevice)
    // A user-created tab reuses this exact private client; any persistent
    // profile factory, native focus or navigation replay remains a hard trap.
    Native.allowPrivateCreate = true
    let pendingPage = PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "Private", isPrivate: true, controller: nil)
    var created: ChromiumPageNavigation?
    _ = host.createPage(for: pendingPage, profile: child.ephemeralProfile!, in: child) {
        guard case .success(let page) = $0 else { preconditionFailure("Private tab creation refused") }
        created = page as? ChromiumPageNavigation
    }
    precondition(created?.isPrivateSession == true && created?.profileID == a && Native.privateCreatedClients == [711])
    // Rejected observation releases only the just-created, still-owned private
    // blank. A tab moved to a foreign owner during rejection is untouched.
    Native.allowFailedPrivateClose = true
    Native.rejectNextObservation = true
    let expectedFailed = Int32(9000 + Native.privateCreatedClients.count)
    var failed = false
    _ = host.createPage(for: pendingPage, profile: child.ephemeralProfile!, in: child) {
        if case .failure = $0 { failed = true }
    }
    precondition(failed && Native.failedPrivateCloses.count == 1 &&
        Native.failedPrivateCloses[0].0 == 711 && Native.failedPrivateCloses[0].1 == expectedFailed)
    Native.rejectNextObservation = true
    var foreignTab: Int32 = 0
    Native.onRejectedObserve = { _, tab in
        foreignTab = tab
        let index = Native.tabs.firstIndex { $0.tab == tab }!
        Native.tabs[index].window = 702
    }
    failed = false
    _ = host.createPage(for: pendingPage, profile: child.ephemeralProfile!, in: child) {
        if case .failure = $0 { failed = true }
    }
    precondition(failed && Native.failedPrivateCloses.count == 1 &&
        Native.tabs.contains { $0.window == 702 && $0.tab == foreignTab })
    Native.allowFailedPrivateClose = false
    Native.allowPrivateCreate = false
    // Unchanged-owner state/commands do not repeat UUID lookup. A changed
    // owner must retain both the session UUID and private/regular identity kind.
    let reads = Native.privateIdentityReads
    for (token, entry) in Native.observers where entry.3 == page.nativeTabID {
        for _ in 0..<20 { entry.0?(entry.1, token, 6, 711, entry.3, nil, nil, 0, 0) }
    }
    precondition(page.goBack() && Native.privateIdentityReads == reads)
    Native.windows[713] = Native.window(713, group: 713, profile: a, active: 0)
    Native.privateIDs[713] = a // Matching text, wrong kind.
    Native.windows[714] = Native.window(714, group: 714, profile: nil, profileKind: BARC_DISCOVERY_GUEST.rawValue, active: 0)
    Native.privateIDs[714] = b // Correct kind, foreign session.
    for (token, entry) in Native.observers where entry.3 == page.nativeTabID {
        "https://foreign.invalid/".withCString {
            entry.0?(entry.1, token, 1, 713, entry.3, $0, nil, 0, 0)
            entry.0?(entry.1, token, 1, 714, entry.3, $0, nil, 0, 0)
        }
        precondition(page.nativeWindowID == 711 && page.state.url?.host != "foreign.invalid")
        entry.0?(entry.1, token, 6, 0, entry.3, nil, nil, 0, 0)
        precondition(page.nativeWindowID == 0 && !page.selectNativePage())
        let detachedReads = Native.privateIdentityReads
        entry.0?(entry.1, token, 6, 711, entry.3, nil, nil, 0, 0)
        precondition(page.nativeWindowID == 711 && Native.privateIdentityReads == detachedReads + 1)
    }

    // A cancelled async factory cannot publish its late blank/private product.
    let count = registry.windows.count
    var closed: [Int32] = []
    let cancel = admission.openPrivateWindow(open: { callback, pointer in MainActor.assumeIsolated {
        Native.privateCallback = callback; Native.privateContext = pointer
    } }, close: { id in closed.append(id); Native.end(id); return 1 }, canPresent: { true })
    cancel(); add(721, session: UUID(), factory: true)
    Native.privateCallback?(0, 721, Native.privateContext); Native.privateCallback = nil; Native.privateContext = nil
    precondition(closed == [721] && registry.windows.count == count)
    var cancelDuringAdmission: (() -> Void)?
    cancelDuringAdmission = admission.openPrivateWindow(open: { callback, pointer in MainActor.assumeIsolated {
        Native.privateCallback = callback; Native.privateContext = pointer
    } }, close: { id in closed.append(id); Native.end(id); return 1 }, canPresent: {
        cancelDuringAdmission?(); return true
    })
    add(723, session: UUID(), factory: true)
    Native.privateCallback?(0, 723, Native.privateContext); Native.privateCallback = nil; Native.privateContext = nil
    precondition(closed == [721, 723] && registry.windows.count == count)
    cancelDuringAdmission = nil
    // Synchronous completion is also valid; the exact factory blank is adopted
    // once rather than stolen by the ordinary catalog drain.
    add(722, session: UUID(), factory: true)
    _ = admission.openPrivateWindow(open: { callback, pointer in callback(0, 722, pointer) },
        close: { _ in preconditionFailure("Valid private factory was rejected") }, canPresent: { true })
    precondition(registry.windows.count == count + 1 && Native.shown == [722])
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(registry.windows.count == count + 1 && tabs.tree == originalTree && tabs.device == originalDevice)
    let childItem = originalSession.itemID
    Native.end(711)
    precondition(originalSession.navigation == nil && page.isClosed)
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(registry.windows[child.id] == nil && tabs.session(for: childItem) == nil)
    for id in Array(Native.windows.keys) { Native.end(id) }
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(registry.windows.isEmpty && tabs.tree == originalTree && tabs.device == originalDevice && Native.observers.isEmpty)
    tabs.saveNow()
    let saved = TabStore(directory: root).load()
    precondition(saved.tree == originalTree && saved.device == originalDevice)
}

@MainActor private func checkSavedWindowRestoration() throws {
    let root = URL(fileURLWithPath: "/private/tmp/BarcSavedWindows-\(UUID())", isDirectory: true)
    let suite = "BarcSavedWindows-\(UUID())", registry = WindowRegistry()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "house", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "house", accentHex: "#123456", after: Native.work)
    let first = UUID(), selected = UUID(), unloaded = UUID(), lateSelected = UUID(), splitOther = UUID()
    let rootURL = URL(string: "https://fixture.invalid/restored-root")!, selectedURL = URL(string: "https://fixture.invalid/restored-selected")!
    _ = try tree.createTab(id: first, url: rootURL, title: "Root", in: .tabs(spaceID: Native.work), after: nil)
    _ = try tree.createTab(id: selected, url: selectedURL, title: "Selected", in: .tabs(spaceID: Native.personal), after: nil)
    _ = try tree.createTab(id: unloaded, url: URL(string: "https://fixture.invalid/unloaded")!, title: "Unloaded", in: .tabs(spaceID: Native.personal), after: selected)
    _ = try tree.createTab(id: lateSelected, url: URL(string: "https://fixture.invalid/late-selected")!, title: "Late", in: .tabs(spaceID: Native.personal), after: unloaded)
    _ = try tree.createTab(id: splitOther, url: URL(string: "https://fixture.invalid/split-other")!, title: "Split", in: .tabs(spaceID: Native.work), after: first)
    let rootID = UUID(), extraID = UUID(), failedID = UUID(), lateID = UUID(), splitID = UUID()
    var device = DeviceState(); device.firstLaunchCompleted = true
    let split = SplitRecord([first, splitOther])!
    device.windows = [WindowRecord(id: rootID, spaceID: Native.work, selectedItemBySpace: [Native.work: first]),
        WindowRecord(id: extraID, spaceID: Native.personal, selectedItemBySpace: [Native.personal: selected]),
        WindowRecord(id: failedID, spaceID: Native.personal, selectedItemBySpace: [Native.personal: unloaded]),
        WindowRecord(id: lateID, spaceID: Native.personal, selectedItemBySpace: [Native.personal: lateSelected]),
        WindowRecord(id: splitID, spaceID: Native.work, selectedItemBySpace: [Native.work: first], split: split)]
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(api: Native.host, navigationAPI: Native.navigation, discoveryAPI: Native.discovery)
    tabs.nativePageHost = host
    let admission = ChromiumCreatedPageAdmission(api: Native.discovery, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    registry.onWindowClose = { [weak admission, weak registry, weak tabs] id in
        guard let admission, let registry, let tabs, let state = registry.windows[id] else { return }
        if admission.shouldDetachModelWindow(state) { tabs.detach(window: state) }
    }
    func factory(_ id: Int32, profile: UUID) {
        Native.windows[id] = Native.window(id, group: UInt64(id), profile: profile, flags: 4 | 8, active: id * 10)
        Native.tabs.append(Native.tab(id * 10, window: id, flags: 2))
    }
    Native.restoring = true; defer { Native.restoring = false }
    // Initial split refusal preserves the record and never starts a native page.
    do {
        var splitDevice = device
        splitDevice.windows = [device.windows.last!]
        let splitRoot = root.appendingPathComponent("split-first")
        let splitStore = TabStore(directory: splitRoot); splitStore.save(tree, splitDevice); splitStore.flush()
        let splitRegistry = WindowRegistry()
        let splitTabs = TabsController(settings: settings, windowRegistry: splitRegistry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: splitRoot)
        let splitAdmission = ChromiumCreatedPageAdmission(api: Native.discovery, host: host, tabs: splitTabs,
            registry: splitRegistry, isUtility: { _ in false }, makeShell: { _ in preconditionFailure("Split created a shell") })
        precondition(splitAdmission.prepareInitialWindow() == nil && splitRegistry.windows.isEmpty)
        precondition(splitTabs.device.windows.first?.split == split && Native.restoredURLs.isEmpty)
    }
    do {
        let openingRoot = root.appendingPathComponent("opening")
        let openingStore = TabStore(directory: openingRoot)
        var openingDevice = device; openingDevice.windows = [device.windows[0]]
        openingStore.save(tree, openingDevice); openingStore.flush()
        let openingRegistry = WindowRegistry()
        let openingTabs = TabsController(settings: settings, windowRegistry: openingRegistry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: openingRoot)
        let openingAdmission = ChromiumCreatedPageAdmission(api: Native.discovery, host: host, tabs: openingTabs,
            registry: openingRegistry, isUtility: { _ in false }, makeShell: { _ in NSView() })
        let pending = openingAdmission.prepareInitialWindow()!
        precondition(openingAdmission.browserTarget(kind: 0, regularProfile: Native.work)?.window == -1)
        openingRegistry.unregister(pending.id)
        // Native creation can also precede catalog/model admission. Its real
        // identity is not permission to create a parallel regular window.
        Native.windows[999] = Native.window(999, group: 999, profile: Native.work, active: 9990)
        precondition(openingAdmission.browserTarget(kind: 0, regularProfile: Native.work)?.window == -1)
        Native.windows[999] = nil
        precondition(openingAdmission.browserTarget(kind: 0, regularProfile: Native.work)?.regularProfile == Native.work)
    }
    let initial = BrowserWindowState(id: rootID)
    registry.register(initial); tabs.attach(window: initial)
    factory(1001, profile: Native.work)
    precondition(admission.admitRestoredWindow(initial, native: 1001, profile: Native.work, show: false, canPresent: { true }))
    precondition(initial.id == rootID && initial.selectedItemID == first && Native.restoredURLs == [rootURL.absoluteString])
    var canPresent = true, closed: [Int32] = []
    admission.restoreSavedWindows(open: { profile, destination, callback, pointer in MainActor.assumeIsolated {
        precondition(destination == 5)
        Native.savedRequests.append((UUID(uuidString: String(cString: profile!))!, callback, pointer))
    } }, close: { id in closed.append(id); Native.end(id); return 1 }, canPresent: { canPresent })
    precondition(Native.savedRequests.count == 3 && Native.savedRequests.allSatisfy { $0.0 == Native.personal })
    precondition(registry.windows[splitID] == nil && tabs.device.windows.first { $0.id == splitID }?.split == split)
    let requests = Native.savedRequests; Native.savedRequests = []
    factory(1002, profile: Native.personal); requests[0].1?(0, 1002, requests[0].2)
    precondition(registry.windows[extraID]?.selectedItemID == selected)
    precondition(Native.restoredURLs == [rootURL.absoluteString, selectedURL.absoluteString])
    registry.setActive(initial)
    let snapshots = Native.snapshotReads
    precondition(admission.browserTarget(kind: 0, regularProfile: Native.personal)?.window == 1001)
    precondition(Native.snapshotReads == snapshots)
    let priorActive = Native.windows[1001]!.active_tab
    Native.windows[1001]?.active_tab = 12345
    Native.tabs.append(Native.tab(12345, window: 1001))
    precondition(admission.browserTarget(kind: 0, regularProfile: Native.work)?.window == -1)
    Native.tabs.removeAll { $0.tab == 12345 }; Native.windows[1001]?.active_tab = priorActive
    precondition(admission.browserTarget(kind: 0, regularProfile: Native.work)?.window == 1001)

    registry.setActive(registry.windows[extraID]!)
    precondition(admission.browserTarget(kind: 1, regularProfile: Native.work)?.window == 1002)
    precondition(admission.browserTarget(kind: 2, regularProfile: Native.work)?.window == 1002)
    precondition(admission.browserTarget(kind: 99, regularProfile: Native.work) == nil)
    registry.activeWindowId = nil // A settings/private window is frontmost.
    let frontRegular = admission.browserTarget(kind: 0, regularProfile: UUID())?.window
    precondition(frontRegular == 1001 || frontRegular == 1002)
    registry.setActive(registry.windows[extraID]!)


    factory(1003, profile: Native.personal); Native.rejectNextObservation = true
    requests[1].1?(0, 1003, requests[1].2)
    precondition(registry.windows[failedID] == nil && tabs.device.windows.contains { $0.id == failedID })
    canPresent = false; factory(1004, profile: Native.personal)
    requests[2].1?(0, 1004, requests[2].2)
    precondition(closed == [1003, 1004] && registry.windows[lateID] == nil)
    precondition(Native.restoredURLs == [rootURL.absoluteString, selectedURL.absoluteString])
    precondition(tabs.unclaimedWindowRecords().map(\.id).contains(failedID) && tabs.unclaimedWindowRecords().map(\.id).contains(lateID))
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(tabs.device.windows.count == 5 && tabs.tree.items.count == tree.items.count)
    // Show can reenter quit after product/host registration. Keep that model
    // registered while native close is pending or refused, and retry its same page.
    canPresent = true
    admission.restoreSavedWindows(open: { profile, _, callback, pointer in MainActor.assumeIsolated {
        Native.savedRequests.append((UUID(uuidString: String(cString: profile!))!, callback, pointer))
    } }, close: { _ in preconditionFailure("Bound restoration must retain its close observation") }, canPresent: { canPresent })
    let retries = Native.savedRequests; Native.savedRequests = []
    precondition(retries.count == 2)
    var closeRequests: [Int32] = []
    Native.onCloseWindow = { id in closeRequests.append(id); return id == 1005 ? 1 : 0 }
    Native.onShow = { _ in canPresent = false; return 1 }
    factory(1005, profile: Native.personal); retries[0].1?(0, 1005, retries[0].2)
    let pendingState = registry.windows[failedID]!
    let pendingPage = tabs.selectedSession(in: pendingState)!.navigation!
    precondition(closeRequests == [1005] && registry.windows[failedID] === pendingState)
    let loaded = Native.restoredURLs
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(!admission.shouldDetachModelWindow(pendingState))
    canPresent = true; Native.onShow = nil
    for (token, entry) in Native.observers.filter({ $0.value.2 == 1005 }) {
        entry.0?(entry.1, token, 8, 1005, entry.3, nil, nil, 0, 0)
    }
    precondition(registry.windows[failedID] === pendingState && tabs.selectedSession(in: pendingState)?.navigation === pendingPage)
    precondition(Native.restoredURLs == loaded && host.isNativeSelection(pendingPage, in: pendingState))
    // An immediate refusal also cannot unregister its still-live owner.
    Native.onShow = { _ in canPresent = false; return 1 }
    factory(1006, profile: Native.personal); retries[1].1?(0, 1006, retries[1].2)
    let refusedState = registry.windows[lateID]!
    let refusedPage = tabs.selectedSession(in: refusedState)!.navigation!
    precondition(closeRequests == [1005, 1006] && registry.windows[lateID] === refusedState)
    precondition(host.isNativeSelection(refusedPage, in: refusedState))
    let retainedRecord = tabs.device.windows.first { $0.id == lateID }
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(!admission.shouldDetachModelWindow(refusedState))
    Native.end(1006); admission.apply(Native.discovery.readSnapshot()!)
    precondition(registry.windows[lateID] == nil && tabs.device.windows.first { $0.id == lateID } == retainedRecord)
    canPresent = true; Native.onShow = nil
    admission.resumeRestoredWindows(canPresent: { canPresent })
    precondition(Native.restoredURLs.count == loaded.count + 1)
    Native.onCloseWindow = nil
    tabs.flushSync() // Accepted app-close notification, before either group retires.
    Native.end(1001); Native.end(1002); Native.end(1005); Native.end(1006)
    admission.apply(Native.discovery.readSnapshot()!)
    precondition(registry.windows.isEmpty && Set(tabs.device.windows.map(\.id)) == Set(device.windows.map(\.id)))
    let noWindow = admission.browserTarget(kind: 1, regularProfile: Native.personal)
    precondition(noWindow?.window == 0 && noWindow?.regularProfile == Native.personal)
    precondition(admission.browserTarget(kind: 0, regularProfile: UUID()) == nil)

    tabs.saveNow()
    let saved = TabStore(directory: root).load()
    precondition(Set(saved.device.windows.map(\.id)) == Set(device.windows.map(\.id)) && saved.device.windows.first { $0.id == splitID }?.split == split)
}
