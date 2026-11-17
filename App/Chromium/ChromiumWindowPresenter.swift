import AppKit
import BarcChromium

/// Puts one window's sidebar and selected page on screen. On the old path Chromium's window lays
/// them out around the sidebar it was given (`--bark-window=legacy`); in the Bark window, the default, the app's
/// `ChromiumWindowRoot` does. Chosen per window by whether the engine takes a root view.
@MainActor
protocol ChromiumWindowPresenter: AnyObject {
    /// The one client this window can show, or nil when it shows any of its physical group.
    var onlyClient: Int32? { get }
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
    /// Shows `split`'s panes of `client`, or with nil the focused page alone; false where the app
    /// does not lay out the page.
    func showSplit(_ split: ChromiumWindowRoot.Split?, of client: Int32) -> Bool
    /// The split the window shows; nil for one page, and where the app does not lay out the page.
    var shownSplit: ChromiumWindowRoot.Split? { get }
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

    var onlyClient: Int32? { nil }

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

    func showSplit(_ split: ChromiumWindowRoot.Split?, of client: Int32) -> Bool { false }

    var shownSplit: ChromiumWindowRoot.Split? { nil }
}

/// Bark's own window, with one client, whose root view holds the sidebar and the page the app places.
@MainActor
final class ChromiumHostPresenter: ChromiumWindowPresenter {
    let root: ChromiumWindowRoot
    private weak var sidebar: NSView?

    init?(bridge: BarcBridge, client: Int32, sidebar: NSView) {
        root = ChromiumWindowRoot(bridge: bridge, nativeWindow: client)
        guard root.attach() else { return nil }
        root.setSidebar(sidebar)
        self.sidebar = sidebar
    }

    var onlyClient: Int32? { root.nativeWindow }

    func ownsSidebar(_ client: Int32) -> Bool { client == root.nativeWindow && root.holdsSidebar(sidebar) }

    func attachSidebar(to client: Int32) -> Bool { ownsSidebar(client) }

    func detachSidebar(from client: Int32) -> Bool { !ownsSidebar(client) }

    func showPage(_ tab: Int32, of client: Int32) -> Bool { client == root.nativeWindow && root.show(tab: tab) }

    func setPageHidden(_ hidden: Bool, client: Int32) {
        guard client == root.nativeWindow else { return }
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

    func showSplit(_ split: ChromiumWindowRoot.Split?, of client: Int32) -> Bool {
        guard client == root.nativeWindow else { return false }
        guard let split else { return root.endSplit() }
        return root.showSplit(split)
    }

    var shownSplit: ChromiumWindowRoot.Split? { root.split }
}
