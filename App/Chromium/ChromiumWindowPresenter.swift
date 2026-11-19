import AppKit
import BarcChromium
import NookTabsCore

/// Bark's own window, whose root view holds the sidebar and places the pages of every client in it,
/// one client per profile. Selecting a client gives it the window; the sidebar never moves.
@MainActor
final class ChromiumHostPresenter {
    let root: ChromiumWindowRoot
    private let bridge: BarcBridge
    private let group: UInt64
    private weak var sidebar: NSView?

    init?(bridge: BarcBridge, client: Int32, sidebar: NSView) {
        guard let group = bridge.windowState(client)?.physical_group, group != 0 else { return nil }
        self.bridge = bridge
        self.group = group
        root = ChromiumWindowRoot(bridge: bridge, client: client) { index, positions, length in
            let minimum = SplitRecord.minimumPaneFraction(count: positions.count + 1, length: Double(length))
            let range = SplitRecord.dividerRange(at: index, in: positions.map { Double($0) }, minimum: minimum)
            return range.map { CGFloat($0.lowerBound)...CGFloat($0.upperBound) }
        }
        guard root.attach() else { return nil }
        root.setSidebar(sidebar)
        self.sidebar = sidebar
    }

    /// The engine's selected client of this window shows the sidebar.
    func ownsSidebar(_ client: Int32) -> Bool {
        guard root.holdsSidebar(sidebar), let row = bridge.windowState(client) else { return false }
        return row.physical_group == group && row.selected_client == client &&
            bridge.window_native_shell_is_owned(client, Unmanaged.passUnretained(root).toOpaque()) == 1
    }

    /// Selects `client` in the engine, which gives it the window.
    func attachSidebar(to client: Int32) -> Bool {
        guard let row = bridge.windowState(client), row.physical_group == group else { return false }
        if row.selected_client != client, bridge.window_select(client) != 1 { return false }
        return ownsSidebar(client)
    }

    func showPage(_ tab: Int32, of client: Int32) -> Bool { root.show(tab: tab, of: client) }

    func setPageHidden(_ hidden: Bool, client: Int32) {
        root.pageHidden = hidden
    }

    func setHeader(_ header: NSView?, replacing expected: NSView?, height: Int32, owner: Int32) -> Bool {
        ownsSidebar(owner) && root.setHeader(header, replacing: expected, height: CGFloat(height))
    }

    func downloadLaunch() -> (window: NSWindow, point: NSPoint)? {
        guard let window = root.window,
              let point = root.downloadLaunchPoint(pointer: window.mouseLocationOutsideOfEventStream) else { return nil }
        return (window, point)
    }

    func showSplit(_ split: ChromiumWindowRoot.Split?, while isCurrent: () -> Bool = { true }) -> Bool {
        guard let split else { return isCurrent() && root.endSplit() }
        return root.showSplit(split, while: isCurrent)
    }

    var shownSplit: ChromiumWindowRoot.Split? { root.split }

    func presentPeek(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, header: NSView, actions: NSView,
                     dismiss: @escaping () -> Void) -> UInt64 {
        root.showPeek(.init(source: source, page: page), header: header, actions: actions, dismiss: dismiss)
    }

    func isPeekPresented(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, generation: UInt64,
                         header: NSView, actions: NSView) -> Bool {
        root.showsPeek(.init(source: source, page: page), generation: generation, header: header, actions: actions)
    }

    func hidePeek(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, generation: UInt64,
                  header: NSView, actions: NSView) {
        guard root.showsPeek(.init(source: source, page: page), generation: generation, header: header, actions: actions) else { return }
        root.hidePeek(generation: generation)
    }
}
