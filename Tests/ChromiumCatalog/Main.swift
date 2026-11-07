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
    static var admitted: [Int32] = []

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
        } })
    }
    static var host: ChromiumPageHostAPI {
        ChromiumPageHostAPI(open: { _, _, _, _, _ in preconditionFailure("Discovery created a browser") },
            create: { _, _, _ in preconditionFailure("Discovery created a tab") },
            tabAt: { window, index in MainActor.assumeIsolated {
                let rows = Native.tabs.filter { $0.window == window }
                return rows.indices.contains(index) ? rows[index].tab : 0
            } }, tabTitle: { window, tab, _, _ in MainActor.assumeIsolated {
                Native.tabs.contains { $0.window == window && $0.tab == tab } ? 1 : 0
            } }, selectWindow: { _ in preconditionFailure("Discovery focused a window") },
            closeWindow: { _ in preconditionFailure("Discovery closed native contents") },
            attach: { window, view in MainActor.assumeIsolated {
                Native.attachments += 1; Native.shells[window] = view; return 1
            } }, shellIsOwned: { window, view in MainActor.assumeIsolated {
                Native.windows[window] != nil && Native.shells[window] == view ? 1 : 0
            } }, detachIfOwned: { window, view in MainActor.assumeIsolated {
                guard view != nil, Native.windows[window] != nil, Native.shells[window] == view else { return 0 }
                Native.shells[window] = nil; return 1
            } })
    }
    static var navigation: ChromiumNavigationAPI {
        ChromiumNavigationAPI(observe: { window, tab, callback, context in MainActor.assumeIsolated {
            let token = Native.nextToken; Native.nextToken += 1
            Native.observers[token] = (callback, context, window, tab)
            "https://fixture.invalid/live-\(tab)".withCString {
                callback?(context, token, 0, window, tab, $0, nil, 0, 0)
            }
            return token
        } }, unobserve: { token in MainActor.assumeIsolated { Native.observers[token] = nil } },
            navigate: { _, _, _ in preconditionFailure("Existing page was reloaded") },
            back: { _, _ in 1 }, forward: { _, _ in 1 }, reload: { _, _ in preconditionFailure("Existing page was reloaded") },
            stop: { _, _ in preconditionFailure("Existing page was stopped") },
            select: { _, _ in preconditionFailure("Discovery selected/focused a native tab") },
            close: { _, _ in preconditionFailure("Discovery closed native contents") },
            profileUUID: { window, output, capacity in MainActor.assumeIsolated {
                guard let row = Native.windows[window], let profile = ChromiumDiscoveryAPI.profileID(row) else { return 0 }
                let bytes = profile.uuidString.utf8CString
                if let output, capacity >= bytes.count {
                    for (index, byte) in bytes.enumerated() { output[index] = byte }
                }
                return bytes.count
            } })
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
        Native.tabs = [Native.tab(100, window: 10, flags: 2), Native.tab(101, window: 10)]
        Native.publish()
        precondition(shellCount == 1 && registry.windows.count == 1)
        let first = registry.allWindows.first!
        let selected = tabs.selectedSession(in: first)!
        precondition((selected.navigation as! ChromiumPageNavigation).nativeTabID == 101)
        precondition(Native.observers.values.allSatisfy { $0.3 != 100 })
        precondition(Native.admitted == [10] && registry.activeWindowId == first.id)
        let initialTree = tabs.tree, initialDevice = tabs.device, initialAttachments = Native.attachments
        Native.publish()
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

        // Losing an original logical client does not destroy its physical group.
        Native.end(10); Native.publish()
        precondition(registry.windows[first.id] === first && shellCount == 3)
        let savedItems = Set(tabs.tree.items.keys)
        Native.end(30); Native.publish()
        precondition(registry.windows[inactive.id] == nil && Set(tabs.tree.items.keys) == savedItems)
        precondition(!tabs.device.windows.contains { $0.id == inactive.id })
        catalog.stop()
        precondition(Native.callback == nil)
        for window in Array(Native.windows.keys) { Native.end(window) }
        tabs.saveNow()
        print("Chromium catalog admission checks passed")
    }
}
