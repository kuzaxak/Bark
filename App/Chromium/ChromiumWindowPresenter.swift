import AppKit
import BarcChromium
import NookTabsCore

/// Puts one window's sidebar and selected page on screen. On the old path Chromium's window lays
/// them out around the sidebar it was given (`--bark-window=legacy`); in the Bark window, the default, the app's
/// `ChromiumWindowRoot` does. Chosen per window by whether the engine takes a root view.
@MainActor
protocol ChromiumWindowPresenter: AnyObject {
    /// Whether `client` shows this window's sidebar.
    func ownsSidebar(_ client: Int32) -> Bool
    /// Gives the sidebar to `client`; false when it refuses.
    func attachSidebar(to client: Int32) -> Bool
    /// Takes the sidebar back from `client`; false when `client` keeps it.
    func detachSidebar(from client: Int32) -> Bool
    /// Shows `client`'s selected `tab` as the window's page.
    func showPage(_ tab: Int32, of client: Int32) -> Bool
    /// The window shows no page of its own: page commands do nothing and no page shows.
    func setPageHidden(_ hidden: Bool, client: Int32)
    /// The optional bar above the page; `expected` is the bar installed before.
    func setHeader(_ header: NSView?, replacing expected: NSView?, height: Int32, owner: Int32) -> Bool
    /// The window and the point in it a download that starts now flies from; nil where the app
    /// does not lay out the page.
    func downloadLaunch() -> (window: NSWindow, point: NSPoint)?
    /// Whether the app lays out this window's split panes itself.
    var laysOutSplits: Bool { get }
    /// Shows `split`'s panes, or with nil the focused page alone; false where the app does not lay
    /// out the page.
    func showSplit(_ split: ChromiumWindowRoot.Split?) -> Bool
    /// The split the window shows; nil for one page, and where the app does not lay out the page.
    var shownSplit: ChromiumWindowRoot.Split? { get }
    /// Whether the sidebar moves to the client whose page the window shows.
    var sidebarFollowsClient: Bool { get }
    /// Shows `page` in a Peek card over `source`, with `header` above it and `actions` beside it.
    /// Returns the card's generation, or 0. `dismiss` runs on a click outside the card.
    func presentPeek(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, header: NSView, actions: NSView,
                     dismiss: @escaping () -> Void) -> UInt64
    func isPeekPresented(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, generation: UInt64,
                         header: NSView, actions: NSView) -> Bool
    func hidePeek(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, generation: UInt64,
                  header: NSView, actions: NSView)
}

enum ChromiumWindowPresenters {
    /// The host presenter when the engine gives `client`'s window to the app, else the old path's.
    @MainActor static func make(bridge: BarcBridge, client: Int32, sidebar: NSView) -> any ChromiumWindowPresenter {
        ChromiumHostPresenter(bridge: bridge, client: client, sidebar: sidebar)
            ?? ChromiumLegacyPresenter(bridge: bridge, sidebar: sidebar)
    }
}

/// Chromium's own window: the sidebar is attached to one client at a time, and Chromium shows
/// that client's selected tab beside it.
@MainActor
final class ChromiumLegacyPresenter: ChromiumWindowPresenter {
    private let bridge: BarcBridge
    private weak var sidebar: NSView?

    init(bridge: BarcBridge, sidebar: NSView) {
        self.bridge = bridge
        self.sidebar = sidebar
    }

    private var pointer: UnsafeMutableRawPointer? { sidebar.map { Unmanaged.passUnretained($0).toOpaque() } }

    func ownsSidebar(_ client: Int32) -> Bool {
        guard let pointer else { return false }
        return bridge.window_native_shell_is_owned(client, pointer) == 1
    }

    func attachSidebar(to client: Int32) -> Bool {
        guard let pointer else { return false }
        return bridge.window_attach_native_shell(client, pointer) == 1
    }

    func detachSidebar(from client: Int32) -> Bool {
        guard let pointer else { return false }
        return bridge.window_detach_native_shell_if_owned(client, pointer) == 1
    }

    func showPage(_ tab: Int32, of client: Int32) -> Bool { true }

    func setPageHidden(_ hidden: Bool, client: Int32) {
        _ = bridge.window_set_page_hidden(client, hidden ? 1 : 0)
    }

    func setHeader(_ header: NSView?, replacing expected: NSView?, height: Int32, owner: Int32) -> Bool {
        guard let pointer, ownsSidebar(owner) else { return false }
        return bridge.window_set_native_header(owner, pointer, expected.map { Unmanaged.passUnretained($0).toOpaque() },
                                               header.map { Unmanaged.passUnretained($0).toOpaque() }, height) == 1
    }

    func downloadLaunch() -> (window: NSWindow, point: NSPoint)? { nil }

    var laysOutSplits: Bool { false }

    func showSplit(_ split: ChromiumWindowRoot.Split?) -> Bool { false }

    var shownSplit: ChromiumWindowRoot.Split? { nil }

    var sidebarFollowsClient: Bool { true }

    func presentPeek(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, header: NSView, actions: NSView,
                     dismiss: @escaping () -> Void) -> UInt64 {
        guard let pointer else { return 0 }
        return bridge.tab_present_peek(source.client, source.tab, page.client, page.tab, pointer,
                                       Unmanaged.passUnretained(header).toOpaque(), Unmanaged.passUnretained(actions).toOpaque())
    }

    func isPeekPresented(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, generation: UInt64,
                         header: NSView, actions: NSView) -> Bool {
        bridge.tab_is_peek_presented(source.client, source.tab, page.client, page.tab, generation,
                                     Unmanaged.passUnretained(header).toOpaque(), Unmanaged.passUnretained(actions).toOpaque()) == 1
    }

    func hidePeek(source: ChromiumWindowRoot.Pane, page: ChromiumWindowRoot.Pane, generation: UInt64,
                  header: NSView, actions: NSView) {
        _ = bridge.tab_hide_peek(source.client, source.tab, page.client, page.tab, generation,
                                 Unmanaged.passUnretained(header).toOpaque(), Unmanaged.passUnretained(actions).toOpaque())
    }
}

/// Bark's own window, whose root view holds the sidebar and places the pages of every client in it,
/// one client per profile. Selecting a client gives it the window; the sidebar never moves.
@MainActor
final class ChromiumHostPresenter: ChromiumWindowPresenter {
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
        return row.physical_group == group && row.selected_client == client
    }

    /// Selects `client` in the engine, which gives it the window.
    func attachSidebar(to client: Int32) -> Bool {
        guard let row = bridge.windowState(client), row.physical_group == group else { return false }
        if row.selected_client != client, bridge.window_select(client) != 1 { return false }
        return ownsSidebar(client)
    }

    func detachSidebar(from client: Int32) -> Bool { true }

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

    var laysOutSplits: Bool { true }

    func showSplit(_ split: ChromiumWindowRoot.Split?) -> Bool {
        guard let split else { return root.endSplit() }
        return root.showSplit(split)
    }

    var shownSplit: ChromiumWindowRoot.Split? { root.split }

    var sidebarFollowsClient: Bool { false }

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
