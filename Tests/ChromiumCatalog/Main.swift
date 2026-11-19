#if BARK_CATALOG_FRAMEWORK
@testable import NookNativeShell
#endif
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
/// Delay delivery only: the concrete host still creates and owns every native row.
@MainActor private final class DelayedCreationHost: NativePageHost {
    let base: ChromiumNativePageHost
    var delayedItem: UUID?
    var onPending: (() -> Void)?
    private var pending: (() -> Void)?
    init(_ base: ChromiumNativePageHost) { self.base = base }
    var isPending: Bool { pending != nil }
    func resolve() { let completion = pending; pending = nil; completion?() }
    func createPage(for session: PageSession, profile: Profile, in window: BrowserWindowState,
                    completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void)
        -> (@MainActor () -> Void) {
        let delayed = delayedItem == session.itemID
        if delayed { delayedItem = nil }
        return base.createPage(for: session, profile: profile, in: window) { [self] result in
            if delayed {
                precondition(pending == nil)
                // Cancellation still delivers the real late result so the model
                // can release its actual resource through this same host.
                pending = { completion(result) }
                onPending?()
            } else { completion(result) }
        }
    }
    func canAdoptPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        base.canAdoptPage(page, in: window)
    }
    func selectPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        base.selectPage(page, in: window)
    }
    func acceptNativeSelection(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        base.acceptNativeSelection(page, in: window)
    }
    func isNativeSelection(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        base.isNativeSelection(page, in: window)
    }
    func applySplit(_ record: SplitRecord?, replacing previous: SplitRecord?,
                    pages: [UUID: PageSession], activeItemID: UUID?, in window: BrowserWindowState,
                    isCurrent: () -> Bool) -> Bool {
        base.applySplit(record, replacing: previous, pages: pages, activeItemID: activeItemID,
                        in: window, isCurrent: isCurrent)
    }
    func isSplit(_ record: SplitRecord?, pages: [UUID: PageSession], activeItemID: UUID?,
                 in window: BrowserWindowState) -> Bool {
        base.isSplit(record, pages: pages, activeItemID: activeItemID, in: window)
    }
    func closePage(_ page: any PageNavigation, completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        base.closePage(page, completion: completion)
    }
}

@MainActor private enum Native {
    static let work = UUID(), personal = UUID()
    static var windows: [Int32: BarcDiscoveryWindow] = [:]
    static var tabs: [BarcDiscoveryTab] = []
    static var observers: [UInt64: (BarcTabCallback?, UnsafeMutableRawPointer?, Int32, Int32)] = [:]
    static var nextToken: UInt64 = 10
    static var callback: BarcDiscoveryCallback?
    static var context: UnsafeMutableRawPointer?
    static var revision: UInt64 = 1
    static var miniCloseRequests = 0
    static var transfersEnabled = false
    static var refusesTransfers = false
    static var transferCount = 0
    static var sameOwnerAdmissions = 0
    static var peekRoleClears = 0
    static var onTransferAdmission: (() -> Void)?
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
    static var profileOpens: [(String, barc_profile_destination)] = []
    static var onCompleteStartup: ((Int32) -> Void)?
    static var onShow: ((Int32) -> Int32)?
    static var onCloseWindow: ((Int32) -> Int32)?
    static var onSelectWindow: ((Int32) -> Int32)?
    static var onForward: ((Int32, Int32) -> Void)?
    static var onSpaceSwitch: ((BarcSpaceSwitchRequest, BarcSpaceSwitchCallback?, UnsafeMutableRawPointer?) -> Int32)?
    static var onOpen: ((Int32, barc_profile_window_callback?, UnsafeMutableRawPointer?) -> Void)?
    static var onPageView: ((Int32) -> Void)?
    static var savedRequests: [(UUID, barc_profile_window_callback?, UnsafeMutableRawPointer?)] = []
    static var privateCallback: barc_profile_window_callback?
    static var privateContext: UnsafeMutableRawPointer?
    static func selectClient(_ client: Int32, tab: Int32) {
        guard let group = windows[client]?.physical_group else { return }
        for key in Array(windows.keys) where windows[key]?.physical_group == group {
            windows[key]?.selected_client = client
        }
        windows[client]?.flags &= ~BARC_DISCOVERY_SPACE_SUPPRESSED.rawValue
        if tab > 0 { windows[client]?.active_tab = tab }
    }

    static func settle(_ request: BarcSpaceSwitchRequest, group: UInt64,
                       status: BarcSpaceSwitchStatus, client: Int32, tab: Int32,
                       prompts: [BarcSpaceSwitchPrompt] = [], callback: BarcSpaceSwitchCallback?,
                       context: UnsafeMutableRawPointer?) {
        prompts.withUnsafeBufferPointer { records in
            var result = BarcSpaceSwitchResult(size: UInt32(MemoryLayout<BarcSpaceSwitchResult>.size),
                status: Int32(status.rawValue), request: request.request, physical_group: group,
                selected_client: client, active_tab: tab, prompts: records.baseAddress, prompt_count: records.count)
            callback?(&result, context)
        }
    }

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
    /// Page views retained by the simulated native engine.
    static var pageViews: [Int32: NSView] = [:]
    /// Tabs whose page has no view to place.
    static var viewless: Set<Int32> = []
    static var peekCapable = false
    static var miniShellCalls: [String] = []
    static var miniCloses: [Int32] = []
    /// The root view each Bark window was given; a window takes one.
    static var roots: [Int32: UnsafeMutableRawPointer] = [:]
    /// Makes a Peek for (source client, source tab, request): its client and tab.
    static var onCreatePeek: ((Int32, Int32, Int32) -> (Int32, Int32))?
    static var servesPageViews = true
    static var closesShowing: [(tab: Int32, successor: Int32)] = []
    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.discovery_snapshot = { windowRows, windowCapacity, tabRows, tabCapacity, size in MainActor.assumeIsolated {
            guard let size, size.pointee.size >= MemoryLayout<BarcDiscoverySnapshot>.size,
                  windowCapacity == 0 || windowRows![0].size >= MemoryLayout<BarcDiscoveryWindow>.size,
                  tabCapacity == 0 || tabRows![0].size >= MemoryLayout<BarcDiscoveryTab>.size else {
                return Int32(BARC_DISCOVERY_READ_INVALID_ARGUMENT.rawValue)
            }
            Native.snapshotReads += 1
            let rows = Native.windows.values.sorted { $0.window < $1.window }
            size.pointee = BarcDiscoverySnapshot(size: size.pointee.size, revision: Native.revision,
                                                 window_count: rows.count, tab_count: Native.tabs.count)
            guard windowCapacity >= rows.count, tabCapacity >= Native.tabs.count else { return 1 }
            for (index, row) in rows.enumerated() { var row = row; row.size = windowRows![index].size; windowRows![index] = row }
            for (index, row) in Native.tabs.enumerated() { var row = row; row.size = tabRows![index].size; tabRows![index] = row }
            return 0
        } }
        bridge.window_discovery_state = { id, result in MainActor.assumeIsolated {
            guard let result, result.pointee.size >= MemoryLayout<BarcDiscoveryWindow>.size, var row = Native.windows[id] else { return 0 }
            row.size = result.pointee.size; result.pointee = row; return 1
        } }
        bridge.discovery_observe = { callback, context in MainActor.assumeIsolated {
            Native.callback = callback; Native.context = context; return 1
        } }
        bridge.discovery_unobserve = { _ in MainActor.assumeIsolated {
            Native.callback = nil; Native.context = nil
        } }
        bridge.window_private_session_uuid = { window, output, capacity in MainActor.assumeIsolated {
            Native.copyPrivateID(window, output, capacity)
        } }
        bridge.runtime_complete_startup = { window in MainActor.assumeIsolated {
            Native.onCompleteStartup?(window)
        } }
        bridge.window_show = { window in MainActor.assumeIsolated {
            precondition((Native.windows[window].flatMap { Native.roots[Int32($0.physical_group)] } != nil) && Native.windows[window]?.selected_client == window)
            Native.shown.append(window); return Native.onShow?(window) ?? 1
        } }
        bridge.tab_copy_launch_space = { _, _, _, _ in 0 }
        bridge.tab_application_pending = { _, _ in 0 }
        bridge.profile_open_in_native_window = { owner, _, _, callback, context in MainActor.assumeIsolated {
            guard let open = Native.onOpen else { preconditionFailure("Discovery created a browser") }
            open(owner, callback, context)
        } }
        bridge.tab_create = { client, _, foreground in MainActor.assumeIsolated {
            precondition(foreground == 0 && (Native.restoring || Native.allowPrivateCreate && Native.privateIDs[client] != nil))
            let tab = Int32(9000 + Native.privateCreatedClients.count)
            Native.privateCreatedClients.append(client); Native.tabs.append(Native.tab(tab, window: client))
            return tab
        } }
        bridge.window_tab_at = { window, index in MainActor.assumeIsolated {
            let rows = Native.tabs.filter { $0.window == window }
            return rows.indices.contains(index) ? rows[index].tab : 0
        } }
        bridge.tab_copy_title = { window, tab, _, _ in MainActor.assumeIsolated {
            Native.membershipChecks += 1
            return Native.tabs.contains { $0.window == window && $0.tab == tab } ? 1 : 0
        } }
        bridge.window_select = { owner in MainActor.assumeIsolated {
            guard let select = Native.onSelectWindow else { preconditionFailure("Discovery focused a window") }
            return select(owner)
        } }
        bridge.window_switch_space = { pointer, callback, context in MainActor.assumeIsolated {
            guard let request = pointer?.pointee, request.size == MemoryLayout<BarcSpaceSwitchRequest>.size else { return 0 }
            if let switchSpace = Native.onSpaceSwitch { return switchSpace(request, callback, context) }
            guard let row = Native.windows[request.window],
                  Native.windows[request.client]?.physical_group == row.physical_group else { return 0 }
            let allowed = request.client == row.selected_client || Native.onSelectWindow?(request.client) != 0
            if allowed {
                Native.selectClient(request.client, tab: request.tab)
                if request.tab == 0 { Native.windows[request.client]?.flags |= BARC_DISCOVERY_SPACE_SUPPRESSED.rawValue }
            }
            let client = allowed ? request.client : row.selected_client
            Native.settle(request, group: row.physical_group, status: allowed ? BARC_SPACE_SWITCH_APPLIED : BARC_SPACE_SWITCH_REFUSED,
                client: client, tab: allowed ? request.tab : Native.windows[client]?.active_tab ?? 0,
                callback: callback, context: context)
            return 1
        } }
        bridge.window_close = { window in MainActor.assumeIsolated {
            guard Native.restoring, let close = Native.onCloseWindow else { preconditionFailure("Discovery closed native contents") }
            return close(window)
        } }
        bridge.window_native_shell_is_owned = { window, view in MainActor.assumeIsolated {
            guard let row = Native.windows[window] else { return 0 }
            return Native.roots[Int32(row.physical_group)] == view ? 1 : 0
        } }
        bridge.tab_transfer_with_admission = { source, tab, destination, admission, context in MainActor.assumeIsolated {
            precondition(Native.transfersEnabled)
            Native.transferCount += 1
            if Native.refusesTransfers { return 0 }
            if source == destination {
                Native.sameOwnerAdmissions += 1
                Native.onTransferAdmission?()
                guard Native.tabs.contains(where: { $0.window == source && $0.tab == tab }),
                      admission?(context, destination, tab) == 1,
                      let index = Native.tabs.firstIndex(where: { $0.window == destination && $0.tab == tab }) else { return 0 }
                if Native.tabs[index].flags & BARC_DISCOVERY_TAB_PEEK.rawValue != 0 {
                    Native.peekRoleClears += 1
                    Native.tabs[index].flags &= ~UInt32(BARC_DISCOVERY_TAB_PEEK.rawValue)
                    Native.tabs[index].peek_source_tab = 0
                }
                return 1
            }
            let previous = Native.windows[destination]?.active_tab ?? 0
            precondition(Native.tabs.contains { $0.window == source && $0.tab == tab })
            Native.move(tab, to: destination)
            Native.onTransferAdmission?()
            let accepted = admission?(context, destination, tab) == 1
            if accepted {
                if let index = Native.tabs.firstIndex(where: { $0.window == destination && $0.tab == tab }),
                   Native.tabs[index].flags & BARC_DISCOVERY_TAB_PEEK.rawValue != 0 {
                    Native.peekRoleClears += 1
                    Native.tabs[index].flags &= ~UInt32(BARC_DISCOVERY_TAB_PEEK.rawValue)
                    Native.tabs[index].peek_source_tab = 0
                }
                if !Native.tabs.contains(where: { $0.window == source }) {
                    Native.windows[source] = nil
                }
                return Native.tabs.contains { $0.window == destination && $0.tab == tab } ? 1 : 0
            }
            if Native.windows[source] != nil,
               Native.tabs.contains(where: { $0.window == destination && $0.tab == tab }) {
                let restore = Native.windows[destination]?.active_tab == tab
                Native.move(tab, to: source)
                if restore { Native.windows[destination]?.active_tab = previous }
            }
            return 0
        } }
        bridge.window_set_app_lifetime = { _ in 1 }
        bridge.window_set_page_hidden = { _, _ in 1 }
        bridge.window_new_peer_in_native_window = { _, _ in 0 }
        bridge.window_set_native_header = { _, _, _, _, _ in 0 }
        bridge.window_host_observe = { window, _, _ in MainActor.assumeIsolated { Native.windows[window] != nil ? UInt64(window) : 0 } }
        bridge.window_host_unobserve = { _ in }
        bridge.window_set_root_view = { window, view in MainActor.assumeIsolated {
            guard let row = Native.windows[window], let view, Native.onAttach?(window) != 0 else { return 0 }
            let group = Int32(row.physical_group)
            if let root = Native.roots[group] { return root == view ? 1 : 0 }
            Native.attachments += 1
            Native.roots[group] = view
            if row.flags & BARC_DISCOVERY_AWAITING_ADMISSION.rawValue != 0 {
                Native.admitted.append(window)
                Native.windows[window]?.flags &= ~BARC_DISCOVERY_AWAITING_ADMISSION.rawValue
            }
            return 1
        } }
        bridge.window_set_chrome = { window, _ in MainActor.assumeIsolated {
            Native.windows[window] != nil ? 1 : 0
        } }
        bridge.tab_native_view = { window, tab in
            let address: UInt = MainActor.assumeIsolated {
                guard Native.windows[window] != nil, Native.tabs.contains(where: { $0.window == window && $0.tab == tab }),
                      !Native.viewless.contains(tab), Native.servesPageViews else { return 0 }
                Native.onPageView?(window)
                guard Native.windows[window] != nil else { return 0 }
                let view = Native.pageViews[tab] ?? NSView()
                Native.pageViews[tab] = view
                return UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque())
            }
            return UnsafeMutableRawPointer(bitPattern: address)
        }
        bridge.tab_observe = { window, tab, callback, context in MainActor.assumeIsolated {
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
        } }
        bridge.tab_unobserve = { token in MainActor.assumeIsolated { Native.observers[token] = nil } }
        bridge.tab_navigate = { window, tab, url in MainActor.assumeIsolated {
            precondition(Native.restoring && Native.tabs.contains { $0.window == window && $0.tab == tab })
            Native.restoredURLs.append(String(cString: url!)); return 1
        } }
        bridge.tab_go_back = { _, _ in 1 }
        bridge.tab_go_forward = { client, tab in MainActor.assumeIsolated {
            Native.onForward?(client, tab)
            return 1
        } }
        bridge.tab_reload = { _, _ in preconditionFailure("Existing page was reloaded") }
        bridge.tab_stop = { _, _ in preconditionFailure("Existing page was stopped") }
        bridge.tab_select = { window, tab in MainActor.assumeIsolated {
            precondition(Native.tabs.contains { $0.window == window && $0.tab == tab })
            if let select = Native.onSelectWindow, select(window) != 1 { return 0 }
            Native.windows[window]?.active_tab = tab; return 1
        } }
        bridge.tab_close = { window, tab in MainActor.assumeIsolated {
            precondition((Native.allowFailedPrivateClose && Native.privateIDs[window] != nil || Native.restoring) && Native.tabs.contains { $0.window == window && $0.tab == tab })
            Native.failedPrivateCloses.append((window, tab)); Native.tabs.removeAll { $0.window == window && $0.tab == tab }; return 1
        } }
        bridge.tab_capture_thumbnail = { _, _, _ in 0 }
        bridge.tab_clear_site_data = { _, _, _, _ in 0 }
        bridge.window_profile_uuid = { window, output, capacity in MainActor.assumeIsolated {
            guard let row = Native.windows[window], let profile = row.profileID else { return 0 }
            let bytes = profile.uuidString.utf8CString
            if let output, capacity >= bytes.count {
                for (index, byte) in bytes.enumerated() { output[index] = byte }
            }
            return bytes.count
        } }
        bridge.tab_observe_media = { _, _ in 1 }
        bridge.tab_observe_vault = { _, _ in 1 }
        bridge.tab_observe_vault_save = { _, _ in 1 }
        bridge.tab_observe_vault_passkeys = { _, _ in 1 }
        bridge.tab_enable_peek = { _, _ in MainActor.assumeIsolated { Native.peekCapable ? 1 : 0 } }
        bridge.tab_create_peek = { observation, request, admission, context in MainActor.assumeIsolated {
            guard let source = Native.observers[observation], let make = Native.onCreatePeek else { return 0 }
            let (owner, tab) = make(source.2, source.3, request)
            var row = Native.tab(tab, window: owner, opener: source.3, flags: UInt32(BARC_DISCOVERY_TAB_PEEK.rawValue))
            row.peek_source_tab = source.3
            Native.tabs.append(row)
            guard admission?(context, owner, tab) == 1 else { Native.tabs.removeAll { $0.tab == tab }; return 0 }
            return 1
        } }
        bridge.blocker_set_tab_policy = { _, _, _, _, _ in 0 }
        bridge.tab_set_user_css = { _, _, _, _, _ in 0 }
        bridge.tab_close_selecting = { token, successor in MainActor.assumeIsolated {
            guard let observed = Native.observers[token], Native.tabs.contains(where: { $0.tab == successor }) else { return 0 }
            Native.closesShowing.append((observed.3, successor)); return 1
        } }
        return bridge
    }
    static var onAttach: ((Int32) -> Int32)?
    static func move(_ tab: Int32, to window: Int32) {
        guard var moved = tabs.first(where: { $0.tab == tab }) else { preconditionFailure("Missing moved tab") }
        tabs.removeAll { $0.tab == tab }
        moved.window = window; moved.flags |= UInt32(BARC_DISCOVERY_ACTIVE_TAB.rawValue)
        tabs.append(moved) // A transfer preserves opener and factory provenance.
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
        let group = windows.removeValue(forKey: window)?.physical_group
        if let group, !windows.values.contains(where: { $0.physical_group == group }) {
            roots[Int32(group)] = nil
        }
        tabs.removeAll { $0.window == window }
    }
}

private struct NoTokens: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@MainActor private func checkRegularTabCount() {
    let regular = Native.window(1, group: 1, profile: UUID(), active: 10)
    var parked = Native.window(2, group: 1, profile: UUID(), flags: 0, active: 20)
    parked.selected_client = regular.window
    let guest = Native.window(3, group: 2, profile: nil, profileKind: BARC_DISCOVERY_GUEST.rawValue, active: 30)
    let unnamed = Native.window(4, group: 3, profile: nil, active: 40)
    let snapshot = ChromiumDiscoverySnapshot(revision: 1, windows: [regular, parked, guest, unnamed], tabs: [
        Native.tab(10, window: 1), Native.tab(11, window: 1),
        Native.tab(20, window: 2, flags: BARC_DISCOVERY_TAB_APP_FACTORY.rawValue),
        Native.tab(30, window: 3), Native.tab(40, window: 4), Native.tab(50, window: 5),
    ])
    precondition(snapshot.regularTabCount == 3, "Count parked and factory tabs only for known regular owners")
}

/// Drive key-window changes inside this process without taking the desktop.
private final class CatalogApplication: NSApplication {
    weak var simulatedKeyWindow: NSWindow?
    override var keyWindow: NSWindow? { simulatedKeyWindow ?? super.keyWindow }
}

@main private enum Checks {
    @MainActor static func main() throws {
        let application = CatalogApplication.shared as! CatalogApplication
        try checkWindowShortcuts(application)
        checkRegularTabCount()
        try checkEngineSelectionInBarkWindow()
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
        let host = ChromiumNativePageHost(bridge: Native.bridge)
        tabs.nativePageHost = host
        registry.onWindowClose = { [weak tabs, weak registry] id in
            guard let tabs, let registry else { return }
            if let window = registry.windows[id], tabs.device.windows.contains(where: { $0.id == id }) { tabs.detach(window: window) }
        }
        var shellCount = 0
        var utilities: Set<Int32> = [80]
        let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
            registry: registry, isUtility: { utilities.contains($0) }, makeShell: { _ in shellCount += 1; return NSView() })
        let catalog = ChromiumWindowCatalog(bridge: Native.bridge)
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
        // Only the selected page needs a membership check.
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
        try checkClosingSelectionStaysWithNook()
        try checkSelfClosingPageKeepsNooksSpace()
        try checkLinkReachesEmptySpaceOfAnotherProfile()
        try checkSpaceSwitchOutcomes()
        try checkPrivateSessions()
        try checkSavedWindowRestoration()
        try checkNewWindowLikeWebKit()
        try checkPendingInitialPageRestoration()
        try checkPendingProfileRecoveryWindow()
        try checkDetachedMiniPromotion()
        try checkMiniInBarkWindow()
        try checkMiniPagesAdmitOrClose()
        try checkMixedProfileSplitAdmission()
        try checkSavedSplitInBarkWindow()
        try checkPeekWithoutAnEngineDocument()
        try checkNativePeekAdmission()
        try checkPeekInBarkWindow(promoteToSplit: false)
        try checkPeekInBarkWindow(promoteToSplit: true)
        try checkPeekInBarkWindow(promoteToSplit: true, existingSplit: true)
        print("Chromium same-client Peek activation and split promotion checks passed")
        print("Chromium catalog admission checks passed")
    }
}

/// Chromium activates a neighbour once Nook's selected page closes. That is not
/// mirrored: Nook's own pick wins, and a page Chromium opens on an empty space shows.
@MainActor private func checkClosingSelectionStaysWithNook() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcClosingSelection-\(UUID())")
    let suite = "BarcClosingSelection-\(UUID())", registry = WindowRegistry()
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
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    func item(_ tab: Int32) -> UUID {
        tabs.sessions.first { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == tab }!.itemID
    }
    Native.windows[601] = Native.window(601, group: 601, profile: Native.work, active: 6010)
    Native.tabs = [Native.tab(6010, window: 601), Native.tab(6011, window: 601), Native.tab(6012, window: 601)]
    admission.apply(Native.bridge.readSnapshot()!)
    let window = registry.allWindows.first!
    let closing = item(6010), neighbour = item(6011), recent = item(6012)
    precondition(window.selectedItemID == closing)
    Native.restoring = true
    tabs.select(recent, in: window); tabs.select(closing, in: window)
    precondition(window.selectedItemID == closing && Native.windows[601]?.active_tab == 6010)
    tabs.close(closing)
    precondition(Native.closesShowing.last! == (6010, 6012), "Chromium is to show Nook's live successor")
    precondition(window.selectedItemID == closing, "The page stays shown until it actually closes")
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(window.selectedItemID == closing)
    // The close goes ahead: Chromium shows the successor and the sidebar follows at once.
    Native.windows[601]?.active_tab = 6012
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(window.selectedItemID == recent, "The sidebar moves when Chromium shows the successor")
    func endTab(_ tab: Int32) {
        Native.tabs.removeAll { $0.tab == tab }
        for (token, observation) in Native.observers.filter({ $0.value.3 == tab }) {
            Native.observers[token] = nil
            observation.0?(observation.1, token, 7, 601, tab, nil, nil, 0, 0)
        }
    }
    endTab(6010)
    admission.apply(Native.bridge.readSnapshot()!)
    drain()
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(tabs.item(closing) == nil && window.selectedItemID == recent && window.spaceID == Native.work)
    precondition(Native.windows[601]?.active_tab == 6012)

    // A cold successor loads after the close, so Chromium's neighbour is active meanwhile.
    let cold = tabs.open(url: URL(string: "https://fixture.invalid/cold")!, in: window, placement: .background,
                         parent: .tabs(spaceID: Native.work))!
    precondition(tabs.session(for: cold)?.navigation == nil)
    tabs.move(cold, to: .tabs(spaceID: Native.work), after: recent)
    tabs.select(recent, in: window)
    tabs.close(recent)
    precondition(window.selectedItemID == recent, "No live successor to show first")
    endTab(6012)
    Native.windows[601]?.active_tab = 6011
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(window.selectedItemID != neighbour, "Chromium's neighbour was mirrored while Nook chose")
    drain()
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(tabs.item(recent) == nil && window.selectedItemID == cold && window.spaceID == Native.work)

    // A page Chromium opens while the window shows an empty space takes the selection.
    let empty = tabs.createSpace(name: "Empty", icon: "", accentHex: "#123456", after: Native.work, sharingLoginsWith: Native.work)!
    tabs.setSpace(empty, in: window)
    precondition(window.showsNativeEmptySpace && tabs.nativeSelectionIsSettling(in: window))
    // Links and Dock actions reach the empty space through its retained client.
    registry.setActive(window)
    precondition(admission.browserTarget(kind: 0, regularProfile: Native.work)?.window == 601)
    precondition(admission.browserTarget(kind: 2, regularProfile: Native.work)?.window == 601)
    let route = admission.incomingTarget(ruleSpace: nil, mini: false, regularProfile: Native.work)
    precondition(route?.window == 601 && route?.profile == Native.work && route?.space == empty)
    Native.tabs.append(Native.tab(6013, window: 601))
    Native.selectClient(601, tab: 6013)
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(window.selectedItemID == item(6013) && !window.showsNativeEmptySpace)
    Native.restoring = false
    Native.failedPrivateCloses = []; Native.privateCreatedClients = []; Native.restoredURLs = []
    Native.end(601); tabs.saveNow()
}

/// A page that closes itself, such as window.close(), reaches Nook after Chromium has
/// activated a neighbour, here from another space on the same profile. The window stays.
@MainActor private func checkSelfClosingPageKeepsNooksSpace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcSelfClosing-\(UUID())")
    let suite = "BarcSelfClosing-\(UUID())", registry = WindowRegistry()
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
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    Native.windows[621] = Native.window(621, group: 621, profile: Native.work, active: 6210)
    Native.tabs = [Native.tab(6210, window: 621)]
    admission.apply(Native.bridge.readSnapshot()!)
    let window = registry.allWindows.first!
    let closing = window.selectedItemID!
    let shared = tabs.createSpace(name: "Shared", icon: "", accentHex: "#123456", after: Native.work, sharingLoginsWith: Native.work)!
    Native.restoring = true
    let other = tabs.open(url: URL(string: "https://fixture.invalid/shared")!, in: window, placement: .newTab,
                          parent: .tabs(spaceID: shared))!
    let otherTab = (tabs.session(for: other)!.navigation as! ChromiumPageNavigation).nativeTabID
    tabs.select(closing, in: window)
    precondition(window.spaceID == Native.work && window.selectedItemID == closing)
    Native.tabs.removeAll { $0.tab == 6210 }
    for (token, observation) in Native.observers.filter({ $0.value.3 == 6210 }) {
        Native.observers[token] = nil
        observation.0?(observation.1, token, 7, 621, 6210, nil, nil, 0, 0)
    }
    Native.windows[621]?.active_tab = otherTab
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(window.spaceID == Native.work && window.selectedItemID != other,
                 "Chromium's neighbour carried the window into another space")
    drain()
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(tabs.item(closing) == nil && window.spaceID == Native.work && window.showsNativeEmptySpace)
    Native.restoring = false
    Native.failedPrivateCloses = []; Native.privateCreatedClients = []; Native.restoredURLs = []
    Native.end(621); tabs.saveNow()
}

/// An empty space whose profile has no client in the window gets one, selected, before an
/// incoming link resolves; the link waits instead of being refused.
@MainActor private func checkLinkReachesEmptySpaceOfAnotherProfile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcEmptyRoute-\(UUID())")
    let suite = "BarcEmptyRoute-\(UUID())", registry = WindowRegistry()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "house", accentHex: "#123456", after: Native.work)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    Native.windows[631] = Native.window(631, group: 631, profile: Native.work, active: 6310)
    Native.tabs = [Native.tab(6310, window: 631)]
    admission.apply(Native.bridge.readSnapshot()!)
    let window = registry.allWindows.first!
    registry.setActive(window)
    var opened: [(Int32, barc_profile_window_callback?, UnsafeMutableRawPointer?)] = []
    Native.onOpen = { owner, callback, pointer in opened.append((owner, callback, pointer)) }
    Native.onSelectWindow = { owner in
        guard let group = Native.windows[owner]?.physical_group else { return 0 }
        for key in Array(Native.windows.keys) where Native.windows[key]?.physical_group == group {
            Native.windows[key]?.selected_client = owner
        }
        return 1
    }
    Native.restoring = true
    defer { Native.restoring = false; Native.onOpen = nil; Native.onSelectWindow = nil }
    tabs.setSpace(Native.personal, in: window)
    precondition(window.nativeSpaceSwitchIsPending && window.spaceID == Native.work && !window.showsNativeEmptySpace)
    precondition(opened.count == 1, "One client is opened for the empty space's profile")
    precondition(opened[0].0 == 631)
    Native.windows[632] = Native.window(632, group: 631, profile: Native.personal, flags: 0, active: 6320)
    Native.windows[632]?.selected_client = 631
    Native.tabs.append(Native.tab(6320, window: 632))
    opened[0].1?(BARC_PROFILE_OK, 632, opened[0].2)
    precondition(!Native.tabs.contains { $0.window == 632 }, "The new client's blank is closed")
    precondition(window.showsNativeEmptySpace && window.spaceID == Native.personal &&
                 tabs.controllableSession(in: window) == nil)
    Native.windows[632]?.active_tab = 0
    Native.windows[632]?.flags |= UInt32(BARC_DISCOVERY_EMPTY_STRIP.rawValue)
    let route = admission.incomingTarget(ruleSpace: nil, mini: false, regularProfile: Native.work)
    precondition(route?.window == 632 && route?.profile == Native.personal && route?.space == Native.personal)
    precondition(Native.windows[631]?.selected_client == 632 && Native.roots[631] != nil,
                 "The empty space's client is selected with the sidebar")
    Native.failedPrivateCloses = []; Native.privateCreatedClients = []; Native.restoredURLs = []
    Native.end(632); Native.end(631); tabs.saveNow()
}

@MainActor private func checkSpaceSwitchOutcomes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcSpaceSwitch-\(UUID())")
    let suite = "BarcSpaceSwitch-\(UUID())", registry = WindowRegistry()
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        Native.onSpaceSwitch = nil; Native.onOpen = nil; Native.onSelectWindow = nil; Native.restoring = false
        Native.failedPrivateCloses.removeAll { $0.0 == 643 }
        for owner in Array(Native.windows.keys) { Native.end(owner) }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "house", accentHex: "#123456", after: Native.work)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    let group: UInt64 = 640
    Native.windows[640] = Native.window(640, group: group, profile: Native.work, active: 6400)
    Native.windows[641] = Native.window(641, group: group, profile: Native.personal, flags: 0, active: 6410)
    Native.windows[642] = Native.window(642, group: 642, profile: Native.work, flags: 0, active: 6420)
    Native.selectClient(640, tab: 6400)
    Native.tabs = [Native.tab(6400, window: 640), Native.tab(6401, window: 640),
                   Native.tab(6402, window: 640), Native.tab(6403, window: 640),
                   Native.tab(6410, window: 641), Native.tab(6420, window: 642)]
    func discover() { admission.apply(Native.bridge.readSnapshot()!) }
    discover()

    func page(_ tab: Int32) -> PageSession {
        tabs.sessions.first { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == tab }!
    }
    let work = page(6400), research = page(6401), personal = page(6410), otherPage = page(6420)
    let window = registry.allWindows.first { $0.selectedItemID == work.itemID }!
    let other = registry.allWindows.first { $0.selectedItemID == otherPage.itemID }!
    registry.setActive(window)
    func assertCommands(_ destination: PageSession, in state: BrowserWindowState) {
        precondition(tabs.controllableSession(in: state) === destination)
        precondition(host.isNativeSelection(destination.navigation!, in: state))
    }
    let researchSpace = tabs.createSpace(name: "Research", icon: "", accentHex: "#123456",
        after: Native.personal, sharingLoginsWith: Native.work)!
    tabs.move(research.itemID, to: .tabs(spaceID: researchSpace), after: nil)
    let sharedEmpty = tabs.createSpace(name: "Empty", icon: "", accentHex: "#123456",
        after: researchSpace, sharingLoginsWith: Native.work)!

    // Keyboard switches between profiles. A palette selection of a tab in a
    // different space can select a parked pane in the same original client.
    precondition(tabs.selectNextSpace(in: window))
    precondition(window.spaceID == Native.personal)
    assertCommands(personal, in: window)
    tabs.select(research.itemID, in: window)
    precondition(window.spaceID == researchSpace)
    assertCommands(research, in: window)
    tabs.setSpace(sharedEmpty, in: window)
    precondition(window.spaceID == sharedEmpty && window.showsNativeEmptySpace &&
                 tabs.controllableSession(in: window) == nil && Native.windows[640]?.active_tab == 6401)
    discover()
    precondition(window.spaceID == sharedEmpty && tabs.controllableSession(in: window) == nil)
    Native.windows[640]?.active_tab = 6400
    discover()
    precondition(window.spaceID == sharedEmpty && tabs.controllableSession(in: window) == nil,
                 "A parked strip change leaves the empty space selected")
    Native.selectClient(640, tab: 6400)
    discover()
    assertCommands(work, in: window)
    precondition(window.spaceID == Native.work)

    // A second relative shortcut can arrive before the first native reply.
    // Keep the outgoing selection visible until Chromium names the winner.
    var pending: [(BarcSpaceSwitchRequest, BarcSpaceSwitchCallback?, UnsafeMutableRawPointer?)] = []
    Native.onSpaceSwitch = { request, callback, context in
        pending.append((request, callback, context))
        return 1
    }
    func reply(_ index: Int, status: BarcSpaceSwitchStatus, client: Int32, tab: Int32) {
        let (request, callback, context) = pending[index]
        Native.settle(request, group: group, status: status, client: client, tab: tab,
                      callback: callback, context: context)
    }
    precondition(tabs.selectNextSpace(in: window) && tabs.selectNextSpace(in: window))
    precondition(pending.map { $0.0.tab } == [6410, 6401], "Rapid Next Space must advance two spaces")
    precondition(window.spaceID == Native.work && window.selectedItemID == work.itemID)
    assertCommands(work, in: window)
    Native.selectClient(640, tab: 6401)
    reply(1, status: BARC_SPACE_SWITCH_APPLIED, client: 640, tab: 6401)
    reply(0, status: BARC_SPACE_SWITCH_SUPERSEDED, client: 640, tab: 6401)
    precondition(window.spaceID == researchSpace && !window.nativeSpaceSwitchIsPending)
    assertCommands(research, in: window)
    assertCommands(otherPage, in: other)

    pending.removeAll()
    precondition(tabs.selectPreviousSpace(in: window) && tabs.selectNextSpace(in: window))
    precondition(pending.map { $0.0.tab } == [6410, 6401], "Reversing a pending switch returns to its origin")
    reply(0, status: BARC_SPACE_SWITCH_SUPERSEDED, client: 640, tab: 6401)
    precondition(window.nativeSpaceSwitchIsPending && window.spaceID == researchSpace)
    reply(1, status: BARC_SPACE_SWITCH_APPLIED, client: 640, tab: 6401)
    assertCommands(research, in: window)

    pending.removeAll()
    precondition(tabs.selectPreviousSpace(in: window))
    reply(0, status: BARC_SPACE_SWITCH_REFUSED, client: 640, tab: 6401)
    precondition(tabs.selectPreviousSpace(in: window))
    precondition(pending.map { $0.0.tab } == [6410, 6410], "A refusal clears the requested destination")
    Native.selectClient(641, tab: 6410)
    reply(1, status: BARC_SPACE_SWITCH_APPLIED, client: 641, tab: 6410)
    assertCommands(personal, in: window)
    Native.onSpaceSwitch = nil
    tabs.setSpace(Native.work, in: window)
    assertCommands(work, in: window)

    // Two spaces may intentionally show the very same shared favorite.
    tabs.move(work.itemID, to: .favorites(spaceID: Native.work), after: nil)
    let favorites = tabs.createSpace(name: "Favorites", icon: "", accentHex: "#123456",
        after: sharedEmpty, sharingLoginsWith: Native.work)!
    tabs.setSpace(favorites, in: window)
    precondition(window.spaceID == favorites)
    assertCommands(work, in: window)
    tabs.setSpace(Native.work, in: window)
    precondition(window.spaceID == Native.work)
    assertCommands(work, in: window)

    // Discovery can run during engine activation while Research wins. Only
    // the terminal result claims that pane, even when the sidebar asked for Personal.
    Native.onSpaceSwitch = { request, callback, context in
        precondition(window.nativeSpaceSwitchIsPending && request.window == 640 &&
                     request.client == 641 && request.tab == 6410)
        Native.selectClient(640, tab: 6401)
        discover()
        precondition(window.spaceID == Native.work && window.selectedItemID == work.itemID &&
                     tabs.controllableSession(in: window) == nil)
        let outgoing = BarcSpaceSwitchPrompt(size: UInt32(MemoryLayout<BarcSpaceSwitchPrompt>.size),
            kind: Int32(BARC_SPACE_SWITCH_PERMISSION.rawValue), disposition: Int32(BARC_SPACE_SWITCH_PROMPT_PARKED.rawValue),
            client: 640, tab: 6400, document: 42)
        Native.settle(request, group: group, status: BARC_SPACE_SWITCH_SUPERSEDED, client: 640, tab: 6401,
                      prompts: [outgoing], callback: callback, context: context)
        return 1
    }
    tabs.setSpace(Native.personal, in: window)
    precondition(window.spaceID == researchSpace && !window.nativeSpaceSwitchIsPending)
    assertCommands(research, in: window)
    let mirrored = tabs.device
    discover()
    precondition(tabs.device == mirrored)

    Native.onSpaceSwitch = { request, callback, context in
        Native.settle(request, group: group, status: BARC_SPACE_SWITCH_REFUSED, client: 640, tab: 6401,
                      callback: callback, context: context)
        return 1
    }
    tabs.setSpace(Native.personal, in: window)
    precondition(window.spaceID == researchSpace)
    assertCommands(research, in: window)

    // The native pane may already have changed while Swift was preparing.
    // Refusal preserves the pane actually retained by the invoking group.
    Native.onSpaceSwitch = { request, callback, context in
        Native.selectClient(640, tab: 6400)
        Native.settle(request, group: group, status: BARC_SPACE_SWITCH_REFUSED, client: 640, tab: 6400,
                      callback: callback, context: context)
        return 1
    }
    tabs.setSpace(Native.personal, in: window)
    assertCommands(work, in: window)

    // Selecting another pane in one space follows the owner Chromium settles on.
    Native.onSpaceSwitch = nil
    tabs.setSpace(Native.work, in: window)
    Native.restoring = true
    Native.onSelectWindow = { owner in Native.selectClient(owner, tab: 0); return 1 }
    let second = page(6402), third = page(6403)
    let sameSpaceSplit = SplitRecord([work.itemID, second.itemID, third.itemID],
                                     orientation: .vertical, dividers: [0.3, 0.7])!
    precondition(tabs.presentNativeSplit(sameSpaceSplit, activeItemID: work.itemID, in: window))
    precondition(window.split == sameSpaceSplit && window.spaceID == Native.work)
    var finishPaneSelection: ((BarcSpaceSwitchStatus, Int32) -> Void)?
    Native.onSpaceSwitch = { request, callback, context in
        precondition(request.client == 640 && request.tab == 6402)
        finishPaneSelection = { status, actualTab in
            Native.selectClient(640, tab: actualTab)
            Native.settle(request, group: group, status: status, client: 640, tab: actualTab,
                          callback: callback, context: context)
        }
        return 1
    }
    var forwardedTabs: [Int32] = []
    Native.onForward = { client, tab in
        precondition(client == 640)
        forwardedTabs.append(tab)
    }
    func forward() { _ = tabs.controllableSession(in: window)?.navigation?.goForward() }
    tabs.select(second.itemID, in: window)
    precondition(finishPaneSelection != nil && window.nativeSpaceSwitchIsPending,
                 "A pane activation must wait for the engine's selected page")
    Native.selectClient(640, tab: 6403)
    discover()
    precondition(tabs.controllableSession(in: window) == nil)
    forward()
    precondition(forwardedTabs.isEmpty)
    finishPaneSelection?(BARC_SPACE_SWITCH_SUPERSEDED, 6403)
    assertCommands(third, in: window)
    forward()
    precondition(window.split == sameSpaceSplit && window.spaceID == Native.work)
    tabs.select(second.itemID, in: window)
    finishPaneSelection?(BARC_SPACE_SWITCH_REFUSED, 6403)
    assertCommands(third, in: window)
    forward()
    Native.onSpaceSwitch = nil
    tabs.select(second.itemID, in: window)
    assertCommands(second, in: window)
    forward()
    precondition(forwardedTabs == [6403, 6403, 6402])
    Native.onForward = nil
    precondition(window.split == sameSpaceSplit)
    assertCommands(otherPage, in: other)

    // An existing mixed-profile split routes to its actual focused pane.
    let split = SplitRecord([research.itemID, personal.itemID], orientation: .vertical, dividers: [0.5])!
    var splitReady = false
    precondition(tabs.presentNativeSplit(split, activeItemID: research.itemID, in: window,
                                        completion: { splitReady = $0 }))
    precondition(splitReady && window.split == split)
    tabs.setSpace(Native.personal, in: window)
    precondition(window.split == split && window.spaceID == Native.personal)
    assertCommands(personal, in: window)

    // A newer intent takes ownership while a new empty profile client is starting.
    let newProfileSpace = tabs.createSpace(name: "Fresh", icon: "", accentHex: "#123456", after: sharedEmpty)!
    let newProfile = tabs.tree.dataStoreID(for: newProfileSpace)!
    var factory: (barc_profile_window_callback?, UnsafeMutableRawPointer?)?
    Native.onOpen = { _, callback, context in factory = (callback, context) }
    Native.restoring = true
    tabs.setSpace(newProfileSpace, in: window)
    precondition(window.nativeSpaceSwitchIsPending && factory != nil)
    tabs.setSpace(Native.personal, in: window)
    assertCommands(personal, in: window)
    Native.windows[643] = Native.window(643, group: group, profile: newProfile, flags: 0, active: 6430)
    Native.windows[643]?.selected_client = 641
    Native.tabs.append(Native.tab(6430, window: 643))
    factory?.0?(BARC_PROFILE_OK, 643, factory?.1)
    precondition(window.spaceID == Native.personal && Native.windows[641]?.selected_client == 641)
    assertCommands(personal, in: window)

    // A native result may also arrive after a newer request was fully published.
    var finishOlder: (() -> Void)?
    Native.onSpaceSwitch = { request, callback, context in
        finishOlder = { Native.settle(request, group: group, status: BARC_SPACE_SWITCH_SUPERSEDED, client: 641,
                                     tab: 6410, callback: callback, context: context) }
        return 1
    }
    tabs.setSpace(Native.work, in: window)
    precondition(window.nativeSpaceSwitchIsPending)
    Native.onSpaceSwitch = nil
    tabs.setSpace(researchSpace, in: window)
    finishOlder?()
    precondition(window.spaceID == researchSpace)
    assertCommands(research, in: window)

    Native.onSpaceSwitch = { request, callback, context in
        Native.selectClient(640, tab: 6499)
        Native.settle(request, group: group, status: BARC_SPACE_SWITCH_SUPERSEDED, client: 640, tab: 6499,
                      callback: callback, context: context)
        return 1
    }
    tabs.setSpace(Native.personal, in: window)
    precondition(window.nativeSpaceSwitchIsUnresolved && tabs.controllableSession(in: window) == nil)
    assertCommands(otherPage, in: other)
    Native.selectClient(640, tab: 6400)
    discover()
    precondition(!window.nativeSpaceSwitchIsUnresolved && window.spaceID == researchSpace,
                 "Discovery restores the shared favorite in the window's existing space")
    assertCommands(work, in: window)

    Native.onSpaceSwitch = { request, callback, context in
        for owner: Int32 in [640, 641, 643] { Native.end(owner) }
        Native.settle(request, group: 0, status: BARC_SPACE_SWITCH_CLOSED, client: 0, tab: 0,
                      callback: callback, context: context)
        return 1
    }
    tabs.setSpace(Native.personal, in: window)
    precondition(window.nativeSpaceSwitchIsUnresolved && tabs.controllableSession(in: window) == nil)
    assertCommands(otherPage, in: other)
    discover()
    precondition(registry.windows[window.id] == nil && registry.windows[other.id] === other)
    tabs.saveNow()
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
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    registry.onWindowClose = { id in
        if let window = registry.windows[id], tabs.device.windows.contains(where: { $0.id == id }) { tabs.detach(window: window) }
    }
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    Native.windows[501] = Native.window(501, group: 501, profile: Native.work, active: 5010)
    Native.tabs = [Native.tab(5010, window: 501)]
    admission.apply(Native.bridge.readSnapshot()!)
    let source = registry.allWindows.first!, session = tabs.selectedSession(in: registry.allWindows.first!)!
    let page = session.navigation as! ChromiumPageNavigation, item = session.itemID
    precondition(registry.windows.count == 1 && tabs.device.windows.contains { $0.id == source.id })
    Native.windows[502] = Native.window(502, group: 502, profile: Native.work, active: 5010)
    Native.move(5010, to: 502); Native.end(501)
    admission.apply(Native.bridge.readSnapshot()!)
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
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    registry.onWindowClose = { id in if let window = registry.windows[id] { tabs.detach(window: window) } }
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    let a = UUID(), b = UUID()
    func add(_ window: Int32, session: UUID?, factory: Bool = false) {
        Native.windows[window] = Native.window(window, group: UInt64(window), profile: nil,
            profileKind: BARC_DISCOVERY_GUEST.rawValue,
            flags: 4 | (factory ? 8 : 16) | UInt32(BARC_DISCOVERY_AWAITING_ADMISSION.rawValue), active: window * 10)
        Native.tabs.append(Native.tab(window * 10, window: window, flags: factory ? 2 : 0))
        Native.privateIDs[window] = session
    }
    add(701, session: a); add(702, session: b); add(703, session: nil) // Stock Guest is not a Barc session.
    Native.windows[704] = Native.window(704, group: 704, profile: nil, profileKind: BARC_DISCOVERY_INCOGNITO.rawValue, active: 7040)
    Native.tabs.append(Native.tab(7040, window: 704))
    let originalTree = tabs.tree, originalDevice = tabs.device
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(registry.windows.count == 2 && tabs.privateWindows.count == 2)
    precondition(Native.admitted.contains(701) && Native.admitted.contains(702))
    precondition(!Native.admitted.contains(703) && !Native.admitted.contains(704))
    let source = tabs.privateWindows.first { $0.ephemeralProfile?.id == a }!
    let originalSession = tabs.selectedSession(in: source)!, page = originalSession.navigation as! ChromiumPageNavigation
    precondition(page.isPrivateSession && originalSession.isPrivate && originalSession.profile?.webKitStorage == nil)
    add(711, session: a)
    Native.tabs[Native.tabs.firstIndex { $0.tab == 7110 }!].opener_tab = 7010
    admission.apply(Native.bridge.readSnapshot()!)
    let child = tabs.privateWindows.first { $0 !== source && $0.ephemeralProfile?.id == a }!
    precondition(child.ephemeralProfile === source.ephemeralProfile && registry.windows.count == 3)
    let item = originalSession.itemID
    Native.move(7010, to: 711); Native.end(701)
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(registry.windows[source.id] == nil && tabs.session(for: item) === originalSession)
    precondition(tabs.selectedSession(in: child) === originalSession && originalSession.navigation === page && !page.isClosed)
    registry.setActive(child)
    let privateTarget = admission.browserTarget(kind: 2, regularProfile: nil)
    precondition(privateTarget?.window == page.nativeWindowID && privateTarget?.regularProfile == nil)
    precondition(admission.browserTarget(kind: 0, regularProfile: a) == nil)

    precondition(tabs.tree == originalTree && tabs.device == originalDevice)
    let privateSibling = tabs.sessions.first {
        ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == 7110
    }!
    let otherPrivate = tabs.privateWindows.first { $0.ephemeralProfile?.id == b }!
    let otherSelection = tabs.controllableSession(in: otherPrivate)!
    let privateSplit = SplitRecord([item, privateSibling.itemID])!
    precondition(tabs.presentNativeSplit(privateSplit, activeItemID: item, in: child))
    precondition(child.split == privateSplit)
    var askedForPrivatePane = false
    Native.onSpaceSwitch = { request, callback, context in
        precondition(request.window == 711 && request.client == 711 && request.tab == 7110)
        askedForPrivatePane = true
        Native.settle(request, group: 711, status: BARC_SPACE_SWITCH_REFUSED, client: 711, tab: 7010,
                      callback: callback, context: context)
        return 1
    }
    tabs.select(privateSibling.itemID, in: child)
    precondition(askedForPrivatePane && tabs.controllableSession(in: child) === originalSession,
                 "A refused private pane change retains the original private page")
    Native.onSpaceSwitch = nil
    tabs.select(privateSibling.itemID, in: child)
    precondition(tabs.controllableSession(in: child) === privateSibling && child.split == privateSplit)
    tabs.select(item, in: child)
    precondition(tabs.controllableSession(in: child) === originalSession)
    precondition(tabs.presentNativeSplit(nil, activeItemID: item, in: child))
    precondition(tabs.controllableSession(in: otherPrivate) === otherSelection)
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
    Native.privateCallback?(BARC_PROFILE_OK, 721, Native.privateContext); Native.privateCallback = nil; Native.privateContext = nil
    precondition(closed == [721] && registry.windows.count == count)
    var cancelDuringAdmission: (() -> Void)?
    cancelDuringAdmission = admission.openPrivateWindow(open: { callback, pointer in MainActor.assumeIsolated {
        Native.privateCallback = callback; Native.privateContext = pointer
    } }, close: { id in closed.append(id); Native.end(id); return 1 }, canPresent: {
        cancelDuringAdmission?(); return true
    })
    add(723, session: UUID(), factory: true)
    Native.privateCallback?(BARC_PROFILE_OK, 723, Native.privateContext); Native.privateCallback = nil; Native.privateContext = nil
    precondition(closed == [721, 723] && registry.windows.count == count)
    cancelDuringAdmission = nil
    // Synchronous completion is also valid; the exact factory blank is adopted
    // once rather than stolen by the ordinary catalog drain.
    add(722, session: UUID(), factory: true)
    Native.restoring = true
    let navigationsBefore = Native.restoredURLs.count
    _ = admission.openPrivateWindow(open: { callback, pointer in callback?(BARC_PROFILE_OK, 722, pointer) },
        close: { _ in preconditionFailure("Valid private factory was rejected") }, canPresent: { true })
    Native.restoring = false
    precondition(Native.restoredURLs.count == navigationsBefore + 1 &&
                 Native.restoredURLs.last == TabsController.homeURL.absoluteString,
                 "A private window opens WebKit's home page, not Chromium's")
    precondition(Native.admitted.contains(722))
    precondition(registry.windows.count == count + 1 && Native.shown == [722])
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(registry.windows.count == count + 1 && tabs.tree == originalTree && tabs.device == originalDevice)
    let childItem = originalSession.itemID
    Native.end(711)
    precondition(originalSession.navigation == nil && page.isClosed)
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(registry.windows[child.id] == nil && tabs.session(for: childItem) == nil)
    for id in Array(Native.windows.keys) { Native.end(id) }
    admission.apply(Native.bridge.readSnapshot()!)
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
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
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
    do {
        let initialRegistry = WindowRegistry()
        let initialRoot = root.appendingPathComponent("activation")
        let initialStore = TabStore(directory: initialRoot); initialStore.save(tree, device); initialStore.flush()
        let initialTabs = TabsController(settings: settings, windowRegistry: initialRegistry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: initialRoot)
        let initialHost = ChromiumNativePageHost(bridge: Native.bridge)
        initialTabs.nativePageHost = initialHost
        let initialAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: initialHost, tabs: initialTabs,
            registry: initialRegistry, isUtility: { _ in false }, makeShell: { _ in NSView() })
        let initial = initialAdmission.prepareInitialWindow()!
        let native: Int32 = 1090
        factory(native, profile: Native.work)
        precondition(initialAdmission.admitRestoredWindow(initial, native: native, profile: Native.work,
            show: false, canPresent: { true }))
        let catalog = ChromiumWindowCatalog(bridge: Native.bridge)
        catalog.onSnapshot = { initialAdmission.apply($0) }
        precondition(catalog.start())
        Native.publish()
        defer {
            Native.onCompleteStartup = nil
            Native.end(native)
            catalog.stop()
        }

        var focusChanges = 0
        initialRegistry.onActiveWindowChange = { _ in focusChanges += 1 }
        defer { initialRegistry.onActiveWindowChange = nil }
        Native.onCompleteStartup = { shown in
            precondition(shown == native)
            Native.windows[shown]?.flags |= UInt32(BARC_DISCOVERY_PHYSICAL_ACTIVE.rawValue)
            // No discovery delivery after Chromium makes the startup window key.
        }
        precondition(initialRegistry.activeWindow == nil)
        Native.bridge.runtime_complete_startup(native)
        let row = Native.bridge.windowState(native)!
        initialAdmission.reflectInitialActivation(row)
        precondition(initialRegistry.activeWindow === initial && focusChanges == 1,
                     "Completing startup must reflect the now-active window without a discovery delivery")
        Native.publish()
        precondition(focusChanges == 1, "The next discovery pass must not deliver the same focus twice")
    }

    // Real concrete host and native rows, with only delivery of an already
    // created background pane held back. Pending admission must not close/show.
    for mode in ["sync", "delayed", "refused", "closed", "new-selection"] {
        let delayed = mode != "sync"
        var splitDevice = device
        splitDevice.windows = [device.windows.last!]
        let splitRoot = root.appendingPathComponent("split-" + mode)
        let splitStore = TabStore(directory: splitRoot); splitStore.save(tree, splitDevice); splitStore.flush()
        let splitRegistry = WindowRegistry()
        let splitTabs = TabsController(settings: settings, windowRegistry: splitRegistry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: splitRoot)
        let concrete = ChromiumNativePageHost(bridge: Native.bridge)
        let delivery = DelayedCreationHost(concrete)
        splitTabs.nativePageHost = delivery
        let splitAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: concrete, tabs: splitTabs,
            registry: splitRegistry, isUtility: { _ in false }, makeShell: { _ in NSView() })
        let state = splitAdmission.prepareInitialWindow()!
        let native: Int32 = 1101 + Int32(["sync", "delayed", "refused", "closed", "new-selection"].firstIndex(of: mode)!)
        factory(native, profile: Native.work)
        let showsBefore = Native.shown.count
        var outcomes: [NativeSplitOutcome] = []
        let closedPagesBefore = Native.failedPrivateCloses.count
        delivery.delayedItem = delayed ? splitOther : nil
        precondition(splitAdmission.admitRestoredWindow(state, native: native, profile: Native.work,
            show: true, canPresent: { true }, completion: { outcomes.append($0) }))
        if delayed {
            precondition(delivery.isPending && outcomes.isEmpty && Native.shown.count == showsBefore)
            precondition(splitRegistry.windows[state.id] === state && state.split == split)
            if mode == "refused" { Native.servesPageViews = false }
            if mode == "closed" { splitRegistry.unregister(state.id) }
            if mode == "new-selection" { splitTabs.select(splitOther, in: state) }
            delivery.resolve()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let succeeds = mode == "sync" || mode == "delayed"
        let opens = succeeds || mode == "refused"
        let expected: NativeSplitOutcome = opens ? .admitted : (mode == "new-selection" ? .superseded : .refused)
        precondition(outcomes == [expected] && Native.shown.count == showsBefore + (opens ? 1 : 0), "\(mode): \(outcomes)")
        if mode == "refused" {
            precondition(state.split == nil && state.selectedItemID == first
                         && splitTabs.device.windows.first { $0.id == state.id }?.split == nil,
                         "a saved split the engine refuses is dropped, and the window opens on its selected tab alone")
        } else {
            precondition(state.split == split)
        }
        if succeeds { precondition(split.itemIDs.allSatisfy { splitTabs.session(for: $0)?.navigation != nil }) }
        if mode == "new-selection" { precondition(state.selectedItemID == splitOther) }
        if mode == "closed" { precondition(Native.failedPrivateCloses.count == closedPagesBefore + 1) }
        Native.servesPageViews = true
        Native.end(native)
        splitAdmission.apply(Native.bridge.readSnapshot()!)
    }
    // Exercise SavedRequest itself: tabs.select cancels synchronously before
    // publishing its new item, and must not let old refusal cleanup close it.
    do {
        let savedRoot = root.appendingPathComponent("saved-delayed-new-selection")
        var savedDevice = device; savedDevice.windows = [device.windows.last!]
        let savedStore = TabStore(directory: savedRoot); savedStore.save(tree, savedDevice); savedStore.flush()
        let savedRegistry = WindowRegistry()
        let savedTabs = TabsController(settings: settings, windowRegistry: savedRegistry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: savedRoot)
        let concrete = ChromiumNativePageHost(bridge: Native.bridge)
        let delivery = DelayedCreationHost(concrete); delivery.delayedItem = splitOther
        savedTabs.nativePageHost = delivery
        let savedAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: concrete, tabs: savedTabs,
            registry: savedRegistry, isUtility: { _ in false }, makeShell: { _ in NSView() })
        var closedOwners: [Int32] = []
        var reentered = false
        delivery.onPending = {
            let pendingState = savedRegistry.windows[splitID]!
            precondition(savedTabs.whenNativeSplitPrepared(split, activeItemID: first, in: pendingState) { outcome in
                if outcome == .superseded {
                    // Earlier completion finishes a new selection back to the
                    // original item before SavedRequest sees cancellation.
                    savedTabs.select(first, in: pendingState)
                    reentered = true
                }
            })
        }
        Native.onCloseWindow = { owner in closedOwners.append(owner); return 1 }
        savedAdmission.restoreSavedWindows(open: { _, _, callback, pointer in MainActor.assumeIsolated {
            factory(1110, profile: Native.work); callback?(BARC_PROFILE_OK, 1110, pointer)
        } }, close: { owner in closedOwners.append(owner); return 1 }, canPresent: { true })
        let state = savedRegistry.windows[splitID]!
        precondition(delivery.isPending && !Native.shown.contains(1110))
        savedTabs.select(splitOther, in: state)
        precondition(reentered && closedOwners.isEmpty && state.selectedItemID == splitOther)
        delivery.resolve()
        precondition(closedOwners.isEmpty && state.selectedItemID == splitOther)
        precondition(savedRegistry.windows[splitID] === state && Native.windows[1110] != nil)
        Native.onCloseWindow = nil
        Native.end(1110); savedAdmission.apply(Native.bridge.readSnapshot()!)
    }
    // Initial startup follows a legitimate newer presentation, including a
    // different profile/client in the same physical group. Completion is the
    // actual admitted ID, never a Show of the original factory client.
    for mode in ["personal", "reentrant", "refused", "creation-refused", "split-refused", "retired", "shutdown"] {
        let initialRoot = root.appendingPathComponent("initial-supersession-" + mode)
        var initialDevice = device; initialDevice.windows = [device.windows.last!]
        let initialStore = TabStore(directory: initialRoot); initialStore.save(tree, initialDevice); initialStore.flush()
        let initialRegistry = WindowRegistry()
        let initialTabs = TabsController(settings: settings, windowRegistry: initialRegistry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: initialRoot)
        let concrete = ChromiumNativePageHost(bridge: Native.bridge)
        let delivery = DelayedCreationHost(concrete); delivery.delayedItem = splitOther
        initialTabs.nativePageHost = delivery
        let coordinator = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: concrete, tabs: initialTabs,
            registry: initialRegistry, isUtility: { _ in false }, makeShell: { _ in NSView() })
        let state = coordinator.prepareInitialWindow()!
        factory(1120, profile: Native.work)
        var admitted: [Int32?] = []
        precondition(coordinator.admitRestoredWindow(state, native: 1120, profile: Native.work,
            show: false, canPresent: { true }, completion: { outcome in
                precondition(outcome == .superseded)
                precondition(coordinator.whenProductPresented(state) { admitted.append($0) })
            }))
        precondition(delivery.isPending && admitted.isEmpty)
        var selections: [Int32] = []
        var pendingOpen: (barc_profile_window_callback?, UnsafeMutableRawPointer?)?
        if mode == "personal" || mode == "reentrant" || mode == "refused" {
            Native.windows[1121] = Native.window(1121, group: 1120, profile: Native.personal,
                flags: 4, active: 11210)
            Native.windows[1121]?.selected_client = 1120
            Native.tabs.append(Native.tab(11210, window: 1121))
            let personalProfile = initialTabs.profile(forSpace: Native.personal)!
            let binding = try concrete.bindExistingPage(nativeWindow: 1121, tab: 11210,
                profile: personalProfile, in: state).get()
            let personalItem = initialTabs.adoptNativePage(binding.navigation, through: delivery,
                in: state, spaceID: Native.personal, select: false)!
            binding.finish(adopted: true)
            Native.onSelectWindow = { owner in
                selections.append(owner)
                if mode == "refused" { return 0 }
                for id in [Int32(1120), 1121] { Native.windows[id]?.selected_client = owner }
                return 1
            }
            if mode == "reentrant" {
                Native.onPageView = { owner in
                    guard owner == 1121 else { return }
                    Native.onPageView = nil
                    delivery.resolve() // Release the cancelled original pane.
                    delivery.delayedItem = splitOther
                    initialTabs.select(splitOther, in: state)
                }
            }
            initialTabs.select(personalItem, in: state)
            if mode == "reentrant" {
                precondition(admitted.isEmpty && state.nativePresentationIsPreparing && delivery.isPending)
                delivery.resolve()
                precondition(state.selectedItemID == splitOther && state.spaceID == Native.work)
            }
            if mode == "personal" {
                precondition(state.spaceID == Native.personal && state.selectedItemID == personalItem)
            }
        } else if mode == "split-refused" {
            Native.servesPageViews = false
            precondition(initialTabs.presentNativeSplit(SplitRecord([splitOther, first])!,
                activeItemID: first, in: state))
            precondition(admitted.count == 1 && admitted[0] == nil)
            Native.servesPageViews = true
        } else {
            Native.onOpen = { _, callback, pointer in
                if mode == "creation-refused" { callback?(BARC_PROFILE_FAILED, 0, pointer) }
                else { pendingOpen = (callback, pointer) }
            }
            initialTabs.select(selected, in: state)
            if mode == "creation-refused" { precondition(admitted.count == 1 && admitted[0] == nil) }
            else { precondition(pendingOpen != nil && admitted.isEmpty) }
        }
        if mode == "shutdown" { coordinator.cancelPendingProductPresentation() }
        if mode == "retired" { Native.end(1120); Native.end(1121) }
        coordinator.apply(Native.bridge.readSnapshot()!)
        let expected: Int32? = mode == "personal" ? 1121 : (mode == "reentrant" ? 1120 : nil)
        precondition(admitted == [expected])
        if mode != "reentrant" { precondition(!selections.contains(1120)) }
        precondition(!Native.shown.contains(1120))
        delivery.resolve()
        pendingOpen?.0?(BARC_PROFILE_FAILED, 0, pendingOpen?.1)
        Native.onOpen = nil
        coordinator.apply(Native.bridge.readSnapshot()!)
        precondition(admitted.count == 1)
        Native.onSelectWindow = nil
        Native.onPageView = nil
        Native.end(1120); Native.end(1121)
        coordinator.apply(Native.bridge.readSnapshot()!)
    }
    Native.restoredURLs.removeAll()
    do {
        let openingRoot = root.appendingPathComponent("opening")
        let openingStore = TabStore(directory: openingRoot)
        var openingDevice = device; openingDevice.windows = [device.windows[0]]
        openingStore.save(tree, openingDevice); openingStore.flush()
        let openingRegistry = WindowRegistry()
        let openingTabs = TabsController(settings: settings, windowRegistry: openingRegistry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: openingRoot)
        let openingAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: openingTabs,
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
        precondition(destination == BARC_PROFILE_BLANK)
        Native.savedRequests.append((UUID(uuidString: String(cString: profile!))!, callback, pointer))
    } }, close: { id in closed.append(id); Native.end(id); return 1 }, canPresent: { canPresent })
    precondition(Native.savedRequests.count == 4 && Native.savedRequests.prefix(3).allSatisfy { $0.0 == Native.personal })
    precondition(Native.savedRequests.last?.0 == Native.work)
    let requests = Native.savedRequests; Native.savedRequests = []
    // Explicit native factory refusal keeps the saved split available for retry.
    requests[3].1?(BARC_PROFILE_FAILED, 0, requests[3].2)
    precondition(registry.windows[splitID] == nil && tabs.device.windows.first { $0.id == splitID }?.split == split)
    factory(1002, profile: Native.personal); requests[0].1?(BARC_PROFILE_OK, 1002, requests[0].2)
    precondition(registry.windows[extraID]?.selectedItemID == selected)
    precondition(Native.restoredURLs == [rootURL.absoluteString, selectedURL.absoluteString])
    registry.setActive(initial)
    let snapshots = Native.snapshotReads
    precondition(admission.browserTarget(kind: 0, regularProfile: Native.personal)?.window == 1001)
    precondition(Native.snapshotReads == snapshots)
    let treeBeforeRoute = tabs.tree, deviceBeforeRoute = tabs.device
    let routed = admission.incomingTarget(ruleSpace: Native.personal, mini: true, regularProfile: Native.work)
    precondition(routed?.window == 1001 && routed?.profile == Native.personal &&
        routed?.space == Native.personal && routed?.mini == false) // Site rule precedes mini preference.
    let normal = admission.incomingTarget(ruleSpace: nil, mini: false, regularProfile: Native.personal)
    precondition(normal?.window == 1001 && normal?.profile == Native.work && normal?.space == Native.work)
    let mini = admission.incomingTarget(ruleSpace: nil, mini: true, regularProfile: Native.personal)
    precondition(mini?.window == 1001 && mini?.profile == nil && mini?.space == nil && mini?.mini == true)
    precondition(tabs.tree == treeBeforeRoute && tabs.device == deviceBeforeRoute && initial.spaceID == Native.work)
    let priorActive = Native.windows[1001]!.active_tab
    Native.windows[1001]?.active_tab = 12345
    Native.tabs.append(Native.tab(12345, window: 1001))
    precondition(admission.browserTarget(kind: 0, regularProfile: Native.work)?.window == -1)
    Native.tabs.removeAll { $0.tab == 12345 }; Native.windows[1001]?.active_tab = priorActive
    precondition(admission.browserTarget(kind: 0, regularProfile: Native.work)?.window == 1001)

    // A window on an empty space has no selected page and still receives links and Dock actions.
    let emptySpace = tabs.createSpace(name: "Empty", icon: "", accentHex: "#123456", after: Native.work, sharingLoginsWith: Native.work)!
    tabs.setSpace(emptySpace, in: initial)
    precondition(initial.showsNativeEmptySpace)
    precondition(admission.browserTarget(kind: 0, regularProfile: Native.work)?.window == 1001)
    precondition(admission.browserTarget(kind: 2, regularProfile: Native.work)?.window == 1001)
    let emptyRoute = admission.incomingTarget(ruleSpace: nil, mini: false, regularProfile: Native.work)
    precondition(emptyRoute?.window == 1001 && emptyRoute?.profile == Native.work && emptyRoute?.space == emptySpace)
    let emptyRouted = admission.incomingTarget(ruleSpace: Native.personal, mini: true, regularProfile: Native.work)
    precondition(emptyRouted?.window == 1001 && emptyRouted?.space == Native.personal)
    tabs.setSpace(Native.work, in: initial)
    tabs.deleteSpace(emptySpace)

    registry.setActive(registry.windows[extraID]!)
    precondition(admission.browserTarget(kind: 2, regularProfile: Native.work)?.window == 1002)
    precondition(admission.browserTarget(kind: 99, regularProfile: Native.work) == nil)
    registry.activeWindowId = nil // A settings/private window is frontmost.
    let frontRegular = admission.browserTarget(kind: 0, regularProfile: UUID())?.window
    precondition(frontRegular == 1001 || frontRegular == 1002)
    registry.setActive(registry.windows[extraID]!)


    factory(1003, profile: Native.personal); Native.rejectNextObservation = true
    requests[1].1?(BARC_PROFILE_OK, 1003, requests[1].2)
    precondition(registry.windows[failedID] == nil && tabs.device.windows.contains { $0.id == failedID })
    canPresent = false; factory(1004, profile: Native.personal)
    requests[2].1?(BARC_PROFILE_OK, 1004, requests[2].2)
    precondition(closed == [1003, 1004] && registry.windows[lateID] == nil)
    precondition(Native.restoredURLs == [rootURL.absoluteString, selectedURL.absoluteString])
    precondition(tabs.unclaimedWindowRecords().map(\.id).contains(failedID) && tabs.unclaimedWindowRecords().map(\.id).contains(lateID))
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(tabs.device.windows.count == 5 && tabs.tree.items.count == tree.items.count)
    // Show can reenter quit after product/host registration. Keep that model
    // registered while native close is pending or refused, and retry its same page.
    canPresent = true
    admission.restoreSavedWindows(open: { profile, _, callback, pointer in MainActor.assumeIsolated {
        Native.savedRequests.append((UUID(uuidString: String(cString: profile!))!, callback, pointer))
    } }, close: { _ in preconditionFailure("Bound restoration must retain its close observation") }, canPresent: { canPresent })
    let retries = Native.savedRequests; Native.savedRequests = []
    precondition(retries.count == 3)
    retries[2].1?(BARC_PROFILE_FAILED, 0, retries[2].2)
    var closeRequests: [Int32] = []
    Native.onCloseWindow = { id in closeRequests.append(id); return id == 1005 ? 1 : 0 }
    Native.onShow = { _ in canPresent = false; return 1 }
    factory(1005, profile: Native.personal); retries[0].1?(BARC_PROFILE_OK, 1005, retries[0].2)
    let pendingState = registry.windows[failedID]!
    let pendingPage = tabs.selectedSession(in: pendingState)!.navigation!
    precondition(closeRequests == [1005] && registry.windows[failedID] === pendingState)
    let loaded = Native.restoredURLs
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(!admission.shouldDetachModelWindow(pendingState))
    canPresent = true; Native.onShow = nil
    for (token, entry) in Native.observers.filter({ $0.value.2 == 1005 }) {
        entry.0?(entry.1, token, 8, 1005, entry.3, nil, nil, 0, 0)
    }
    precondition(registry.windows[failedID] === pendingState && tabs.selectedSession(in: pendingState)?.navigation === pendingPage)
    precondition(Native.restoredURLs == loaded && host.isNativeSelection(pendingPage, in: pendingState))
    // An immediate refusal also cannot unregister its still-live owner.
    Native.onShow = { _ in canPresent = false; return 1 }
    factory(1006, profile: Native.personal); retries[1].1?(BARC_PROFILE_OK, 1006, retries[1].2)
    let refusedState = registry.windows[lateID]!
    let refusedPage = tabs.selectedSession(in: refusedState)!.navigation!
    precondition(closeRequests == [1005, 1006] && registry.windows[lateID] === refusedState)
    precondition(host.isNativeSelection(refusedPage, in: refusedState))
    let retainedRecord = tabs.device.windows.first { $0.id == lateID }
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(!admission.shouldDetachModelWindow(refusedState))
    Native.end(1006); admission.apply(Native.bridge.readSnapshot()!)
    precondition(registry.windows[lateID] == nil && tabs.device.windows.first { $0.id == lateID } == retainedRecord)
    canPresent = true; Native.onShow = nil
    admission.resumeRestoredWindows(canPresent: { canPresent })
    precondition(Native.restoredURLs.count == loaded.count + 1)
    Native.onCloseWindow = nil
    tabs.flushSync() // Accepted app-close notification, before either group retires.
    Native.end(1001); Native.end(1002); Native.end(1005); Native.end(1006)
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(registry.windows.isEmpty && Set(tabs.device.windows.map(\.id)) == Set(device.windows.map(\.id)))
    let noWindow = admission.browserTarget(kind: 2, regularProfile: Native.personal)
    precondition(noWindow?.window == 0 && noWindow?.regularProfile == Native.personal)
    precondition(admission.browserTarget(kind: 0, regularProfile: UUID()) == nil)

    tabs.saveNow()
    let saved = TabStore(directory: root).load()
    precondition(Set(saved.device.windows.map(\.id)) == Set(device.windows.map(\.id)) && saved.device.windows.first { $0.id == splitID }?.split == split)
}

@MainActor private func checkNewWindowLikeWebKit() throws {
    let root = URL(fileURLWithPath: "/private/tmp/BarcNewWindow-\(UUID())", isDirectory: true)
    let suite = "BarcNewWindow-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "house", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "house", accentHex: "#123456", after: Native.work)
    let first = UUID(), second = UUID()
    _ = try tree.createTab(id: first, url: URL(string: "https://fixture.invalid/new-window-first")!, title: "First",
                           in: .tabs(spaceID: Native.work), after: nil)
    _ = try tree.createTab(id: second, url: URL(string: "https://fixture.invalid/new-window-second")!, title: "Second",
                           in: .tabs(spaceID: Native.work), after: first)
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    func make(_ name: String, records: [WindowRecord]) -> (ChromiumCreatedPageAdmission, TabsController, WindowRegistry) {
        let directory = root.appendingPathComponent(name)
        var device = DeviceState(); device.firstLaunchCompleted = true; device.windows = records
        let store = TabStore(directory: directory); store.save(tree, device); store.flush()
        let registry = WindowRegistry()
        let tabs = TabsController(settings: settings, windowRegistry: registry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: directory)
        let host = ChromiumNativePageHost(bridge: Native.bridge)
        tabs.nativePageHost = host
        let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
            registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
        return (admission, tabs, registry)
    }
    func factory(_ id: Int32, profile: UUID) {
        Native.windows[id] = Native.window(id, group: UInt64(id), profile: profile, flags: 4 | 8, active: id * 10)
        Native.tabs.append(Native.tab(id * 10, window: id, flags: 2))
    }
    Native.restoring = true; defer { Native.restoring = false }

    // No saved window to claim: the first space, its first tab selected, no tab added.
    do {
        let (admission, tabs, registry) = make("first-space", records: [])
        Native.profileOpens = []
        precondition(admission.openNewWindow(open: { profile, destination, callback, pointer in MainActor.assumeIsolated {
            Native.profileOpens.append((String(cString: profile!), destination))
            factory(1301, profile: Native.work); callback?(BARC_PROFILE_OK, 1301, pointer)
        } }, close: { _ in preconditionFailure("The new window was closed") }, canPresent: { true }))
        let state = registry.windows.values.first!
        precondition(registry.windows.count == 1 && Native.profileOpens.count == 1 && Native.profileOpens[0].1 == BARC_PROFILE_BLANK &&
                     UUID(uuidString: Native.profileOpens[0].0) == Native.work)
        precondition(state.spaceID == Native.work && state.selectedItemID == first, "The first space's first tab shows")
        precondition(Set(tabs.items(inSpace: Native.work).map(\.id)) == [first, second] &&
                     tabs.items(inSpace: Native.personal).isEmpty, "New Window adds no tab")
        precondition(Native.shown.last == 1301)
        Native.end(1301); admission.apply(Native.bridge.readSnapshot()!)
    }

    // A saved window nobody claimed comes back; on an empty space it shows the panel.
    do {
        let record = WindowRecord(id: UUID(), spaceID: Native.personal, selectedItemBySpace: [:])
        let (admission, tabs, registry) = make("saved-empty", records: [record])
        precondition(admission.openNewWindow(open: { profile, _, callback, pointer in MainActor.assumeIsolated {
            precondition(UUID(uuidString: String(cString: profile!)) == Native.personal)
            factory(1302, profile: Native.personal); callback?(BARC_PROFILE_OK, 1302, pointer)
        } }, close: { _ in preconditionFailure("The new window was closed") }, canPresent: { true }))
        let state = registry.windows.values.first!
        precondition(state.spaceID == Native.personal && state.selectedItemID == nil && state.showsNativeEmptySpace,
                     "An empty space shows the empty-space panel")
        precondition(tabs.items(inSpace: Native.personal).isEmpty, "No blank tab is added to the empty space")
        precondition(tabs.device.windows.count == 1 && tabs.device.windows[0].id == state.id, "The saved window is claimed")
        precondition(Native.shown.last == 1302)
        Native.end(1302); admission.apply(Native.bridge.readSnapshot()!)
    }

    // The first tab is shown in another window: the new window says it is open there, as in
    // WebKit mode, and moves nothing until asked. "Move Here" moves it either way, and once
    // the window holding it closes the other one shows the page itself.
    do {
        let (admission, tabs, registry) = make("shown-elsewhere", records: [])
        Native.transfersEnabled = true; defer { Native.transfersEnabled = false }
        Native.onSelectWindow = { window in Native.windows[window]?.selected_client = window; return 1 }
        defer { Native.onSelectWindow = nil }
        Native.windows[1310] = Native.window(1310, group: 1310, profile: Native.work, active: 13100)
        Native.tabs += [Native.tab(13100, window: 1310), Native.tab(13101, window: 1310)]
        admission.apply(Native.bridge.readSnapshot()!)
        let holder = registry.allWindows.first!
        let top = tabs.displayOrder(in: holder).first!
        tabs.select(top, in: holder)
        let page = tabs.session(for: top)!.navigation as! ChromiumPageNavigation
        precondition(holder.selectedItemID == top && page.nativeWindowID == 1310)
        let transfers = Native.transferCount
        precondition(admission.openNewWindow(open: { _, _, callback, pointer in MainActor.assumeIsolated {
            factory(1311, profile: Native.work); callback?(BARC_PROFILE_OK, 1311, pointer)
        } }, close: { _ in preconditionFailure("The new window was closed") }, canPresent: { true }))
        let state = registry.allWindows.first { $0 !== holder }!
        precondition(state.selectedItemID == top && tabs.showsPageElsewhere(in: state), "It is open in another window")
        precondition(Native.shown.last == 1311, "The new window shows at once")
        precondition(Native.transferCount == transfers && page.nativeWindowID == 1310, "Nothing moved")

        tabs.takeControl(top, in: state)
        precondition(page.nativeWindowID == 1311 && tabs.pageOwnerWindow(of: top) === state, "Move Here moves the live page")
        precondition(tabs.showsPageElsewhere(in: holder) && !tabs.showsPageElsewhere(in: state))
        Native.windows[1310]?.active_tab = 13101
        admission.apply(Native.bridge.readSnapshot()!)
        precondition(holder.selectedItemID == top, "Chromium's tab in the first window is not mirrored")
        tabs.takeControl(top, in: holder)
        precondition(page.nativeWindowID == 1310 && tabs.showsPageElsewhere(in: state))

        Native.end(1310)
        admission.apply(Native.bridge.readSnapshot()!)
        precondition(registry.windows[holder.id] == nil && !tabs.showsPageElsewhere(in: state))
        tabs.showSelectedPageHere(in: state)
        let reopened = tabs.session(for: top)?.navigation as? ChromiumPageNavigation
        precondition(reopened?.nativeWindowID == 1311 && state.selectedItemID == top, "The page opens where it shows")
        Native.end(1311); admission.apply(Native.bridge.readSnapshot()!)
    }

    // Whatever it selects, a new window never waits forever: the first tab is live in a
    // window that does not show it, and moving it into the new window fails.
    do {
        let (admission, tabs, registry) = make("refused-move", records: [])
        Native.transfersEnabled = true; Native.refusesTransfers = true
        defer { Native.transfersEnabled = false; Native.refusesTransfers = false }
        Native.onSelectWindow = { window in Native.windows[window]?.selected_client = window; return 1 }
        Native.onCloseWindow = { window in Native.end(window); return 1 }
        defer { Native.onSelectWindow = nil; Native.onCloseWindow = nil }
        Native.windows[1320] = Native.window(1320, group: 1320, profile: Native.work, active: 13200)
        Native.tabs += [Native.tab(13200, window: 1320), Native.tab(13201, window: 1320)]
        admission.apply(Native.bridge.readSnapshot()!)
        let holder = registry.allWindows.first!
        let order = tabs.displayOrder(in: holder)
        tabs.select(order[0], in: holder); tabs.select(order[1], in: holder)
        precondition(holder.selectedItemID == order[1] && tabs.session(for: order[0])?.navigation != nil)
        var closed: [Int32] = []
        _ = admission.openNewWindow(open: { _, _, callback, pointer in MainActor.assumeIsolated {
            factory(1321, profile: Native.work); callback?(BARC_PROFILE_OK, 1321, pointer)
        } }, close: { id in closed.append(id); Native.end(id); return 1 }, canPresent: { true })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(closed == [1321] && registry.allWindows.count == 1, "The failed window closes")
        Native.end(1320); admission.apply(Native.bridge.readSnapshot()!)
    }
}

@MainActor private func checkPendingProfileRecoveryWindow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcPendingRecovery-\(UUID())")
    let defaults = UserDefaults(suiteName: "BarcPendingRecovery-\(UUID())")!
    defer { try? FileManager.default.removeItem(at: root) }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "house", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "house", accentHex: "#123456", after: Native.work)
    let source = tree.dataStoreID(for: Native.work)!, survivor = tree.dataStoreID(for: Native.personal)!
    let item = UUID(), recordID = UUID()
    _ = try tree.createTab(id: item, url: URL(string: "https://fixture.invalid/pending-source")!,
        title: "Source", in: .tabs(spaceID: Native.work), after: nil)
    let retained = WindowRecord(id: recordID, spaceID: Native.work, selectedItemBySpace: [Native.work: item])
    var device = DeviceState(); device.firstLaunchCompleted = true; device.windows = [retained]
    device.pendingProfileDeletion = PendingProfileDeletion(target: source, survivor: survivor,
        change: PendingProfileChange(kind: .deleteProfile, spaceIDs: [Native.work],
            source: KeptProfile(tree.profiles.first { $0.id == source }!), newDestination: nil, windowIDs: [recordID]))
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let registry = WindowRegistry()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in preconditionFailure("Recovery must not attach before native admission") })
    var reconciliations = 0, retries = 0
    tabs.onDeleteProfile = { intent, reconcileOnly, canDelete, done in
        precondition(intent.target == source && intent.survivor == survivor && canDelete())
        if reconcileOnly { reconciliations += 1 } else { retries += 1 }
        done(.pending) // No close admission or wipe occurs.
    }
    tabs.resumePendingProfileDeletion { _ in }
    let recovered = admission.prepareInitialWindow()!
    precondition(recovered.id != recordID && recovered.spaceID == Native.personal && recovered.selectedItemID == nil)
    precondition(tabs.profile(forSpace: recovered.spaceID!)?.id == survivor)
    precondition(tabs.device.windows == [retained] && tabs.tree == tree)
    precondition(tabs.device.pendingProfileDeletion != nil && reconciliations == 1)
    admission.restoreSavedWindows(open: { _, _, _, _ in preconditionFailure("Unavailable target was opened") },
        close: { _ in preconditionFailure("Recovery closed native page") }, canPresent: { true })
    tabs.retryPendingProfileChange { _ in }
    precondition(retries == 1 && tabs.device.windows == [retained] && tabs.tree.item(item) != nil)
    registry.unregister(recovered.id)
    // An eligible saved window takes precedence, retaining its original ID.
    let eligible = WindowRecord(id: UUID(), spaceID: Native.personal)
    var next = tabs.device; next.windows.append(eligible)
    let alternate = root.appendingPathComponent("alternate")
    let nextStore = TabStore(directory: alternate); nextStore.save(tree, next); nextStore.flush()
    let nextRegistry = WindowRegistry()
    let nextTabs = TabsController(settings: settings, windowRegistry: nextRegistry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: alternate)
    let nextAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: nextTabs,
        registry: nextRegistry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    precondition(nextAdmission.prepareInitialWindow()?.id == eligible.id)
    precondition(nextTabs.device.windows.first { $0.id == recordID } == retained)
    // A kept-only survivor cannot borrow a space from an unavailable target.
    var keptTree = tree; _ = try keptTree.deleteSpace(Native.personal)
    var keptDevice = device; keptDevice.keptProfiles = [KeptProfile(id: survivor, name: "Personal")]
    let keptRoot = root.appendingPathComponent("kept-only")
    let keptStore = TabStore(directory: keptRoot); keptStore.save(keptTree, keptDevice); keptStore.flush()
    let keptRegistry = WindowRegistry()
    let keptTabs = TabsController(settings: settings, windowRegistry: keptRegistry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: keptRoot)
    let keptAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: keptTabs,
        registry: keptRegistry, isUtility: { _ in false }, makeShell: { _ in preconditionFailure() })
    precondition(keptAdmission.prepareInitialWindow() == nil && keptRegistry.windows.isEmpty)
    precondition(keptTabs.tree == keptTree && keptTabs.device.windows == [retained])

    // Ordinary startup still lets attach normalize stale saved-space IDs.
    var staleDevice = DeviceState(); staleDevice.firstLaunchCompleted = true
    staleDevice.windows = [WindowRecord(id: recordID, spaceID: UUID())]
    let staleRoot = root.appendingPathComponent("ordinary-stale")
    let staleStore = TabStore(directory: staleRoot); staleStore.save(keptTree, staleDevice); staleStore.flush()
    let staleRegistry = WindowRegistry()
    let staleTabs = TabsController(settings: settings, windowRegistry: staleRegistry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: staleRoot)
    let staleAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: staleTabs,
        registry: staleRegistry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    let normalized = staleAdmission.prepareInitialWindow()
    precondition(normalized?.id == recordID && normalized?.spaceID == Native.work)
    precondition(staleTabs.device.windows.first?.id == recordID && staleTabs.tree == keptTree)

    // Successful admitted retry reuses normal saved-window restoration, retaining
    // the original item/window IDs and requesting only the explicit survivor.
    Native.savedRequests = []
    tabs.onProfileWindowsNeedReload = { ids in
        admission.reloadProfileWindows(ids, open: { profile, _, callback, pointer in MainActor.assumeIsolated {
            Native.savedRequests.append((UUID(uuidString: String(cString: profile!))!, callback, pointer))
        } }, close: { _ in preconditionFailure("Retry closed a foreign window") }, canPresent: { true })
    }
    tabs.onDeleteProfile = { requested, reconcileOnly, canDelete, done in
        precondition(!reconcileOnly && requested.target == source && requested.survivor == survivor && canDelete())
        done(.closeAdmitted(continueCleanup: { cleanup in cleanup(.deleted) }))
    }
    var completed = false
    tabs.retryPendingProfileChange { if case .success = $0 { completed = true } }
    precondition(completed && tabs.device.pendingProfileDeletion == nil)
    precondition(tabs.tree.dataStoreID(for: Native.work) == survivor && tabs.tree.item(item) != nil)
    precondition(Native.savedRequests.count == 1 && Native.savedRequests[0].0 == survivor)
    let retry = Native.savedRequests.removeFirst()
    retry.1?(BARC_PROFILE_CANCELLED, 0, retry.2) // Bounded refused factory: keep the saved record for a later retry.
    precondition(tabs.device.windows.contains { $0.id == recordID })

}

/// A mini window that is a Bark window: the controller gives it a compact root with the header over
/// the page, and makes none of the old window's shell calls. A second tab's controller cannot take
/// the window; ending takes the header out.
@MainActor private func miniWindowSelects(_ window: Int32, _ tab: Int32) -> Bool {
    guard let row = Native.windows[window] else { return false }
    return row.selected_client == window && row.active_tab == tab &&
        row.flags & BARC_DISCOVERY_COMPACT_MINI.rawValue != 0 &&
        row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0
}

@MainActor private func checkMiniInBarkWindow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcBarkMini-\(UUID())")
    let suite = "BarcBarkMini-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    Native.windows.removeAll(); Native.tabs.removeAll(); Native.observers.removeAll(); Native.roots = [:]
    defer { Native.pageViews = [:]; Native.roots = [:] }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let registry = WindowRegistry()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let profile = tabs.profile(forSpace: Native.work)!
    Native.windows[2101] = Native.window(2101, group: 2101, profile: Native.work, kind: 1,
                                         flags: 4 | UInt32(BARC_DISCOVERY_COMPACT_MINI.rawValue), active: 21001)
    Native.tabs = [Native.tab(21001, window: 2101), Native.tab(21002, window: 2101)]
    Native.miniShellCalls = []; Native.miniCloses = []
    var miniBridge = Native.bridge
    miniBridge.window_set_root_view = { window, pointer in MainActor.assumeIsolated {
        guard window == 2101, let pointer else { return 0 }
        if let previous = Native.roots[window] { return previous == pointer ? 1 : 0 }
        Native.roots[window] = pointer
        let root = Unmanaged<ChromiumCompactRoot>.fromOpaque(pointer).takeUnretainedValue()
        let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        popup.contentView = root
        // The engine can show the window as soon as AppKit has installed this root.
        let header = root.subviews.first { !$0.isHidden && $0.frame.height == ChromiumCompactRoot.headerHeight }
        precondition(header != nil && root.shownTab == 21001 && Native.pageViews[21001]?.isDescendant(of: root) == true,
                     "The first popup frame must contain its header and its live page")
        popup.contentView = nil
        return 1
    } }
    miniBridge.window_attach_native_shell = { _, _ in MainActor.assumeIsolated { Native.miniShellCalls.append("attach"); return 0 } }
    miniBridge.window_detach_native_shell_if_owned = { _, _ in MainActor.assumeIsolated { Native.miniShellCalls.append("detach"); return 0 } }
    miniBridge.window_admit_discovered = { _, _ in MainActor.assumeIsolated { Native.miniShellCalls.append("admit"); return 0 } }
    miniBridge.tab_close = { _, tab in MainActor.assumeIsolated { Native.miniCloses.append(tab); return 1 } }
    var api = ChromiumMiniWindowAPI(bridge: miniBridge, canUse: miniWindowSelects)
    api.installCommandOMonitor = { _, _ in NSObject() }
    api.removeCommandOMonitor = { _ in }
    func controller(_ tab: Int32, ended: @escaping () -> Void = {}) -> ChromiumMiniWindowController {
        let navigation = try! ChromiumPageNavigation(profileID: profile.id, window: 2101, tab: tab, bridge: miniBridge)
        return ChromiumMiniWindowController(tabs: tabs, profile: profile, navigation: navigation, origin: nil, api: api,
                                            promote: { _, _ in false }, onEnd: { _ in ended() })!
    }
    var ended = 0
    let mini = controller(21001) { ended += 1 }
    precondition(mini.present(canPresent: { true }) && mini.isPresented, "the mini window is presented")
    let compact = Native.roots[2101].map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() } as? ChromiumCompactRoot
    precondition(compact != nil && Native.pageViews[21001]?.isDescendant(of: compact!) == true && compact!.shownTab == 21001,
                 "its window's root is a compact root showing the page")
    precondition(Native.miniShellCalls.isEmpty, "no call reaches the old window's shell: \(Native.miniShellCalls)")
    let headerAndPage = compact!.subviews.count
    precondition(headerAndPage == 2, "the header over the page")
    precondition(mini.present(canPresent: { true }) && Native.roots.count == 1, "presenting again changes nothing")
    let second = controller(21002)
    Native.windows[2101]?.active_tab = 21002
    precondition(!second.present(canPresent: { true }) && second.presentationRefused,
                 "a second tab's controller cannot take the window")
    Native.windows[2101]?.active_tab = 21001
    precondition(mini.isPresented && Native.pageViews[21001]?.isDescendant(of: compact!) == true && Native.pageViews[21002]?.superview == nil,
                 "refusing a second root preserves the admitted page")
    let mountedRoot = Native.roots.removeValue(forKey: 2101)
    precondition(!mini.isPresented, "a retained local header does not prove native root ownership")
    mini.close()
    precondition(Native.miniCloses.isEmpty)
    Native.roots[2101] = mountedRoot
    mini.close()
    precondition(Native.miniCloses == [21001], "Close closes the page")
    for (token, observer) in Native.observers where observer.3 == 21001 {
        observer.0?(observer.1, token, 7, 2101, 21001, nil, nil, 0, 0)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(ended == 1 && !mini.isPresented && compact!.subviews.count == headerAndPage - 1, "ending takes the header out")
    Native.end(2101)
    Native.viewless.insert(21003)
    defer { Native.viewless.remove(21003) }
    Native.roots[2101] = nil
    Native.windows[2101] = Native.window(2101, group: 2101, profile: Native.work, kind: 1,
                                         flags: 4 | UInt32(BARC_DISCOVERY_COMPACT_MINI.rawValue), active: 21003)
    Native.tabs.append(Native.tab(21003, window: 2101))
    let unsupported = controller(21003)
    precondition(!unsupported.present(canPresent: { true }) && unsupported.presentationRefused)
    precondition(Native.roots[2101] == nil && Native.miniShellCalls.isEmpty && Native.miniCloses == [21001])
    Native.end(2101)
    tabs.saveNow()
}

@MainActor private final class MiniRegistry: ChromiumMiniRegistry {
    var controllers: [any DetachedPageWindowController] = []
    func nativeController(tab: Int32) -> (any DetachedPageWindowController)? { controllers.first { $0.nativeTabID == tab } }
    func retainNative(_ controller: any DetachedPageWindowController) -> Bool {
        guard nativeController(tab: controller.nativeTabID ?? 0) == nil else { return false }
        controllers.append(controller); return true
    }
    func relinquishNativeHeader(window: Int32, except tab: Int32) {
        for controller in controllers where controller.nativeWindowID == window && controller.nativeTabID != tab { controller.relinquishNativeHeader() }
    }
}

/// Every compact window that waits for the app ends the drain shown or with its tab closed: one of
/// a profile the app does not know is closed, one it knows is shown in the same drain, with its
/// opener's window as its origin; while the app accepts no windows, a waiting one is closed.
@MainActor private func checkMiniPagesAdmitOrClose() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcMiniDrain-\(UUID())")
    let suite = "BarcMiniDrain-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    Native.windows.removeAll(); Native.tabs.removeAll(); Native.observers.removeAll(); Native.roots = [:]
    defer { Native.pageViews = [:]; Native.roots = [:] }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let registry = WindowRegistry()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let opener = BrowserWindowState(); opener.spaceID = Native.work
    registry.register(opener); tabs.attach(window: opener, restoringSavedState: false)
    let profile = tabs.profile(forSpace: Native.work)!
    Native.windows[2203] = Native.window(2203, group: 2203, profile: Native.work, flags: 4, active: 22030)
    Native.tabs = [Native.tab(22030, window: 2203)]
    let openerShell = NSView()
    precondition(host.registerWindow(opener, nativeOwner: 2203, shell: openerShell))
    guard case .success(let binding) = host.bindExistingPage(nativeWindow: 2203, tab: 22030, profile: profile, in: opener) else { preconditionFailure() }
    _ = tabs.adoptNativePage(binding.navigation, through: host, in: opener, spaceID: Native.work, select: false)
    binding.finish(adopted: true)
    let other = BrowserWindowState(); other.spaceID = Native.work
    registry.register(other)

    let waiting = UInt32(BARC_DISCOVERY_AWAITING_ADMISSION.rawValue) | UInt32(BARC_DISCOVERY_COMPACT_MINI.rawValue) | 4
    Native.windows[2201] = Native.window(2201, group: 2201, profile: UUID(), kind: 1, flags: waiting, active: 22010)
    Native.windows[2202] = Native.window(2202, group: 2202, profile: Native.work, kind: 1, flags: waiting, active: 22020)
    Native.tabs += [Native.tab(22010, window: 2201), Native.tab(22020, window: 2202, opener: 22030)]
    Native.miniCloses = []
    var miniBridge = Native.bridge
    miniBridge.tab_close = { _, tab in MainActor.assumeIsolated { Native.miniCloses.append(tab); return 1 } }
    var onCanUse: ((Int32, Int32) -> Void)?
    var api = ChromiumMiniWindowAPI(bridge: miniBridge, canUse: { window, tab in
        onCanUse?(window, tab)
        return miniWindowSelects(window, tab)
    })
    api.installCommandOMonitor = { _, _ in NSObject() }
    api.removeCommandOMonitor = { _ in }
    let minis = MiniRegistry()
    var origins: [Int32: BrowserWindowState?] = [:]
    var onMake: ((Int32) -> Void)?
    let pages = ChromiumMiniPages(bridge: miniBridge, tabs: tabs, registry: minis) { profile, navigation, origin in
        origins[navigation.nativeTabID] = origin
        onMake?(navigation.nativeTabID)
        return ChromiumMiniWindowController(tabs: tabs, profile: profile, navigation: navigation, origin: origin, api: api,
                                            promote: { _, _ in false }, onEnd: { _ in })
    }
    pages.apply(Native.bridge.readSnapshot()!, accepting: { true }, activeWindow: other)
    precondition(Native.miniCloses == [22010], "a waiting window of a profile the app does not know has its tab closed: \(Native.miniCloses)")
    let shown = minis.nativeController(tab: 22020) as? ChromiumMiniWindowController
    precondition(shown?.isPresented == true && Native.roots[2202] != nil, "a waiting window the app knows is shown in the same drain")
    precondition(origins[22020].map { $0 === opener } == true, "a page popup's origin is its opener's window, not the active one")

    Native.end(2201)
    Native.windows[2202]?.flags &= ~UInt32(BARC_DISCOVERY_AWAITING_ADMISSION.rawValue)
    pages.apply(Native.bridge.readSnapshot()!, accepting: { true }, activeWindow: other)
    precondition(shown?.isPresented == true && Native.miniCloses == [22010], "a shown window stays")

    // Keep the original controller's live header while a captured row reports
    // a different selected tab and an earlier pending admission.
    for (alternate, supersededWhileBinding) in [(Int32(22021), false), (Int32(22022), true)] {
        Native.tabs.append(Native.tab(alternate, window: 2202))
        Native.windows[2202]?.active_tab = alternate
        Native.windows[2202]?.flags = waiting
        let snapshot = Native.bridge.readSnapshot()!
        func selectAlreadyShown() {
            Native.windows[2202]?.active_tab = 22020
            Native.windows[2202]?.flags &= ~UInt32(BARC_DISCOVERY_AWAITING_ADMISSION.rawValue)
        }
        var superseded = false
        if supersededWhileBinding {
            onMake = { tab in
                guard tab == alternate else { return }
                superseded = true
                selectAlreadyShown()
            }
        } else {
            selectAlreadyShown()
        }
        pages.apply(snapshot, accepting: { true }, activeWindow: other)
        onMake = nil
        precondition(superseded == supersededWhileBinding, "controller creation synchronously selected the existing page")
        precondition(shown?.isPresented == true && Native.miniCloses == [22010],
                     "a stale compact row cannot strip the currently selected page's header or close its tabs")
    }

    // Even after the selection initially passed validation, a callback from
    // presentation can admit a successor before the old attempt returns.
    Native.windows[2205] = Native.window(2205, group: 2205, profile: Native.work, kind: 1, flags: waiting, active: 22050)
    Native.tabs += [Native.tab(22050, window: 2205), Native.tab(22051, window: 2205)]
    var attempted = false
    onCanUse = { window, tab in
        guard window == 2205, tab == 22050 else { return }
        attempted = true
        Native.windows[2205]?.active_tab = 22051
        Native.windows[2205]?.flags &= ~UInt32(BARC_DISCOVERY_AWAITING_ADMISSION.rawValue)
    }
    pages.apply(Native.bridge.readSnapshot()!, accepting: { true }, activeWindow: other)
    onCanUse = nil
    precondition(attempted && Native.miniCloses == [22010],
                 "a refused presentation may not close the successor admitted during its callback")

    // Legacy discovery can report an awaiting client in a physical window
    // with another selected client. It cannot make the group's close decision.
    Native.windows[2206] = Native.window(2206, group: 2205, profile: UUID(), kind: 1, flags: waiting, active: 22060)
    Native.windows[2206]?.selected_client = 2205
    Native.tabs.append(Native.tab(22060, window: 2206))
    pages.apply(Native.bridge.readSnapshot()!, accepting: { true }, activeWindow: other)
    precondition(Native.miniCloses == [22010], "an unselected waiting client cannot close the window's pages")

    Native.miniCloses = []
    Native.windows[2204] = Native.window(2204, group: 2204, profile: Native.work, kind: 1, flags: waiting, active: 22040)
    Native.tabs += [Native.tab(22040, window: 2204), Native.tab(22041, window: 2204)]
    pages.apply(Native.bridge.readSnapshot()!, accepting: { false }, activeWindow: other)
    precondition(Native.miniCloses == [22041, 22040] && Native.roots[2204] == nil,
                 "while the app accepts no windows a selected waiting window closes its background tab and then its active tab")
    for owner in Array(Native.windows.keys) { Native.end(owner) }
    withExtendedLifetime(openerShell) {}
    tabs.saveNow()
}

@MainActor private func checkDetachedMiniPromotion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcMini-\(UUID())")
    let suite = "BarcMini-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    Native.windows.removeAll(); Native.tabs.removeAll(); Native.observers.removeAll()
    Native.roots = [:]
    Native.transfersEnabled = true; Native.transferCount = 0; Native.miniCloseRequests = 0
    defer {
        Native.transfersEnabled = false; Native.restoring = false
        Native.pageViews = [:]; Native.roots = [:]
    }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "house", accentHex: "#123456", after: Native.work)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let untouchedSaved = WindowRecord(id: UUID(), spaceID: Native.personal)
    device.windows = [untouchedSaved]
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let registry = WindowRegistry()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let sharedSpace = tabs.createSpace(name: "Shared Work", icon: "folder", accentHex: "#123456",
                                      after: Native.work, sharingLoginsWith: Native.work)!
    let window = BrowserWindowState(); window.spaceID = Native.work
    registry.register(window); tabs.attach(window: window, restoringSavedState: false)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    Native.windows[2001] = Native.window(2001, group: 2001, profile: Native.work, kind: 1, flags: BARC_DISCOVERY_COMPACT_MINI.rawValue, active: 20001)
    Native.windows[2002] = Native.window(2002, group: 2002, profile: Native.work, active: 20002)
    Native.tabs = [Native.tab(20001, window: 2001), Native.tab(20002, window: 2002)]
    let shell = NSView()
    precondition(host.registerWindow(window, nativeOwner: 2002, shell: shell))
    let profile = tabs.profile(forSpace: Native.work)!
    let navigation = try ChromiumPageNavigation(profileID: profile.id, window: 2001, tab: 20001, bridge: Native.bridge)
    let originalTree = tabs.tree, originalDevice = tabs.device
    var reject = true, ended = 0
    var keyHandler: ChromiumMiniWindowAPI.CommandOMonitor?
    var monitorInstalls = 0, monitorRemovals = 0, eventScopeMatches = true
    var shares: [(URL, NSView)] = []
    var copies: [UUID] = []
    var miniBridge = Native.bridge
    miniBridge.window_admit_discovered = { _, _ in 1 }
    miniBridge.tab_close = { _, _ in
        MainActor.assumeIsolated { Native.miniCloseRequests += 1; return 1 }
    }
    var api = ChromiumMiniWindowAPI(bridge: miniBridge, canUse: miniWindowSelects)
    let defaultScope = api.eventBelongsToHeader
    api.installCommandOMonitor = { _, handler in monitorInstalls += 1; keyHandler = handler; return NSObject() }
    api.removeCommandOMonitor = { _ in monitorRemovals += 1; keyHandler = nil }
    api.eventBelongsToHeader = { _, _ in eventScopeMatches }
    api.shareURL = { url, header in shares.append((url, header)); return NSObject() }
    let choices = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    let controller = ChromiumMiniWindowController(tabs: tabs, profile: profile, navigation: navigation,
        origin: window, api: api, promote: { session, requested in
            host.promoteDetachedPage(navigation, profile: profile, to: 2002, in: window) {
                guard !reject, host.acceptNativeSelection(navigation, in: window),
                      let id = tabs.adoptDetachedNativePage(session, through: host, in: window,
                          spaceID: requested ?? Native.work, select: false),
                      registry.windows[window.id] === window, tabs.session(for: id) === session,
                      tabs.isNativePageOwner(session, in: window), session.navigation === navigation,
                      host.canAdoptPage(navigation, in: window) else { return false }
                _ = tabs.reflectNativeSelection(id, in: window)
                return registry.windows[window.id] === window && tabs.session(for: id) === session &&
                    tabs.isNativePageOwner(session, in: window) && session.navigation === navigation
            }
        }, destinations: { choices.miniDestinations(for: $0) },
        openCopy: { _, space in copies.append(space); return true },
        onEnd: { _ in ended += 1 })!
    let session = controller.page
    precondition(controller.present(canPresent: { true }))
    precondition(monitorInstalls == 1 && keyHandler != nil)
    precondition(controller.present(canPresent: { true }) && monitorInstalls == 1)
    let commandO = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31)!
    let repeated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: true, keyCode: 31)!
    precondition(!defaultScope(commandO, NSView())) // nil window must not match nil.
    eventScopeMatches = false // Another window or an attached sheet keeps normal dispatch.
    precondition(keyHandler?(commandO) === commandO && Native.transferCount == 0)
    eventScopeMatches = true
    precondition(keyHandler?(repeated) == nil && Native.transferCount == 0)
    precondition(controller.share() && shares.count == 1 && shares[0].0 == session.url)
    let compact = Unmanaged<ChromiumCompactRoot>.fromOpaque(Native.roots[2001]!).takeUnretainedValue()
    precondition(compact.holdsHeader(shares[0].1) && compact.shownTab == 20001)
    precondition(Native.pageViews[20001]?.isDescendant(of: compact) == true)
    let menu = choices.miniDestinations(for: session)
    let liveShared = menu.first(where: { $0.id == sharedSpace })!
    let freshPersonal = menu.first(where: { $0.id == Native.personal })!
    precondition(!liveShared.isCopy && liveShared.profileID == profile.id && freshPersonal.isCopy)
    controller.openInSpace(freshPersonal)
    precondition(copies == [Native.personal] && Native.transferCount == 0 && session.isDetached && session.navigation === navigation)
    controller.openInSpace(ChromiumMiniDestination(id: freshPersonal.id, name: freshPersonal.name,
        profileID: UUID(), isCopy: true)) // A stale/reassigned menu cannot change target identity.
    precondition(copies.count == 1)
    let observations = Native.observers.count
    controller.close()
    precondition(Native.miniCloseRequests == 1 && session.navigation === navigation)
    for (token, observer) in Native.observers where observer.3 == 20001 {
        observer.0?(observer.1, token, 8, 2001, 20001, nil, nil, 0, 0)
    }
    precondition(session.navigation === navigation && ended == 0)
    precondition(keyHandler != nil && monitorRemovals == 0)
    precondition(keyHandler?(commandO) == nil)
    precondition(session.isDetached && session.navigation === navigation && navigation.nativeWindowID == 2001)
    precondition(tabs.tree == originalTree && tabs.device == originalDevice && ended == 0)
    precondition(Native.observers.count == observations)
    reject = false
    controller.openInSpace(liveShared)
    precondition(!session.isDetached && tabs.session(for: session.itemID) === session && session.navigation === navigation)
    precondition(navigation.nativeWindowID == 2002 && window.selectedItemID == session.itemID && window.spaceID == sharedSpace && ended == 1)
    precondition(Native.observers.count == observations && Native.transferCount == 2 && Native.miniCloseRequests == 1)
    precondition(keyHandler == nil && monitorRemovals == 1 && !controller.share())
    Native.end(2002)
    precondition(tabs.tree.item(session.itemID) != nil && session.navigation == nil)

    // Chrome/extension-origin transfer follows the same detached session;
    // discovery must not allocate a replacement adapter or release its owner
    // until destination publication actually succeeds.
    Native.windows[3001] = Native.window(3001, group: 3001, profile: Native.work, kind: 1, flags: BARC_DISCOVERY_COMPACT_MINI.rawValue, active: 30001)
    Native.windows[3002] = Native.window(3002, group: 3002, profile: Native.work, active: 30002)
    Native.tabs.append(Native.tab(30001, window: 3001, opener: 30002))
    Native.tabs.append(Native.tab(30002, window: 3002))
    let destination = BrowserWindowState(); destination.spaceID = Native.work
    registry.register(destination); tabs.attach(window: destination, restoringSavedState: false)
    let externalShell = NSView()
    precondition(host.registerWindow(destination, nativeOwner: 3002, shell: externalShell))
    let external = try ChromiumPageNavigation(profileID: profile.id, window: 3001, tab: 30001, bridge: Native.bridge)
    var held: ChromiumMiniWindowController?, releases = 0
    let externalController = ChromiumMiniWindowController(tabs: tabs, profile: profile, navigation: external,
        origin: window, api: api, promote: { _, _ in false }, onEnd: { _ in releases += 1; held = nil })!
    held = externalController
    let externalSession = externalController.page
    precondition(externalController.present(canPresent: { true }))
    var excludeDestination = true
    let externalAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { excludeDestination && $0 == 3002 }, makeShell: { _ in NSView() },
        detachedPage: { $0 == 30001 ? held?.page : nil }, didAdoptDetached: { tab in
            precondition(tab == 30001 && tabs.isNativePageOwner(externalSession, in: destination))
            precondition(externalSession.navigation === external)
            held?.releaseAfterAdoption()
        })
    precondition(externalAdmission.registerInitial(ChromiumProductWindow(state: destination, shell: externalShell), nativeWindow: 3002))
    Native.move(30001, to: 3002)
    Native.windows[3001] = nil
    externalAdmission.apply(Native.bridge.readSnapshot()!)
    precondition(held === externalController && releases == 0 && externalSession.isDetached)
    precondition(externalSession.navigation === external && !external.isClosed)
    excludeDestination = false
    externalAdmission.apply(Native.bridge.readSnapshot()!)
    precondition(held == nil && releases == 1 && tabs.session(for: externalSession.itemID) === externalSession)
    precondition(tabs.isNativePageOwner(externalSession, in: destination) && externalSession.navigation === external)
    precondition(Native.tabs.first(where: { $0.tab == 30001 })?.opener_tab == 30002)
    precondition(Native.observers.values.filter { $0.3 == 30001 }.count == 1)
    precondition(Native.transferCount == 2 && Native.miniCloseRequests == 1)

    // A real source can become kept while its blank/native delivery is pending.
    // Present it through exact store identity, without inventing a new space.
    let keptSpace = tabs.createSpace(name: "Kept", icon: "person", accentHex: "#123456", after: Native.work)!
    let keptID = tabs.tree.dataStoreID(for: keptSpace)!
    Native.windows[4001] = Native.window(4001, group: 4001, profile: keptID, kind: 1, flags: BARC_DISCOVERY_COMPACT_MINI.rawValue, active: 40001)
    Native.tabs.append(Native.tab(40001, window: 4001))
    tabs.deleteSpace(keptSpace, keepingLeftProfile: true)
    let kept = tabs.profile(forStore: keptID)!
    precondition(kept.id == keptID && kept.webKitStorage == nil && tabs.profiles.first(where: { $0.id == keptID })?.spaceIDs.isEmpty == true)
    let keptTree = tabs.tree, keptDevice = tabs.device
    let keptPage = try ChromiumPageNavigation(profileID: keptID, window: 4001, tab: 40001, bridge: Native.bridge)
    let keptController = ChromiumMiniWindowController(tabs: tabs, profile: kept, navigation: keptPage,
        origin: nil, api: api, promote: { _, _ in preconditionFailure("Kept profile invented a space") },
        canPromote: { _ in false }, onEnd: { _ in })!
    precondition(keptController.present(canPresent: { true }))
    keptController.openInSpace()
    precondition(keptController.page.profile?.id == keptID && keptController.page.navigation === keptPage)
    precondition(tabs.tree == keptTree && tabs.device == keptDevice)

    // Explicit cross-profile copy reuses normal factory admission. It never
    // consumes a saved window, moves the source, or creates a second source observer.
    let copyAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    let beforeCopyRecords = tabs.device.windows
    let beforeCopyLoads = Native.restoredURLs.count
    let sourceObserverCount = Native.observers.values.filter { $0.3 == 40001 }.count
    let copyURL = keptController.page.url
    Native.savedRequests = []
    Native.restoring = true
    let openCopy: ChromiumCreatedPageAdmission.SavedOpen = { profile, destination, callback, context in MainActor.assumeIsolated {
        precondition(destination == BARC_PROFILE_BLANK)
        Native.savedRequests.append((UUID(uuidString: String(cString: profile!))!, callback, context))
    } }
    precondition(copyAdmission.openDetachedCopy(keptController.page, in: Native.personal,
        open: openCopy, close: { id in Native.end(id); return 1 }, canPresent: { true }))
    precondition(Native.savedRequests.count == 1 && Native.savedRequests[0].0 == Native.personal)
    precondition(tabs.device.windows == beforeCopyRecords && tabs.device.windows.contains(untouchedSaved))
    Native.windows[6001] = Native.window(6001, group: 6001, profile: Native.personal, flags: 4 | 8, active: 60010)
    Native.tabs.append(Native.tab(60010, window: 6001, flags: 2))
    let copy = Native.savedRequests.removeFirst(); copy.1?(BARC_PROFILE_OK, 6001, copy.2)
    precondition(Native.restoredURLs.count == beforeCopyLoads + 1 && Native.restoredURLs.last == copyURL.absoluteString)
    precondition(keptController.page.isDetached && keptController.page.navigation === keptPage && !keptPage.isClosed)
    precondition(Native.observers.values.filter { $0.3 == 40001 }.count == sourceObserverCount)
    precondition(tabs.sessions.contains { ($0.navigation as? ChromiumPageNavigation)?.nativeWindowID == 6001 &&
        $0.profile?.id == Native.personal && tabs.spaceID(of: $0.itemID) == Native.personal })
    precondition(tabs.device.windows.contains(untouchedSaved) && Native.miniCloseRequests == 1)

    // Refusal before a fresh target can be published closes only that factory
    // result; the exact source and every old saved record remain available.
    let failedCopyAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    var copyAllowed = true, closedCopies: [Int32] = []
    let savedBeforeFailure = tabs.device.windows, loadsBeforeFailure = Native.restoredURLs.count
    precondition(failedCopyAdmission.openDetachedCopy(keptController.page, in: Native.personal,
        open: openCopy, close: { id in closedCopies.append(id); Native.end(id); return 1 }, canPresent: { copyAllowed }))
    let failedCopy = Native.savedRequests.removeFirst()
    Native.windows[6002] = Native.window(6002, group: 6002, profile: Native.personal, flags: 4 | 8, active: 60020)
    Native.tabs.append(Native.tab(60020, window: 6002, flags: 2))
    copyAllowed = false; failedCopy.1?(BARC_PROFILE_OK, 6002, failedCopy.2)
    precondition(closedCopies == [6002] && tabs.device.windows == savedBeforeFailure && Native.restoredURLs.count == loadsBeforeFailure)
    precondition(keptController.page.navigation === keptPage && !keptPage.isClosed)
    // Refusal from Show occurs after the copy's own item was published.
    // Retire only that unadmitted native owner, retaining the source and old records.
    let showRefusalAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    let recordsBeforeShowRefusal = tabs.device.windows
    var refusedState: BrowserWindowState?, refusedItem: UUID?
    var showCloseRequests: [Int32] = []
    var showCopyAllowed = true
    Native.onCloseWindow = { owner in
        showCloseRequests.append(owner); Native.end(owner); return 1
    }
    Native.onShow = { owner in
        precondition(owner == 6010)
        refusedState = registry.windows.values.first {
            (tabs.selectedSession(in: $0)?.navigation as? ChromiumPageNavigation)?.nativeWindowID == owner
        }
        refusedItem = refusedState?.selectedItemID
        precondition(refusedItem != nil && tabs.item(refusedItem!)?.url == copyURL)
        showCopyAllowed = false
        return 0
    }
    precondition(showRefusalAdmission.openDetachedCopy(keptController.page, in: Native.personal,
        open: openCopy, close: { id in showCloseRequests.append(id); Native.end(id); return 1 },
        canPresent: { showCopyAllowed }))
    let showRefusal = Native.savedRequests.removeFirst()
    Native.windows[6010] = Native.window(6010, group: 6010, profile: Native.personal, flags: 4 | 8, active: 60100)
    Native.tabs.append(Native.tab(60100, window: 6010, flags: 2))
    showRefusal.1?(BARC_PROFILE_OK, 6010, showRefusal.2)
    precondition(refusedState != nil && refusedItem != nil && showCloseRequests == [6010])
    precondition(Native.windows[6010] == nil && registry.windows[refusedState!.id] == nil)
    precondition(recordsBeforeShowRefusal.allSatisfy { tabs.device.windows.contains($0) })
    precondition(keptController.page.navigation === keptPage && !keptPage.isClosed && keptController.page.isDetached)
    precondition(Native.observers.values.filter { $0.3 == 40001 }.count == sourceObserverCount)
    Native.onShow = nil; Native.onCloseWindow = nil

    // A newer user selection during Show owns the still-live copied window.
    // Refusal of the older copy presentation must not close or overwrite it.
    let supersededCopyAdmission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    let recordsBeforeSupersession = tabs.device.windows
    var newerState: BrowserWindowState?, newerItem: UUID?, originalCopyItem: UUID?
    showCloseRequests = []
    Native.onCloseWindow = { owner in showCloseRequests.append(owner); return 0 }
    Native.onShow = { owner in
        precondition(owner == 6011)
        Native.onShow = nil
        let state = registry.windows.values.first {
            (tabs.selectedSession(in: $0)?.navigation as? ChromiumPageNavigation)?.nativeWindowID == owner
        }!
        newerState = state; originalCopyItem = state.selectedItemID
        newerItem = tabs.open(url: URL(string: "https://fixture.invalid/newer-copy")!, in: state, placement: .newTab)
        precondition(newerItem != nil && state.selectedItemID == newerItem && newerItem != originalCopyItem)
        return 0
    }
    precondition(supersededCopyAdmission.openDetachedCopy(keptController.page, in: Native.personal,
        open: openCopy, close: { id in showCloseRequests.append(id); return 0 }, canPresent: { true }))
    let supersededCopy = Native.savedRequests.removeFirst()
    Native.windows[6011] = Native.window(6011, group: 6011, profile: Native.personal, flags: 4 | 8, active: 60110)
    Native.tabs.append(Native.tab(60110, window: 6011, flags: 2))
    supersededCopy.1?(BARC_PROFILE_OK, 6011, supersededCopy.2)
    precondition(newerState != nil && newerItem != nil && originalCopyItem != nil && showCloseRequests.isEmpty)
    precondition(registry.windows[newerState!.id] === newerState && newerState!.selectedItemID == newerItem)
    precondition(Native.windows[6011] != nil && Native.windows[6011]?.active_tab != 60110)
    precondition(tabs.selectedSession(in: newerState!)?.profile?.id == Native.personal)
    precondition(recordsBeforeSupersession.allSatisfy { tabs.device.windows.contains($0) })
    precondition(tabs.device.windows.contains(untouchedSaved))
    precondition(keptController.page.navigation === keptPage && !keptPage.isClosed && keptController.page.isDetached)
    precondition(Native.observers.values.filter { $0.3 == 40001 }.count == sourceObserverCount)
    Native.onShow = nil; Native.onCloseWindow = nil
    Native.restoring = false

    // Retained controls cannot command a replacement header. Their local
    // monitor is removed even though the native document itself stays alive.
    let retainedHandler = keyHandler!
    let foreignHeader = NSView()
    let keptRoot = Unmanaged<ChromiumCompactRoot>.fromOpaque(Native.roots[4001]!).takeUnretainedValue()
    keptRoot.setHeader(foreignHeader)
    let removalsBeforeReplacement = monitorRemovals
    precondition(retainedHandler(commandO) === commandO)
    precondition(keyHandler == nil && monitorRemovals == removalsBeforeReplacement + 1 && !keptController.share())
    keptController.openInSpace()
    precondition(!keptPage.isClosed && Native.miniCloseRequests == 1 && Native.transferCount == 2)
    Native.end(4001)
    precondition(monitorRemovals == removalsBeforeReplacement + 1 && keptRoot.holdsHeader(foreignHeader))

    // Even a retained/injected regular destination cannot cross a private
    // session boundary. Cmd+O still targets that exact private page/session.
    let privateID = UUID()
    Native.privateIDs[5001] = privateID
    Native.windows[5001] = Native.window(5001, group: 5001, profile: nil, kind: BARC_DISCOVERY_POPUP.rawValue, profileKind: BARC_DISCOVERY_GUEST.rawValue, flags: BARC_DISCOVERY_COMPACT_MINI.rawValue, active: 50001)
    Native.tabs.append(Native.tab(50001, window: 5001))
    let privateProfile = Profile.createEphemeral(id: privateID, engine: .chromium)
    let privatePage = try ChromiumPageNavigation(profileID: privateID, window: 5001, tab: 50001, bridge: Native.bridge, privateSession: true)
    var privatePromotions = 0, privateCopies = 0
    let privateController = ChromiumMiniWindowController(tabs: tabs, profile: privateProfile, navigation: privatePage,
        origin: nil, api: api, promote: { page, space in
            precondition(page.isPrivate && page.profile?.id == privateID && space == nil)
            privatePromotions += 1; return false
        }, destinations: { _ in [freshPersonal] }, openCopy: { _, _ in privateCopies += 1; return true }, onEnd: { _ in })!
    let privateTreeBefore = tabs.tree, privateDeviceBefore = tabs.device
    precondition(privateController.present(canPresent: { true }))
    privateController.openInSpace(freshPersonal)
    precondition(!copyAdmission.openDetachedCopy(privateController.page, in: Native.personal,
        open: { _, _, _, _ in preconditionFailure("Private page reached a regular factory") },
        close: { _ in preconditionFailure("Private source was closed") }, canPresent: { true }))
    precondition(privatePromotions == 0 && privateCopies == 0)
    precondition(keyHandler?(commandO) == nil && privatePromotions == 1 && privateCopies == 0)
    precondition(privateController.share() && shares.last?.0 == privateController.page.url)
    precondition(tabs.tree == privateTreeBefore && tabs.device == privateDeviceBefore)
    let removalsBeforeEnd = monitorRemovals
    Native.end(5001)
    precondition(keyHandler == nil && monitorRemovals == removalsBeforeEnd + 1)
}


/// A Bark window holds clients of two profiles. A selection the engine makes itself, as for a
/// "Leave site?" dialog on a tab of the profile not shown, reaches the model through the catalog:
/// that tab and its space show, once, and the app does not select back. The window lives while
/// any client of its group does.
@MainActor private func checkEngineSelectionInBarkWindow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcEngineSelection-\(UUID())")
    let suite = "BarcEngineSelection-\(UUID())", registry = WindowRegistry()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "person", accentHex: "#654321", after: Native.work)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    Native.windows = [7101: Native.window(7101, group: 7101, profile: Native.work, flags: 1 | 4, active: 71010),
                      7102: Native.window(7102, group: 7101, profile: Native.personal, flags: 1, active: 71020)]
    Native.windows[7102]?.selected_client = 7101
    Native.tabs = [Native.tab(71010, window: 7101), Native.tab(71020, window: 7102)]
    let workView = NSView(), personalView = NSView()
    Native.pageViews = [71010: workView, 71020: personalView]
    var selections: [Int32] = []
    Native.onSelectWindow = { selections.append($0); return 1 }
    defer { Native.pageViews = [:]; Native.onSelectWindow = nil }
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    admission.apply(Native.bridge.readSnapshot()!)
    let state = registry.allWindows.first!
    let barkRoot = sequence(first: workView as NSView, next: \.superview).lazy.compactMap { $0 as? ChromiumWindowRoot }.first
    precondition(barkRoot != nil && state.spaceID == Native.work, "the Bark window shows the work page")
    let personal = tabs.sessions.first { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == 71020 }!

    for key in [Int32(7101), 7102] { Native.windows[key]?.selected_client = 7102 }
    Native.windows[7101]?.flags = 1; Native.windows[7102]?.flags = 1 | 4
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(state.spaceID == Native.personal && state.selectedItemID == personal.itemID,
                 "the engine's selection of the other profile's tab reaches the model: the tab and its space")
    precondition(personalView.isDescendant(of: barkRoot!) && workView.superview == nil,
                 "the window shows that tab's page")
    precondition(selections.isEmpty, "the app does not select back: \(selections)")
    let followed = (tabs.tree, tabs.device)
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(tabs.tree == followed.0 && tabs.device == followed.1 && selections.isEmpty, "once")

    Native.end(7101)
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(registry.windows[state.id] === state && personalView.isDescendant(of: barkRoot!),
                 "the window lives on with the other client when the first closes")
    Native.end(7102)
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(registry.windows[state.id] == nil, "and ends with the last client of its group")
    tabs.saveNow()
}

/// A window saved in a split, in Chromium's own window or a Bark window, opens as a Bark window
/// with no switch: the split shows when the root can lay out its panes, here of one profile or two,
/// and a split it cannot show is dropped, the window opening on its selected tab alone.
@MainActor private func checkSavedSplitInBarkWindow() throws {
    let root = URL(fileURLWithPath: "/private/tmp/BarcSavedBarkSplit-\(UUID())", isDirectory: true)
    let suite = "BarcSavedBarkSplit-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "person", accentHex: "#654321", after: Native.work)
    let first = UUID(), other = UUID(), personalTab = UUID()
    _ = try tree.createTab(id: first, url: URL(string: "https://fixture.invalid/saved-first")!, title: "First", in: .tabs(spaceID: Native.work), after: nil)
    _ = try tree.createTab(id: other, url: URL(string: "https://fixture.invalid/saved-other")!, title: "Other", in: .tabs(spaceID: Native.work), after: first)
    _ = try tree.createTab(id: personalTab, url: URL(string: "https://fixture.invalid/saved-personal")!, title: "Personal",
                           in: .tabs(spaceID: Native.personal), after: nil)
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    Native.restoring = true
    defer { Native.restoring = false; Native.pageViews = [:]; Native.viewless = []; Native.onOpen = nil; Native.onSelectWindow = nil }
    for (index, mode) in ["one-profile", "two-profiles", "no-view"].enumerated() {
        let record = SplitRecord(mode == "two-profiles" ? [first, personalTab] : [first, other], dividers: [0.4])!
        var device = DeviceState(); device.firstLaunchCompleted = true
        device.windows = [WindowRecord(id: UUID(), spaceID: Native.work, selectedItemBySpace: [Native.work: first], split: record)]
        let directory = root.appendingPathComponent(mode)
        let store = TabStore(directory: directory); store.save(tree, device); store.flush()
        let registry = WindowRegistry()
        let tabs = TabsController(settings: settings, windowRegistry: registry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: directory)
        let host = ChromiumNativePageHost(bridge: Native.bridge)
        tabs.nativePageHost = host
        let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
            registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
        let native = Int32(1301 + 10 * index), joined = native + 1
        Native.windows[native] = Native.window(native, group: UInt64(native), profile: Native.work, flags: 4 | 8, active: native * 10)
        Native.tabs.append(Native.tab(native * 10, window: native, flags: 2))
        Native.viewless = mode == "no-view" ? [9000 + Int32(Native.privateCreatedClients.count)] : []
        Native.onSelectWindow = { owner in
            for key in [native, joined] where Native.windows[key] != nil { Native.windows[key]?.selected_client = owner }
            return 1
        }
        Native.onOpen = { owner, callback, pointer in
            Native.windows[joined] = Native.window(joined, group: UInt64(native), profile: Native.personal, flags: 0, active: joined * 10)
            let selected = Native.windows[owner]?.selected_client ?? owner
            Native.windows[joined]?.selected_client = selected
            Native.tabs.append(Native.tab(joined * 10, window: joined))
            callback?(BARC_PROFILE_OK, joined, pointer)
        }
        let state = admission.prepareInitialWindow()!
        precondition(state.split == record, "\(mode): the window carries its saved split")
        let showsBefore = Native.shown.count
        var outcomes: [NativeSplitOutcome] = []
        precondition(admission.admitRestoredWindow(state, native: native, profile: Native.work, show: true, canPresent: { true },
                                                   completion: { outcomes.append($0) }), "\(mode): the restore is accepted")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(outcomes == [.admitted] && Native.shown.count == showsBefore + 1, "\(mode): the window opens: \(outcomes)")
        let page = tabs.selectedSession(in: state)?.navigation as? ChromiumPageNavigation
        let barkRoot = page.flatMap { Native.pageViews[$0.nativeTabID] }.flatMap {
            sequence(first: $0, next: \.superview).lazy.compactMap { $0 as? ChromiumWindowRoot }.first
        }
        precondition(state.selectedItemID == first && barkRoot != nil, "\(mode): a Bark window shows the selected tab")
        if mode == "no-view" {
            precondition(state.split == nil && barkRoot!.split == nil && tabs.device.windows.first { $0.id == state.id }?.split == nil,
                         "a split the window cannot show is dropped, and the window opens on its selected tab alone")
        } else {
            precondition(state.split == record && barkRoot!.split?.panes.count == 2
                         && Set(barkRoot!.split!.panes.compactMap { $0?.client }) == (mode == "two-profiles" ? [native, joined] : [native]),
                         "\(mode): the saved split shows in the Bark window: \(String(describing: barkRoot!.split))")
        }
        for window in [native, joined] where Native.windows[window] != nil { Native.end(window) }
        admission.apply(Native.bridge.readSnapshot()!)
        tabs.saveNow()
    }
}

@MainActor private func checkMixedProfileSplitAdmission() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcMixedSplit-\(UUID())")
    let suite = "BarcMixedSplit-\(UUID())", registry = WindowRegistry()
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "person", accentHex: "#654321", after: Native.work)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    Native.windows = [7001: Native.window(7001, group: 7001, profile: Native.work, active: 70010),
                      7002: Native.window(7002, group: 7001, profile: Native.personal, active: 70020)]
    Native.windows[7002]?.selected_client = 7001
    Native.tabs = [Native.tab(70010, window: 7001), Native.tab(70020, window: 7002)]
    Native.servesPageViews = true; Native.onAttach = nil
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs,
        registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
    admission.apply(Native.bridge.readSnapshot()!)
    let state = registry.allWindows.first!
    let work = tabs.sessions.first { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == 70010 }!
    let personal = tabs.sessions.first { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == 70020 }!
    let workPage = work.navigation!, personalPage = personal.navigation!
    precondition(work.profile?.id == Native.work && personal.profile?.id == Native.personal)
    let record = SplitRecord([work.itemID, personal.itemID], orientation: .vertical, dividers: [0.4])!
    let creationsBefore = Native.privateCreatedClients.count, loadsBefore = Native.restoredURLs.count
    var results: [Bool] = []
    Native.restoring = true
    defer { Native.restoring = false; Native.onSelectWindow = nil; Native.onAttach = nil }
    Native.onSelectWindow = { owner in
        for key in [Int32(7001), 7002] { Native.windows[key]?.selected_client = owner }
        return 1
    }
    precondition(tabs.presentNativeSplit(record, activeItemID: work.itemID, in: state, completion: { results.append($0) }))
    precondition(results == [true] && state.split == record)
    let pages = [work.itemID: work, personal.itemID: personal]
    let view = Native.pageViews[70010]!
    let barkRoot = sequence(first: view, next: \.superview).compactMap { $0 as? ChromiumWindowRoot }.first!
    precondition(barkRoot.split?.panes.compactMap { $0?.client } == [7001, 7002])
    precondition(host.isSplit(record, pages: pages, activeItemID: work.itemID, in: state))
    let replacement = record.converted()
    Native.viewless.insert(70020)
    precondition(tabs.presentNativeSplit(replacement, activeItemID: work.itemID, in: state, completion: { results.append($0) }))
    precondition(results.last == false && state.split == record && barkRoot.split?.vertical == true)
    Native.viewless.remove(70020)
    precondition(tabs.presentNativeSplit(replacement, activeItemID: personal.itemID, in: state, completion: { results.append($0) }))
    precondition(results.last == true && state.split == replacement && state.spaceID == Native.personal)
    precondition(host.isSplit(replacement, pages: pages, activeItemID: personal.itemID, in: state))
    precondition(tabs.presentNativeSplit(nil, activeItemID: personal.itemID, in: state, completion: { results.append($0) }))
    precondition(results.last == true && barkRoot.split == nil && barkRoot.shownTab == 70020)
    precondition(work.navigation === workPage && personal.navigation === personalPage)
    precondition(Native.privateCreatedClients.count == creationsBefore && Native.restoredURLs.count == loadsBefore)
    Native.end(7001); Native.end(7002)
}


@MainActor private func checkWindowShortcuts(_ application: CatalogApplication) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarkShortcuts-\(UUID())")
    let defaults = UserDefaults(suiteName: root.lastPathComponent)!
    defer {
        application.simulatedKeyWindow = nil
        defaults.removePersistentDomain(forName: root.lastPathComponent)
        try? FileManager.default.removeItem(at: root)
    }
    // Empty spaces exercise command dispatch without requiring a renderer for a starter tab.
    let initialSpace = UUID(), destination = UUID(), drafts = UUID(), personal = UUID()
    let first = BrowserWindowState(), second = BrowserWindowState()
    let original = UUID(), other = UUID(), personalDraft = UUID()
    var tree = TabTree()
    tree.createSpace(id: initialSpace, name: "First", icon: "house", accentHex: "#225588", after: nil)
    tree.createSpace(id: destination, name: "Second", icon: "house", accentHex: "#225588", after: initialSpace)
    tree.createSpace(id: drafts, name: "Drafts", icon: "folder", accentHex: "#225588", after: destination)
    tree.createSpace(id: personal, name: "Personal", icon: "person", accentHex: "#886622", after: drafts)
    let url = URL(string: "https://fixture.invalid/draft")!
    _ = try tree.createTab(id: original, url: url, title: "Draft", in: .tabs(spaceID: drafts), after: nil)
    _ = try tree.createTab(id: other, url: url, title: "Draft", in: .tabs(spaceID: drafts), after: original)
    _ = try tree.createTab(id: personalDraft, url: url, title: "Draft", in: .tabs(spaceID: personal), after: nil)
    var device = DeviceState()
    device.windows = [
        WindowRecord(id: first.id, spaceID: initialSpace, selectedItemBySpace: [drafts: original, personal: personalDraft]),
        WindowRecord(id: second.id, spaceID: initialSpace, selectedItemBySpace: [drafts: other]),
    ]
    device.firstLaunchCompleted = true
    let directory = root.appendingPathComponent("Tabs")
    let store = TabStore(directory: directory)
    store.save(tree, device)
    store.flush()
    let registry = WindowRegistry()
    let manager = BrowserManager(
        settings: NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults,
                                     boostStore: BoostStore(fileURL: root.appendingPathComponent("Boosts.json"))),
        windowRegistry: registry, importManager: ImportManager(sources: .fixtures(in: root), workDirectory: root.appendingPathComponent("ImportCopies")),
        persistence: try Persistence(directory: root), userDefaults: defaults, downloadManager: DownloadManager(),
        tabsDirectory: directory)
    let shortcuts = KeyboardShortcutManager(userDefaults: defaults)
    shortcuts.setBrowserManager(manager)
    let firstHandle = NSWindow(), secondHandle = NSWindow(), settings = NSWindow()
    first.window = firstHandle
    second.window = secondHandle
    for state in [first, second] {
        registry.register(state)
        manager.tabs.attach(window: state)
    }
    first.spaceID = initialSpace
    second.spaceID = initialSpace

    func focus(_ state: BrowserWindowState) {
        registry.setActive(state)
        application.simulatedKeyWindow = state.window
    }
    func drain() {
        var delivered = false
        DispatchQueue.main.async { delivered = true }
        while !delivered { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    focus(first)
    shortcuts.perform(.toggleSidebar)
    drain()
    precondition(!first.isSidebarVisible && second.isSidebarVisible)
    shortcuts.perform(.nextSpace)
    drain()
    precondition(first.spaceID == destination && second.spaceID == initialSpace,
                 "Next Space must advance the focused window")
    for action in [ShortcutAction.nextSpace, .previousSpace, .goToSpace2, .toggleSidebar] {
        let otherSpace = action == .previousSpace ? destination : initialSpace
        second.spaceID = otherSpace
        focus(first)
        shortcuts.perform(action)
        focus(second)
        drain()
        precondition(!first.isSidebarVisible && second.isSidebarVisible &&
                     first.spaceID == destination && second.spaceID == otherSpace,
                     "A queued \(action) changed a different browser window")
    }
    focus(first)
    shortcuts.perform(.toggleSidebar)
    application.simulatedKeyWindow = settings
    drain()
    precondition(!first.isSidebarVisible, "Settings took focus before dispatch")
    shortcuts.perform(.toggleSidebar)
    focus(first)
    drain()
    precondition(!first.isSidebarVisible, "Settings dispatched to the browser behind it")
    shortcuts.perform(.goToSpace1)
    drain()
    precondition(first.spaceID == initialSpace, "A numbered shortcut selects the first space in the same window")
    shortcuts.perform(.toggleSidebar)
    first.window = settings
    application.simulatedKeyWindow = settings
    drain()
    precondition(!first.isSidebarVisible, "A replacement window inherited a stale command")

    first.window = firstHandle
    first.spaceID = drafts
    second.spaceID = drafts
    precondition(first.selectedItemID == original && second.selectedItemID == other)
    focus(first)
    shortcuts.perform(.toggleBookmark)
    focus(second)
    drain()
    precondition(manager.tabs.section(of: other) == .tabs(spaceID: drafts),
                 "Bookmark Tab moved the other window's draft into Pinned")
    precondition(manager.tabs.section(of: original) == .tabs(spaceID: drafts))
    focus(first)
    shortcuts.perform(.toggleBookmark)
    first.spaceID = personal
    drain()
    precondition(first.selectedItemID == personalDraft && manager.tabs.section(of: personalDraft) == .tabs(spaceID: personal),
                 "Bookmark Tab changed a different profile after the window switched spaces")
    first.spaceID = drafts
    shortcuts.perform(.toggleBookmark)
    drain()
    precondition(manager.tabs.section(of: original) == .pinned(spaceID: drafts),
                 "Bookmark Tab must still work in its invoking window")
    shortcuts.perform(.toggleBookmark)
    drain()
    precondition(manager.tabs.section(of: original) == .tabs(spaceID: drafts))
    focus(first)
    shortcuts.perform(.closeTab)
    focus(second)
    drain()
    precondition(manager.tabs.item(other) != nil, "Close Tab closed the other window's draft")
    precondition(manager.tabs.item(original) == nil, "Close Tab should close the document where it was invoked")
    shortcuts.reopenClosedTab()
    focus(first)
    drain()
    precondition(manager.tabs.item(original) == nil, "A stale Reopen consumed the closed tab")
    application.simulatedKeyWindow = settings
    shortcuts.reopenClosedTab()
    drain()
    precondition(manager.tabs.item(original) == nil, "Settings reopened a tab behind its window")
    focus(first)
    shortcuts.reopenClosedTab()
    drain()
    precondition(manager.tabs.item(original) != nil && manager.tabs.item(other) != nil,
                 "The invoking browser must still be able to reopen the original draft")
}

@MainActor private func checkPeekWithoutAnEngineDocument() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarkPeekWithoutDocument-\(UUID())")
    let defaults = UserDefaults(suiteName: root.lastPathComponent)!
    defer {
        defaults.removePersistentDomain(forName: root.lastPathComponent)
    }
    let registry = WindowRegistry()
    let manager = BrowserManager(
        settings: NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults,
                                      boostStore: BoostStore(fileURL: root.appendingPathComponent("Boosts.json"))),
        windowRegistry: registry,
        importManager: ImportManager(sources: .fixtures(in: root), workDirectory: root),
        persistence: try Persistence(directory: root), userDefaults: defaults,
        downloadManager: DownloadManager(),
        tabsDirectory: root.appendingPathComponent("Tabs"))
    let window = BrowserWindowState()
    registry.register(window)
    registry.setActive(window)
    manager.tabs.attach(window: window, restoringSavedState: false)
    window.spaceID = manager.tabs.orderedSpaces.first!.id
    let url = URL(string: "https://fixture.invalid/source")!
    let tab = manager.tabs.open(url: url, in: window, placement: .newTab)!
    let source = manager.tabs.ensureSession(for: tab)!
    precondition(source.navigation == nil && source.profile != nil)
    manager.presentPeek(url: URL(string: "https://fixture.invalid/preview")!, from: source)
    precondition(manager.peekManager.page(tab: tab, window: window.id) == nil,
                 "A page without a live Chromium document created a Peek")
}

/// Existing-bound Peek documents use the same adapter/session for promotion and
/// external moves; same-owner admission is the sole role-clearing authority.
@MainActor private func checkNativePeekAdmission() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcPeek-\(UUID())")
    let suite = "BarcPeek-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    Native.windows.removeAll(); Native.tabs.removeAll(); Native.observers.removeAll()
    Native.transfersEnabled = true; Native.transferCount = 0
    Native.sameOwnerAdmissions = 0; Native.peekRoleClears = 0
    Native.restoring = false; Native.onSelectWindow = nil; Native.onAttach = nil
    let initialLoads = Native.restoredURLs.count
    defer { Native.transfersEnabled = false; Native.onTransferAdmission = nil }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    tree.createSpace(id: Native.personal, name: "Personal", icon: "house", accentHex: "#123456", after: Native.work)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults,
        boostStore: BoostStore(fileURL: root.appendingPathComponent("Boosts.json")))
    let registry = WindowRegistry()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let window = BrowserWindowState(); window.spaceID = Native.work
    registry.register(window); registry.setActive(window); tabs.attach(window: window, restoringSavedState: false)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let shell = NSView(), profile = tabs.profile(forSpace: Native.work)!
    Native.windows[8100] = Native.window(8100, group: 8100, profile: profile.id, flags: 1 | 4, active: 81001)
    Native.tabs = [Native.tab(81001, window: 8100)]
    precondition(host.registerWindow(window, nativeOwner: 8100, shell: shell))
    guard case .success(let sourceBinding) = host.bindExistingPage(nativeWindow: 8100, tab: 81001, profile: profile, in: window) else { preconditionFailure() }
    let sourceID = tabs.adoptNativePage(sourceBinding.navigation, through: host, in: window, spaceID: Native.work, select: false)!
    sourceBinding.finish(adopted: true)
    precondition(tabs.reflectNativeSelection(sourceID, in: window))
    let source = tabs.session(for: sourceID)!, sourceNavigation = source.navigation as! ChromiumPageNavigation
    var detached: PageSession?, adopted = 0, covered = false
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs, registry: registry,
        isUtility: { _ in false }, makeShell: { _ in NSView() },
        detachedPage: { tab in (detached?.navigation as? ChromiumPageNavigation)?.nativeTabID == tab ? detached : nil },
        didAdoptDetached: { tab in
            precondition((detached?.navigation as? ChromiumPageNavigation)?.nativeTabID == tab)
            adopted += 1; detached = nil
        }, coveredByPeek: { page, state in covered && page === source && state === window })
    precondition(admission.registerInitial(ChromiumProductWindow(state: window, shell: shell), nativeWindow: 8100))

    func makePeek(_ owner: Int32, _ tab: Int32) -> PageSession {
        Native.windows[owner] = Native.window(owner, group: 8100, profile: profile.id, flags: 0, active: tab)
        Native.windows[owner]?.selected_client = 8100
        var row = Native.tab(tab, window: owner, opener: 81001, flags: UInt32(BARC_DISCOVERY_TAB_PEEK.rawValue))
        row.peek_source_tab = 81001; Native.tabs.append(row)
        guard case .success(let binding) = host.bindExistingPage(nativeWindow: owner, tab: tab, profile: profile, in: window) else { preconditionFailure() }
        let page = tabs.bindDetachedNativePage(binding.navigation, profile: profile, owner: host, in: window)!
        binding.finish(adopted: true)
        return page
    }
    let peek = makePeek(8101, 81002), peekID = peek.itemID, navigation = peek.navigation as! ChromiumPageNavigation
    detached = peek
    let tokensBeforePromotion = Native.nextToken
    // While the native Peek owns the shared widget, incoming routes still use
    // the exact saved source, never an unrelated active/default profile.
    Native.windows[8100]?.selected_client = 8101
    Native.windows[8100]?.flags &= ~UInt32(BARC_DISCOVERY_SELECTED_CLIENT.rawValue)
    Native.windows[8101]?.selected_client = 8101
    Native.windows[8101]?.flags |= UInt32(BARC_DISCOVERY_SELECTED_CLIENT.rawValue)
    covered = true
    precondition(admission.browserTarget(kind: 0, regularProfile: nil)?.window == 8100)
    let exactSourceRow = Native.windows[8100]!
    Native.windows[8100] = Native.window(8100, group: 8100, profile: tabs.profile(forSpace: Native.personal)!.id, flags: 1, active: 81001)
    Native.windows[8100]?.selected_client = 8101
    precondition(admission.browserTarget(kind: 0, regularProfile: nil)?.window != 8100)
    Native.windows[8100] = exactSourceRow
    covered = false
    precondition(admission.browserTarget(kind: 0, regularProfile: nil)?.window == -1)
    Native.windows[8100]?.selected_client = 8100
    Native.windows[8100]?.flags |= UInt32(BARC_DISCOVERY_SELECTED_CLIENT.rawValue)
    Native.windows[8101]?.selected_client = 8100
    Native.windows[8101]?.flags &= ~UInt32(BARC_DISCOVERY_SELECTED_CLIENT.rawValue)

    // Refusal during the actual transfer-admission callback preserves the
    // original detached session/document and its original Peek role.
    Native.onTransferAdmission = { Native.windows[8100]?.flags |= UInt32(BARC_DISCOVERY_OWNER_ENDING.rawValue) }
    precondition(!admission.promotePeek(peek, source: source, in: window))
    Native.onTransferAdmission = nil
    Native.windows[8100]?.flags &= ~UInt32(BARC_DISCOVERY_OWNER_ENDING.rawValue)
    precondition(peek.isDetached && peek.navigation === navigation && navigation.nativeWindowID == 8101)
    precondition(tabs.item(peekID) == nil && Native.peekRoleClears == 0)
    precondition(admission.promotePeek(peek, source: source, in: window))
    precondition(tabs.session(for: peekID) === peek && peek.navigation === navigation && !peek.isDetached)
    precondition(navigation.nativeWindowID == 8100 && Native.peekRoleClears == 1)
    precondition(tabs.opener(of: peekID) == sourceID && source.navigation === sourceNavigation)
    precondition(Native.nextToken == tokensBeforePromotion)

    // Another retained Peek moves to a different real group. Reject its first
    // model admission without clearing the hint or losing the live adapter.
    Native.windows[8100]?.active_tab = 81001
    precondition(tabs.reflectNativeSelection(sourceID, in: window))
    let moved = makePeek(8102, 81003), movedID = moved.itemID
    let movedNavigation = moved.navigation as! ChromiumPageNavigation
    detached = moved
    Native.windows[8200] = Native.window(8200, group: 8200, profile: profile.id, flags: 4, active: 81003)
    Native.move(81003, to: 8200)
    let transfersBeforeCatalog = Native.transferCount, tokensBeforeCatalog = Native.nextToken
    Native.onTransferAdmission = { Native.windows[8200]?.flags |= UInt32(BARC_DISCOVERY_OWNER_ENDING.rawValue) }
    admission.apply(ChromiumDiscoverySnapshot(revision: Native.revision, windows: Array(Native.windows.values), tabs: Native.tabs))
    Native.onTransferAdmission = nil
    Native.windows[8200]?.flags &= ~UInt32(BARC_DISCOVERY_OWNER_ENDING.rawValue)
    precondition(moved.isDetached && moved.navigation === movedNavigation && tabs.item(movedID) == nil)
    precondition(Native.tabs.first { $0.tab == 81003 }!.flags & BARC_DISCOVERY_TAB_PEEK.rawValue != 0)
    admission.apply(ChromiumDiscoverySnapshot(revision: Native.revision, windows: Array(Native.windows.values), tabs: Native.tabs))
    let destination = registry.windows.values.first { tabs.isNativePageOwner(moved, in: $0) }!
    precondition(destination !== window && tabs.session(for: movedID) === moved && moved.navigation === movedNavigation)
    precondition(!moved.isDetached && movedNavigation.nativeWindowID == 8200 && adopted == 1)
    precondition(Native.transferCount == transfersBeforeCatalog + 2 && Native.sameOwnerAdmissions == 2)
    precondition(Native.peekRoleClears == 2 && Native.nextToken == tokensBeforeCatalog)
    precondition(Native.tabs.first { $0.tab == 81003 }!.peek_source_tab == 0)
    let admittedCount = Native.sameOwnerAdmissions
    admission.apply(ChromiumDiscoverySnapshot(revision: Native.revision, windows: Array(Native.windows.values), tabs: Native.tabs))
    precondition(Native.sameOwnerAdmissions == admittedCount)

    // The source document can end while its Peek's logical client retains the
    // physical group. Expired-source adoption must still use the same session.
    let expired = makePeek(8103, 81004), expiredID = expired.itemID
    let expiredNavigation = expired.navigation as! ChromiumPageNavigation
    detached = expired
    Native.windows[8103]?.selected_client = 8103
    Native.windows[8103]?.flags |= UInt32(BARC_DISCOVERY_SELECTED_CLIENT.rawValue)
    Native.end(8100)
    admission.apply(ChromiumDiscoverySnapshot(revision: Native.revision, windows: Array(Native.windows.values), tabs: Native.tabs))
    precondition(tabs.session(for: expiredID) === expired && expired.navigation === expiredNavigation && !expired.isDetached)
    precondition(expiredNavigation.nativeWindowID == 8103 && tabs.item(sourceID) != nil && source.navigation == nil)
    precondition(Native.sameOwnerAdmissions == admittedCount + 1 && adopted == 2 && Native.peekRoleClears == 3)
    precondition(tabs.isNativePageOwner(expired, in: window) && registry.windows[window.id] === window)
    precondition(Native.observers.values.filter { $0.3 == 81004 }.count == 1)
    precondition(Native.observers.values.filter { $0.3 == 81003 }.count == 1)
    precondition(Native.restoredURLs.count == initialLoads) // load/select/reload mocks reject this entire scope.
    for owner in Array(Native.windows.keys) { Native.end(owner) }
    tabs.saveNow(); settings.flushBoosts()
    print("Chromium Peek promotion/moved-owner checks passed")
}

/// In a Bark window a Peek is a background tab of its source's own client. It is made, owned and
/// promoted there with no second client; while the engine reports it active, the model stays on the
/// source and never adopts it as an ordinary tab.
@MainActor private func checkPeekInBarkWindow(promoteToSplit: Bool, existingSplit: Bool = false) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcBarkPeek-\(UUID())")
    let suite = "BarcBarkPeek-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    Native.windows.removeAll(); Native.tabs.removeAll(); Native.observers.removeAll()
    Native.transfersEnabled = true; Native.sameOwnerAdmissions = 0; Native.peekRoleClears = 0
    Native.restoring = false; Native.onSelectWindow = nil; Native.onAttach = nil
    Native.peekCapable = true
    defer {
        Native.transfersEnabled = false; Native.peekCapable = false
        Native.pageViews = [:]; Native.roots[8300] = nil
        Native.onCreatePeek = nil; Native.onSelectWindow = nil
    }
    var tree = TabTree()
    tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
    var device = DeviceState(); device.firstLaunchCompleted = true
    let store = TabStore(directory: root); store.save(tree, device); store.flush()
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults)
    let registry = WindowRegistry()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
        siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: root)
    let window = BrowserWindowState(); window.spaceID = Native.work
    registry.register(window); registry.setActive(window); tabs.attach(window: window, restoringSavedState: false)
    let host = ChromiumNativePageHost(bridge: Native.bridge)
    tabs.nativePageHost = host
    let shell = NSView(), profile = tabs.profile(forSpace: Native.work)!
    Native.windows[8300] = Native.window(8300, group: 8300, profile: profile.id, flags: 1 | 4, active: 83001)
    Native.tabs = [Native.tab(83001, window: 8300)]
    precondition(host.registerWindow(window, nativeOwner: 8300, shell: shell))
    guard case .success(let sourceBinding) = host.bindExistingPage(nativeWindow: 8300, tab: 83001, profile: profile, in: window) else { preconditionFailure() }
    let sourceID = tabs.adoptNativePage(sourceBinding.navigation, through: host, in: window, spaceID: Native.work, select: false)!
    sourceBinding.finish(adopted: true)
    precondition(tabs.reflectNativeSelection(sourceID, in: window))
    let source = tabs.session(for: sourceID)!, sourceNavigation = source.navigation as! ChromiumPageNavigation
    var originalSplit: SplitRecord?
    if existingSplit {
        Native.tabs.append(Native.tab(83003, window: 8300))
        guard case .success(let sibling) = host.bindExistingPage(nativeWindow: 8300, tab: 83003,
                                                               profile: profile, in: window) else { preconditionFailure() }
        let siblingID = tabs.adoptNativePage(sibling.navigation, through: host, in: window, spaceID: Native.work, select: false)!
        sibling.finish(adopted: true)
        originalSplit = SplitRecord([sourceID, siblingID], orientation: .vertical)
        precondition(tabs.presentNativeSplit(originalSplit, activeItemID: sourceID, in: window) && window.split == originalSplit)
    }
    let sourceView = Native.pageViews[83001]!
    let barkRoot = sequence(first: sourceView as NSView, next: \.superview).lazy.compactMap { $0 as? ChromiumWindowRoot }.first
    precondition(barkRoot != nil, "the Bark window shows the source")
    let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: host, tabs: tabs, registry: registry,
        isUtility: { _ in false }, makeShell: { _ in NSView() })
    precondition(admission.registerInitial(ChromiumProductWindow(state: window, shell: shell), nativeWindow: 8300))

    var unbound = Native.tab(83009, window: 8300, opener: 83001, flags: UInt32(BARC_DISCOVERY_TAB_PEEK.rawValue))
    unbound.peek_source_tab = 83001
    Native.tabs.append(unbound)
    let items = tabs.tree.items.count
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(tabs.tree.items.count == items && !tabs.sessions.contains { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == 83009 },
                 "a Peek tab of the source's own client is never adopted as an ordinary tab")
    Native.tabs.removeAll { $0.tab == 83009 }

    let observation = Native.observers.first { $0.value.3 == 83001 }!
    "https://fixture.invalid/peek-target".withCString { url in
        observation.value.0?(observation.value.1, observation.key, Int32(BARC_TAB_PEEK_REQUESTED.rawValue), 8300, 83001, url, nil, 7, 0)
    }
    precondition(sourceNavigation.pendingPeekRequestID == 7, "the source asked for a Peek")
    Native.onCreatePeek = { owner, _, _ in (owner, 83002) }
    let clients = Native.windows.count
    guard let created = admission.createPeek(from: source, request: 7, in: window) else { preconditionFailure("the Peek is made") }
    let peek = created.page, peekID = peek.itemID, peekNavigation = peek.navigation as! ChromiumPageNavigation
    precondition(created.accepted && peek.isDetached && peekNavigation.nativeWindowID == 8300 && Native.windows.count == clients,
                 "the Peek is a tab of its source's own client, with no second client")
    precondition(admission.ownsPeek(peek, source: source, in: window), "it is owned as the source's Peek")

    let header = NSView(), actions = NSView()
    Native.onSelectWindow = { _ in 0 }
    precondition(host.presentPeek(source: sourceNavigation, page: peekNavigation,
                                 header: header, actions: actions, dismiss: {}, in: window) == 0
        && header.superview == nil && actions.superview == nil && Native.windows[8300]?.active_tab == 83001,
        "a refused native selection leaves the card unmounted and keeps the source selected")
    Native.onSelectWindow = nil
    let generation = host.presentPeek(source: sourceNavigation, page: peekNavigation,
                                      header: header, actions: actions, dismiss: {}, in: window)
    precondition(generation != 0 && Native.windows[8300]?.active_tab == 83002,
                 "the card explicitly activates the Peek outside the renderer's input event")
    admission.apply(Native.bridge.readSnapshot()!)
    precondition(window.selectedItemID == sourceID && tabs.item(peekID) == nil && peek.isDetached,
                 "while the Peek has the keys the model stays on the source and does not adopt the Peek as a tab")
    let peekView = Native.pageViews[83002]!
    let sourceContainer = sourceView.superview
    precondition(sourceView.isDescendant(of: barkRoot!) && peekView.isDescendant(of: barkRoot!),
                 "the source stays placed behind the Peek")

    let split = promoteToSplit
        ? (originalSplit?.inserting(peekID, beside: sourceID, after: true) ?? SplitRecord([sourceID, peekID]))
        : nil
    let siblingView = Native.pageViews[83003], siblingContainer = siblingView?.superview
    let tokens = Native.nextToken, clears = Native.peekRoleClears
    precondition(!host.isNativeSelection(peekNavigation, in: window) &&
        host.isNativePeekSelection(peekNavigation, source: sourceNavigation, in: window),
        "the mounted card owns Peek selection while the ordinary layout still holds the source")
    if promoteToSplit {
        let cardSlot = peekView.superview!, displaced = NSView()
        displaced.addSubview(peekView)
        precondition(!admission.promotePeek(peek, source: source, in: window, intoSplit: split))
        precondition(peek.isDetached && Native.peekRoleClears == clears && window.selectedItemID == sourceID,
                     "the selected native tab cannot promote from a card that lost its page")
        cardSlot.addSubview(peekView)
    }
    precondition(admission.promotePeek(peek, source: source, in: window, intoSplit: split),
                 "the Peek is promoted in place")
    precondition(tabs.session(for: peekID) === peek && peek.navigation === peekNavigation && !peek.isDetached
                 && peekNavigation.nativeWindowID == 8300 && Native.peekRoleClears == clears + 1 && Native.nextToken == tokens,
                 "the same live page becomes a tab of the same client, its Peek role cleared, with no new observation")
    precondition(tabs.opener(of: peekID) == sourceID && window.selectedItemID == peekID
                 && window.split == split && peekView.isDescendant(of: barkRoot!),
                 "the same document is selected either as a tab or in the new split")
    if promoteToSplit {
        precondition(barkRoot?.split?.focused == 83002 && sourceView.superview === sourceContainer,
                     "split promotion focuses the Peek and retains the original source slot")
        if existingSplit {
            precondition(barkRoot?.split?.panes.compactMap { $0?.tab } == [83001, 83002, 83003] &&
                         barkRoot?.split?.vertical == true && siblingView?.superview === siblingContainer,
                         "the new pane goes beside the source, keeping the sibling slot and split orientation")
        }
    }
    precondition(header.superview == nil && actions.superview == nil, "promotion removes the card controls")
    for owner in Array(Native.windows.keys) { Native.end(owner) }
    tabs.saveNow()
}

/// The first selected page can wait for context policy before the saved split
/// request exists. It is still one accepted-pending product presentation.
@MainActor private func checkPendingInitialPageRestoration() throws {
    for mode in ["single", "mixed", "closed", "refused", "new-owner"] {
        let mixed = mode == "mixed"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarcPendingInitial-\(UUID())")
        let suite = "BarcPendingInitial-\(UUID())", registry = WindowRegistry()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var tree = TabTree()
        tree.createSpace(id: Native.work, name: "Work", icon: "briefcase", accentHex: "#123456", after: nil)
        tree.createSpace(id: Native.personal, name: "Personal", icon: "person", accentHex: "#654321", after: Native.work)
        let ids = (0..<(mixed ? 4 : 1)).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            _ = try tree.createTab(id: id, url: URL(string: "https://fixture.invalid/pending-\(index)")!,
                title: "Saved", in: .tabs(spaceID: index % 2 == 0 ? Native.work : Native.personal), after: nil)
        }
        let alternate = UUID()
        _ = try tree.createTab(id: alternate, url: URL(string: "https://fixture.invalid/new-owner")!,
            title: "Other", in: .tabs(spaceID: Native.personal), after: nil)
        let selected = ids.last!, profile = mixed ? Native.personal : Native.work
        let layout = mixed ? SplitRecord(ids, orientation: .vertical) : nil
        var device = DeviceState(); device.firstLaunchCompleted = true
        device.windows = [WindowRecord(id: UUID(), spaceID: profile,
            selectedItemBySpace: [profile: selected], split: layout)]
        let store = TabStore(directory: root); store.save(tree, device); store.flush()
        let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: root.appendingPathComponent("Boosts.json")))
        let tabs = TabsController(settings: settings, windowRegistry: registry,
            blocker: ContentBlockerManager(settings: settings, storageDirectory: root.appendingPathComponent("Blocker")),
            sponsorBlock: SponsorBlockManager(settings: settings), siteRouting: SiteRoutingManager(settings: settings),
            profileEngine: .chromium, directory: root)
        let concrete = ChromiumNativePageHost(bridge: Native.bridge)
        let delivery = DelayedCreationHost(concrete); delivery.delayedItem = selected
        tabs.nativePageHost = delivery
        let admission = ChromiumCreatedPageAdmission(bridge: Native.bridge, host: concrete, tabs: tabs,
            registry: registry, isUtility: { _ in false }, makeShell: { _ in NSView() })
        let state = admission.prepareInitialWindow()!
        let native: Int32 = mixed ? 9601 : 9501
        Native.restoring = true
        Native.onSelectWindow = { owner in
            guard let group = Native.windows[owner]?.physical_group else { return 0 }
            for key in Array(Native.windows.keys) where Native.windows[key]?.physical_group == group {
                Native.windows[key]?.selected_client = owner
            }
            return 1
        }
        Native.windows[native] = Native.window(native, group: UInt64(native), profile: profile, flags: 4 | 8, active: native * 10)
        Native.tabs.append(Native.tab(native * 10, window: native, flags: 2))
        let peer: Int32 = mixed ? 9602 : 9502
        if mixed || mode == "new-owner" {
            Native.windows[peer] = Native.window(peer, group: UInt64(native), profile: mixed ? Native.work : Native.personal, flags: 8, active: peer * 10)
            Native.windows[peer]?.selected_client = native
            Native.tabs.append(Native.tab(peer * 10, window: peer, flags: 2))
        }
        let shows = Native.shown.count, loads = Native.restoredURLs.count
        var outcomes: [NativeSplitOutcome] = [], laterOwner: Int32?
        let accepted = admission.admitRestoredWindow(state, native: native, profile: profile,
            show: true, canPresent: { true }, completion: { outcome in
                outcomes.append(outcome)
                if outcome == .superseded {
                    precondition(admission.whenProductPresented(state) { laterOwner = $0 })
                }
            })
        precondition(delivery.isPending && state.nativePresentationIsPreparing && !state.nativeSplitIsPreparing)
        precondition(accepted, "A pending initial selected page was rejected before split preparation")
        precondition(outcomes.isEmpty && Native.shown.count == shows && Native.restoredURLs.count == loads)
        precondition(registry.windows[state.id] === state && state.selectedItemID == selected && state.split == layout)
        if mode == "closed" { admission.cancelPendingProductPresentation(); registry.unregister(state.id) }
        if mode == "refused" { Native.viewless.insert(native * 10) }
        if mode == "new-owner" {
            tabs.select(alternate, in: state)
            precondition(outcomes == [.superseded] && laterOwner == peer)
            precondition(state.selectedItemID == alternate && Native.shown.count == shows)
        }
        delivery.resolve()
        Native.viewless.remove(native * 10)
        let succeeded = mode == "single" || mixed
        if succeeded {
            precondition(outcomes == [.admitted] && Native.shown.count == shows + 1)
            precondition(Native.restoredURLs.count == loads + ids.count && ids.allSatisfy { tabs.session(for: $0)?.navigation != nil })
            precondition(state.split == layout && state.selectedItemID == selected)
        } else if mode != "new-owner" {
            precondition(outcomes == [.refused] && Native.shown.count == shows, "\(mode) restore returned \(outcomes) after \(Native.shown.count - shows) shows")
        }
        precondition(Set(tabs.tree.items.keys) == Set(tree.items.keys))
        if let layout, succeeded {
            let pages = Dictionary(uniqueKeysWithValues: ids.map { ($0, tabs.session(for: $0)!) })
            precondition(concrete.isSplit(layout, pages: pages, activeItemID: selected, in: state))
        }
        for owner in Array(Native.windows.keys) where Native.windows[owner]?.physical_group == UInt64(native) { Native.end(owner) }
        admission.apply(Native.bridge.readSnapshot()!)
        Native.onSelectWindow = nil; Native.restoring = false
    }
}
