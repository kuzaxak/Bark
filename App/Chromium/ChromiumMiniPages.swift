import AppKit
import BarcChromium
import NookWeb

/// Where the app keeps the controllers of its compact windows' pages.
@MainActor
protocol ChromiumMiniRegistry: AnyObject {
    func nativeController(tab: Int32) -> (any DetachedPageWindowController)?
    func retainNative(_ controller: any DetachedPageWindowController) -> Bool
    func relinquishNativeHeader(window: Int32, except tab: Int32)
}

/// The compact windows a discovery drain reports: the mini window for a link from another app,
/// and pages' popups. Every page gets its controller and the selected one is shown. A window
/// that waits for the app and is not shown in the drain has its tabs closed, so that nothing waits
/// unseen.
@MainActor
final class ChromiumMiniPages {
    typealias MakeController = (Profile, ChromiumPageNavigation, BrowserWindowState?) -> ChromiumMiniWindowController?

    private let bridge: BarcBridge
    private let tabs: TabsController
    private let registry: any ChromiumMiniRegistry
    private let makeController: MakeController

    init(bridge: BarcBridge, tabs: TabsController, registry: any ChromiumMiniRegistry, makeController: @escaping MakeController) {
        self.bridge = bridge
        self.tabs = tabs
        self.registry = registry
        self.makeController = makeController
    }

    /// `accepting` is false while the app takes no windows; `activeWindow` is the origin of a
    /// page whose opener the model does not know.
    func apply(_ snapshot: ChromiumDiscoverySnapshot, accepting: @escaping () -> Bool, activeWindow: BrowserWindowState?) {
        for row in snapshot.windows where row.flags & BARC_DISCOVERY_COMPACT_MINI.rawValue != 0 &&
            row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 {
            if accepting(), present(row, snapshot: snapshot, activeWindow: activeWindow, accepting: accepting) { continue }
            closePendingTabs(in: row, snapshot: snapshot)
        }
    }

    private func present(_ row: BarcDiscoveryWindow, snapshot: ChromiumDiscoverySnapshot, activeWindow: BrowserWindowState?,
                         accepting: @escaping () -> Bool) -> Bool {
        guard let profile = profile(of: row) else { return false }
        // All real pages retain an observer, including a queued incoming
        // document superseded by a newer selected tab before admission.
        for tab in snapshot.tabs where tab.window == row.window {
            guard registry.nativeController(tab: tab.tab) == nil,
                  let navigation = try? ChromiumPageNavigation(profileID: profile.id, window: row.window, tab: tab.tab,
                                                               bridge: bridge, privateSession: profile.isEphemeral),
                  let controller = makeController(profile, navigation, origin(of: tab) ?? activeWindow) else { continue }
            if !registry.retainNative(controller) {
                navigation.invalidate() // Observation only; no unclaimed native close.
            }
        }
        func canPresent() -> Bool { accepting() && currentSelection(of: row) != nil }
        guard let selected = registry.nativeController(tab: row.active_tab) as? ChromiumMiniWindowController,
              selected.nativeWindowID == row.window, canPresent() else { return false }
        registry.relinquishNativeHeader(window: row.window, except: row.active_tab)
        return selected.present(canPresent: canPresent)
    }

    private func currentSelection(of row: BarcDiscoveryWindow) -> BarcDiscoveryWindow? {
        let compact = UInt32(BARC_DISCOVERY_COMPACT_MINI.rawValue)
        let ending = UInt32(BARC_DISCOVERY_OWNER_ENDING.rawValue)
        guard row.selected_client == row.window,
              let current = bridge.windowState(row.window), current.window == row.window,
              current.physical_group == row.physical_group, current.physical_group != 0,
              current.selected_client == row.window, current.active_tab == row.active_tab,
              current.flags & compact != 0, current.flags & ending == 0 else { return nil }
        return current
    }

    private func closePendingTabs(in row: BarcDiscoveryWindow, snapshot: ChromiumDiscoverySnapshot) {
        let waiting = UInt32(BARC_DISCOVERY_AWAITING_ADMISSION.rawValue)
        guard row.flags & waiting != 0 else { return }
        let tabs = snapshot.tabs.filter { $0.window == row.window }
        // Close the active tab last so the normal close order keeps the
        // captured selection valid until the window's other tabs are gone.
        let ordered = tabs.filter { $0.tab != row.active_tab } + tabs.filter { $0.tab == row.active_tab }
        for tab in ordered {
            guard let current = currentSelection(of: row), current.flags & waiting != 0 else { return }
            _ = bridge.tab_close(row.window, tab.tab)
        }
    }

    private func profile(of row: BarcDiscoveryWindow) -> Profile? {
        guard let id = bridge.identity(row) else { return nil }
        if row.profile_kind == BARC_DISCOVERY_GUEST.rawValue {
            return tabs.privateWindows.compactMap(\.ephemeralProfile).first(where: { $0.id == id }) ??
                Profile.createEphemeral(id: id)
        }
        guard row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue, tabs.isProfileAvailable(id) else { return nil }
        return tabs.profile(forStore: id)
    }

    /// The window of the page that opened `tab`, when the model knows that page.
    private func origin(of tab: BarcDiscoveryTab) -> BrowserWindowState? {
        guard tab.opener_tab > 0,
              let opener = tabs.sessions.first(where: { ($0.navigation as? ChromiumPageNavigation)?.nativeTabID == tab.opener_tab })
        else { return nil }
        return tabs.allWindows.first { tabs.isNativePageOwner(opener, in: $0) }
    }
}
