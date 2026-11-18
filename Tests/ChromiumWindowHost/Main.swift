// Licensed under GPL-3.0. See LICENSE.
// Drives the shipped ChromiumWindowRoot against a table that stands in for the engine; no browser runs.
import AppKit
import BarcChromium

@MainActor
private enum Engine {
    static var rootAccepted: Int32 = 1
    static var roots: [(Int32, UnsafeMutableRawPointer?)] = []
    static var pages: [Int32: NSView] = [:]
    static var observer: (BarcWindowHostCallback, UnsafeMutableRawPointer?)?
    static var observations = 0
    static var unobserved: [UInt64] = []
    static var chrome: [ChromiumWindowRoot.Lights] = []
    /// The client each chrome call addressed.
    static var chromeClients: [Int32] = []
    static var reloads: [Int32] = []
    static var reloadClients: [Int32] = []
    /// The window's live clients, and the client of each tab not the first client's.
    static var clients: Set<Int32> = [5]
    static var tabClients: [Int32: Int32] = [:]
    static func owns(_ client: Int32, _ tab: Int32) -> Bool { clients.contains(client) && (tabClients[tab] ?? 5) == client }
    static let token: UInt64 = 77

    static func send(kind: BarcWindowHostEventKind, tab: Int32, view: NSView? = nil, fullscreen: BarcFullscreenKind = BARC_FULLSCREEN_NONE,
                     size: Int = MemoryLayout<BarcWindowHostEvent>.size, window: Int32 = 5) {
        var event = BarcWindowHostEvent(size: size, kind: Int32(kind.rawValue), window: window, tab: tab,
                                        fullscreen: Int32(fullscreen.rawValue),
                                        view: view.map { Unmanaged.passUnretained($0).toOpaque() })
        observer!.0(&event, observer!.1)
    }
}

@MainActor private func table() -> BarcBridge {
    var bridge = trappingBridge
    bridge.window_set_root_view = { window, view in
        MainActor.assumeIsolated { Engine.roots.append((window, view)); return Engine.rootAccepted }
    }
    bridge.window_host_observe = { window, callback, context in
        MainActor.assumeIsolated {
            precondition(window == 5, "observes the window it was given")
            Engine.observations += 1
            Engine.observer = (callback!, context)
            return Engine.token
        }
    }
    bridge.window_host_unobserve = { token in MainActor.assumeIsolated { Engine.unobserved.append(token) } }
    bridge.tab_native_view = { window, tab in
        MainActor.assumeIsolated {
            guard Engine.owns(window, tab) else { return nil }
            return Engine.pages[tab].map { Unmanaged.passUnretained($0).toOpaque() }
        }
    }
    bridge.window_set_chrome = { window, chrome in
        MainActor.assumeIsolated {
            precondition(chrome!.pointee.size == MemoryLayout<BarcWindowChrome>.size, "a whole chrome")
            guard Engine.clients.contains(window) else { return 0 }
            Engine.chromeClients.append(window)
            Engine.chrome.append(.init(titlebarHeight: chrome!.pointee.titlebar_height, leadingInset: chrome!.pointee.leading_inset))
            return 1
        }
    }
    bridge.tab_reload = { window, tab in MainActor.assumeIsolated {
        guard Engine.owns(window, tab) else { return 0 }
        Engine.reloads.append(tab); Engine.reloadClients.append(window); return 1
    } }
    return bridge
}

/// A page view whose first subview takes keys, as a renderer's view does.
private final class PageView: NSView {
    let input = Focusable()
    override init(frame: NSRect) { super.init(frame: frame); addSubview(input) }
    required init?(coder: NSCoder) { nil }
    final class Focusable: NSView { override var acceptsFirstResponder: Bool { true } }
}

@MainActor private func inRoot(_ view: NSView, _ root: NSView) -> CGRect { root.convert(view.bounds, from: view) }

/// The crashed-page card's Reload button shown in `view`.
@MainActor private func reloadButton(in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == "Reload", !button.isHiddenOrHasHiddenAncestor { return button }
    return view.subviews.lazy.compactMap { reloadButton(in: $0) }.first
}

@main struct Main {
    @MainActor static func main() {
        _ = NSApplication.shared
        layoutCases()
        libraryLayoutCases()
        lightsCases()

        Engine.rootAccepted = 0
        let refused = ChromiumWindowRoot(bridge: table(), client: 5)
        precondition(!refused.attach() && Engine.unobserved == [Engine.token], "a refused root view keeps no observation")
        precondition(Engine.chrome.isEmpty, "a refused root view places no lights")
        Engine.rootAccepted = 1
        Engine.unobserved = []
        Engine.observations = 0

        weak var released: ChromiumWindowRoot?
        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let root = ChromiumWindowRoot(bridge: table(), client: 5)
            released = root
            root.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            precondition(root.attach(), "an accepted root view observes the window")
            precondition(Engine.roots.last!.1 == Unmanaged.passUnretained(root).toOpaque(), "the root hands itself over")
            precondition(Engine.chrome == [ChromiumWindowRoot.Arc.lights], "attaching places the lights at Arc's: \(Engine.chrome)")
            precondition(!root.attach() && Engine.observations == 1, "a root attaches once")

            let sidebar = NSView()
            root.setSidebar(sidebar)
            precondition(root.holdsSidebar(sidebar) && inRoot(sidebar, root) == CGRect(x: 0, y: 0, width: 247, height: 700),
                         "the sidebar fills its column: \(inRoot(sidebar, root))")

            let backdrop = NSView()
            root.setBackdrop(backdrop)
            precondition(root.subviews.first === backdrop && backdrop.frame == root.bounds && backdrop.autoresizingMask == [.width, .height],
                         "the space's backdrop fills the window behind the sidebar and the page frame")

            let first = PageView(), second = PageView()
            Engine.pages = [10: first, 11: second]
            precondition(!root.show(tab: 12, of: 5) && root.shownTab == 0, "no page view, nothing shown")
            precondition(root.show(tab: 10, of: 5), "a tab with a page view is shown")
            precondition(first.isDescendant(of: root) && inRoot(first, root) == CGRect(x: 247, y: 10, width: 643, height: 680)
                         && root.shownTab == 10, "the page fills the page frame: \(inRoot(first, root))")
            precondition(first.autoresizingMask == [.width, .height] && first.superview!.autoresizingMask == [.width, .height],
                         "the page and its frame follow a live resize without a layout pass")
            precondition(root.show(tab: 10, of: 5) && first.superview != nil, "showing the same tab again keeps it")
            precondition(root.show(tab: 11, of: 5) && second.isDescendant(of: root) && first.superview == nil, "the next page replaces the last")
            precondition(!root.show(tab: 12, of: 5) && second.isDescendant(of: root) && root.shownTab == 11, "a missing page keeps the shown one")

            root.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            root.layoutSubtreeIfNeeded()
            precondition(inRoot(second, root) == CGRect(x: 247, y: 10, width: 943, height: 780),
                         "the page follows the root's size: \(inRoot(second, root))")

            window.contentView = root
            precondition(Engine.chrome.last == ChromiumWindowRoot.Arc.lights, "moving into a window places the lights")
            let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)! }
            let field = NSTextField()
            sidebar.addSubview(field)
            window.makeFirstResponder(first.input)
            precondition(root.show(tab: 10, of: 5) && window.firstResponder === first.input, "a newly shown page takes the keys")
            precondition(root.show(tab: 11, of: 5) && window.firstResponder === second.input, "a tab switch moves the keys to the new page")
            window.makeFirstResponder(field)
            let editing = window.firstResponder
            precondition(editing is NSText, "the sidebar field edits")
            precondition(root.show(tab: 10, of: 5) && window.firstResponder === editing, "a sidebar field keeps the keys when the page changes")
            precondition(root.show(tab: 11, of: 5), "back to the second page")
            root.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            root.layoutSubtreeIfNeeded()

            let shown = inRoot(second, root)
            root.sidebar = .hidden
            precondition(root.holdsSidebar(sidebar) && inRoot(sidebar, root).maxX <= 0,
                         "a hidden sidebar leaves the window's bounds but keeps its views: \(inRoot(sidebar, root))")
            let hidden = inRoot(second, root)
            precondition(hidden == CGRect(x: 10, y: 10, width: 1180, height: 780), "hidden: the page frame keeps 10 all round: \(hidden)")
            precondition(lights.allSatisfy(\.isHidden), "the lights hide with the sidebar")
            root.sidebar = .revealed
            precondition(inRoot(second, root) == hidden, "the page does not resize when the sidebar floats in")
            precondition(inRoot(sidebar, root) == CGRect(x: 5, y: 5, width: 247, height: 790),
                         "the revealed sidebar floats 5 from the edges: \(inRoot(sidebar, root))")
            precondition(root.subviews.firstIndex(of: sidebar.superview!)! > root.subviews.firstIndex(of: second.superview!.superview!)!,
                         "the revealed sidebar is above the page")
            precondition(!lights.contains(where: \.isHidden) && Engine.chrome.last == ChromiumWindowRoot.Arc.revealedLights,
                         "the lights come back inside the revealed sidebar")
            root.sidebar = .shown
            precondition(inRoot(second, root) == shown && Engine.chrome.last == ChromiumWindowRoot.Arc.lights,
                         "showing the sidebar again restores the page frame and the lights")

            downloadFlightCases(root: root, sidebar: sidebar, page: second, window: window)
            splitCases(root: root, sidebar: sidebar, window: window)
            precondition(root.show(tab: 11, of: 5) && root.split == nil && inRoot(second, root) == shown, "back to one page after the split cases")
            firstClientGoneCases(root: root, window: window)
            precondition(root.show(tab: 11, of: 5) && root.client == 5 && inRoot(second, root) == shown, "back to the first client's page")
            libraryCases(root: root, sidebar: sidebar, page: second, lights: lights)
            root.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            root.layoutSubtreeIfNeeded()
            precondition(inRoot(second, root) == shown, "the Library shut leaves the page frame as it was")

            Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_PAGE)
            precondition(root.pageFullscreen && inRoot(second, root) == root.bounds && inRoot(sidebar, root).maxX <= 0,
                         "page full screen: the page fills the window without the sidebar")
            Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_WINDOW)
            precondition(!root.pageFullscreen && inRoot(second, root) == shown && inRoot(sidebar, root).minX == 0,
                         "leaving page full screen for window full screen brings the frame back")
            Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_NONE)
            precondition(inRoot(second, root) == shown, "window full screen keeps the page frame")

            let bar = NSView()
            precondition(root.setHeader(bar, replacing: nil, height: 40), "a bar goes above the page")
            precondition(inRoot(bar, root) == CGRect(x: 247, y: 10, width: 943, height: 40)
                         && inRoot(second, root) == CGRect(x: 247, y: 50, width: 943, height: 740), "the page sits below the bar")
            Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_PAGE)
            precondition(inRoot(second, root) == root.bounds && (bar.isHidden || bar.frame.height == 0),
                         "a full-screen page has no bar above it: \(inRoot(second, root))")
            Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_NONE)
            precondition(!bar.isHidden && inRoot(bar, root) == CGRect(x: 247, y: 10, width: 943, height: 40)
                         && inRoot(second, root) == CGRect(x: 247, y: 50, width: 943, height: 740), "leaving full screen brings the bar back")
            let pagePanels = root.panelContainer(for: .page)
            precondition(root.panelContainer(for: .window) === root && root.panelContainer(for: .fitted) === pagePanels)
            let emptySpacePanel = NSView(frame: pagePanels.bounds)
            pagePanels.addSubview(emptySpacePanel)
            precondition(inRoot(emptySpacePanel, root) == inRoot(second, root),
                         "a full-page panel stays below the toolbar when an empty space is selected")
            let insideToolbar = CGPoint(x: bar.bounds.midX, y: bar.bounds.midY)
            let barPoint = root.convert(insideToolbar, from: bar)
            precondition(root.hitTest(root.convert(barPoint, to: root.superview)) === bar,
                         "the address bar receives clicks above a full-page overlay")
            emptySpacePanel.removeFromSuperview()
            precondition(!root.setHeader(nil, replacing: NSView(), height: 0), "another caller's bar is not removed")
            precondition(root.setHeader(nil, replacing: bar, height: 0) && bar.superview == nil && inRoot(second, root) == shown,
                         "removing the bar gives the page its height back")

            Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 10, view: first)
            precondition(!root.showsCrashedPage, "another tab's crash leaves the shown page")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 11, view: second)
            precondition(root.showsCrashedPage, "the shown page's crash shows the crashed state")
            precondition(root.show(tab: 10, of: 5) && root.showsCrashedPage, "a crashed tab shows its state when selected")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_RESTORED, tab: 10, view: first)
            precondition(!root.showsCrashedPage, "a reloaded page hides the crashed state")
            precondition(root.show(tab: 11, of: 5) && root.showsCrashedPage, "the other crashed tab still shows its state")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_RESTORED, tab: 11, view: second)
            precondition(!root.showsCrashedPage, "both pages restored")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 10, view: first)
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(root.show(tab: 10, of: 5) && !root.showsCrashedPage, "a tab that left the window forgets its crash here")
            precondition(root.show(tab: 11, of: 5), "back to the second page")

            root.pageHidden = true
            precondition(second.isHidden, "a window that shows no page of its own hides the page")
            precondition(root.show(tab: 10, of: 5) && first.isHidden, "a page shown while the window shows none stays hidden")
            root.pageHidden = false
            precondition(!first.isHidden, "the page shows again")
            precondition(root.show(tab: 11, of: 5), "back to the second page")

            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(second.isDescendant(of: root), "another tab's retirement leaves the shown page")
            Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 11)
            precondition(second.isDescendant(of: root), "a full-screen event removes no page")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 11, view: second, size: 8)
            precondition(second.isDescendant(of: root), "an event smaller than this app's is ignored")
            Engine.pages[11] = nil
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 11, view: second)
            precondition(second.superview == nil && root.shownTab == 0, "a closed tab's page leaves the root")
            precondition(root.show(tab: 10, of: 5) && first.isDescendant(of: root), "a page can be shown after the last one retired")

            let replacement = PageView()
            Engine.pages[10] = replacement
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(first.superview == nil && replacement.isDescendant(of: root) && root.shownTab == 10,
                         "a tab that replaced its contents shows its new page")
            Engine.pages[10] = first
            precondition(root.show(tab: 10, of: 5) && first.isDescendant(of: root), "back to the first page")

            let other = NSView()
            other.addSubview(first)
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(first.superview === other && root.shownTab == 0, "a retired page another root holds stays there")
            Engine.pages[11] = second
            precondition(root.show(tab: 11, of: 5) && second.isDescendant(of: root), "a page is shown after the moved one retired")
            other.addSubview(second)
            precondition(root.show(tab: 11, of: 5) && second.isDescendant(of: root), "a page another root took is shown again")
            let third = PageView()
            Engine.pages[11] = third
            other.addSubview(second)
            precondition(root.show(tab: 11, of: 5) && third.isDescendant(of: root) && second.superview === other,
                         "a tab's new page replaces only the page this root holds")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 11, view: second)
            precondition(third.isDescendant(of: root) && root.shownTab == 11, "a late retirement of a tab's old page leaves its new one")
            other.addSubview(third)
            root.pageHidden = true
            precondition(!third.isHidden, "hiding this root's page leaves a page another root took")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 11, view: third)
            precondition(!root.showsCrashedPage, "a crash of a page another root took is not drawn here")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_RESTORED, tab: 11, view: third)
            root.pageHidden = false
            precondition(Engine.unobserved.isEmpty, "a live root keeps observing")
            window.contentView = nil
        }
        precondition(released == nil, "the root is not retained by its observation")
        precondition(Engine.unobserved == [Engine.token], "a released root stops observing")
        print("Window host root: Arc's sidebar, page frame and lights; the Library in the sidebar's column; hides, reveals and full screen; one page at a time, crashed and retired pages, observes until released")
    }

    @MainActor static func layoutCases() {
        let window = CGRect(x: 0, y: 0, width: 1920, height: 991)
        typealias L = ChromiumWindowRoot.Layout
        let cases: [(CGRect, ChromiumWindowRoot.Sidebar, Bool, L)] = [
            (window, .shown, false, L(sidebar: CGRect(x: 0, y: 0, width: 247, height: 991),
                                      page: CGRect(x: 247, y: 10, width: 1663, height: 971), pageCornerRadius: 7)),
            (window, .hidden, false, L(sidebar: nil, page: CGRect(x: 10, y: 10, width: 1900, height: 971), pageCornerRadius: 7)),
            (window, .revealed, false, L(sidebar: CGRect(x: 5, y: 5, width: 247, height: 981),
                                         page: CGRect(x: 10, y: 10, width: 1900, height: 971), pageCornerRadius: 7, sidebarCornerRadius: 10)),
            (window, .shown, true, L(sidebar: nil, page: window, pageCornerRadius: 0)),
            (window, .revealed, true, L(sidebar: nil, page: window, pageCornerRadius: 0)),
            (.zero, .shown, false, L(sidebar: .zero, page: CGRect(x: 0, y: 10, width: 0, height: 0), pageCornerRadius: 7)),
            (CGRect(x: 0, y: 0, width: 200, height: 15), .shown, false,
             L(sidebar: CGRect(x: 0, y: 0, width: 200, height: 15), page: CGRect(x: 200, y: 10, width: 0, height: 0), pageCornerRadius: 7)),
        ]
        for (bounds, sidebar, fullscreen, expected) in cases {
            let actual = ChromiumWindowRoot.layout(in: bounds, sidebar: sidebar, pageFullscreen: fullscreen)
            precondition(actual == expected, "layout \(bounds) \(sidebar) \(fullscreen): \(actual)")
        }
    }

    @MainActor static func lightsCases() {
        precondition(ChromiumWindowRoot.lights(for: .shown) == .init(titlebarHeight: 48, leadingInset: 13), "Arc's lights centre (20, 24)")
        precondition(ChromiumWindowRoot.lights(for: .revealed) == .init(titlebarHeight: 57, leadingInset: 18), "revealed, (25, 28.5)")
        precondition(ChromiumWindowRoot.lights(for: .hidden) == nil, "no lights with the sidebar hidden")

        typealias P = ChromiumWindowRoot.LightsPlacement
        let arc = ChromiumWindowRoot.Arc.self
        precondition(arc.libraryLights == .init(titlebarHeight: 56, leadingInset: 16), "with the Library out Arc's first light is at (23, 28)")
        let cases: [(ChromiumWindowRoot.Sidebar, CGFloat, P)] = [
            (.shown, 0, P(lights: arc.lights, alpha: 1)),
            (.shown, 0.25, P(lights: arc.lights, alpha: 0.5)),
            (.shown, 0.75, P(lights: arc.libraryLights, alpha: 0.5)),
            (.shown, 1, P(lights: arc.libraryLights, alpha: 1)),
            (.shown, 1.5, P(lights: arc.libraryLights, alpha: 1)),
            (.revealed, 0.25, P(lights: arc.revealedLights, alpha: 0.5)),
            (.revealed, 1, P(lights: arc.libraryLights, alpha: 1)),
            (.hidden, 0, P(lights: nil, alpha: 1)),
            (.hidden, 0.25, P(lights: nil, alpha: 1)),
            (.hidden, 0.75, P(lights: arc.libraryLights, alpha: 0.5)),
            (.hidden, 1, P(lights: arc.libraryLights, alpha: 1)),
        ]
        for (sidebar, progress, expected) in cases {
            let actual = ChromiumWindowRoot.lights(for: sidebar, library: progress)
            precondition(actual == expected, "lights \(sidebar) with the Library \(progress) out: \(actual)")
        }
    }

    /// The Library comes out in the sidebar's column and pushes the page, as Arc's does; the sidebar's
    /// width is an input.
    @MainActor static func libraryLayoutCases() {
        let window = CGRect(x: 0, y: 0, width: 1920, height: 991)
        typealias L = ChromiumWindowRoot.Layout
        typealias Library = ChromiumWindowRoot.Library
        let list: CGFloat = 417, spaces: CGFloat = 840
        let cases: [(String, CGRect, ChromiumWindowRoot.Sidebar, CGFloat, Library, Bool, L)] = [
            ("open", window, .shown, 247, .init(preferredWidth: list, progress: 1), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 417, height: 991), page: CGRect(x: 417, y: 10, width: 1493, height: 971), pageCornerRadius: 7)),
            ("half out", window, .shown, 247, .init(preferredWidth: list, progress: 0.5), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 332, height: 991), page: CGRect(x: 332, y: 10, width: 1578, height: 971), pageCornerRadius: 7)),
            ("pulled past open", window, .shown, 247, .init(preferredWidth: list, progress: 1.5), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 502, height: 991), page: CGRect(x: 502, y: 10, width: 1408, height: 971), pageCornerRadius: 7)),
            ("Spaces", window, .shown, 247, .init(preferredWidth: spaces, progress: 1), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 840, height: 991), page: CGRect(x: 840, y: 10, width: 1070, height: 971), pageCornerRadius: 7)),
            ("wider sidebar, shut", window, .shown, 300, .init(preferredWidth: list, progress: 0), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 300, height: 991), page: CGRect(x: 300, y: 10, width: 1610, height: 971), pageCornerRadius: 7)),
            ("wider sidebar, open", window, .shown, 300, .init(preferredWidth: list, progress: 1), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 417, height: 991), page: CGRect(x: 417, y: 10, width: 1493, height: 971), pageCornerRadius: 7)),
            ("sidebar wider than the Library", window, .shown, 500, .init(preferredWidth: list, progress: 1), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 500, height: 991), page: CGRect(x: 500, y: 10, width: 1410, height: 971), pageCornerRadius: 7)),
            ("window narrower than Spaces", CGRect(x: 0, y: 0, width: 450, height: 600), .shown, 247, .init(preferredWidth: spaces, progress: 1), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 417, height: 600), page: CGRect(x: 417, y: 10, width: 23, height: 580), pageCornerRadius: 7)),
            ("window narrower than the Library", CGRect(x: 0, y: 0, width: 400, height: 600), .shown, 247, .init(preferredWidth: list, progress: 1), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 400, height: 600), page: CGRect(x: 400, y: 10, width: 0, height: 580), pageCornerRadius: 7)),
            ("hidden, open", window, .hidden, 247, .init(preferredWidth: list, progress: 1), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 417, height: 991), page: CGRect(x: 427, y: 10, width: 1483, height: 971), pageCornerRadius: 7)),
            ("hidden, half out", window, .hidden, 247, .init(preferredWidth: list, progress: 0.5), false,
             L(sidebar: CGRect(x: -208.5, y: 0, width: 417, height: 991), page: CGRect(x: 218.5, y: 10, width: 1691.5, height: 971), pageCornerRadius: 7)),
            ("hidden, pulled past open", window, .hidden, 247, .init(preferredWidth: list, progress: 1.5), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 625.5, height: 991), page: CGRect(x: 635.5, y: 10, width: 1274.5, height: 971), pageCornerRadius: 7)),
            ("revealed, open", window, .revealed, 247, .init(preferredWidth: list, progress: 1), false,
             L(sidebar: CGRect(x: 0, y: 0, width: 417, height: 991), page: CGRect(x: 427, y: 10, width: 1483, height: 971), pageCornerRadius: 7)),
            ("revealed, half out", window, .revealed, 247, .init(preferredWidth: list, progress: 0.5), false,
             L(sidebar: CGRect(x: 2.5, y: 2.5, width: 332, height: 986), page: CGRect(x: 218.5, y: 10, width: 1691.5, height: 971),
               pageCornerRadius: 7, sidebarCornerRadius: 5)),
            ("page full screen", window, .shown, 247, .init(preferredWidth: list, progress: 1), true, L(sidebar: nil, page: window, pageCornerRadius: 0)),
        ]
        for (name, bounds, sidebar, width, library, fullscreen, expected) in cases {
            let actual = ChromiumWindowRoot.layout(in: bounds, sidebar: sidebar, sidebarWidth: width, library: library, pageFullscreen: fullscreen)
            precondition(actual == expected, "library layout, \(name): \(actual)")
        }
    }

    /// Split view in a Bark window: 2 to 4 panes of the root's own client, each its own rounded rectangle with a 10 pt gap,
    /// together filling the page frame one page fills. A pane that keeps its tab never leaves the window.
    @MainActor static func splitCases(root: ChromiumWindowRoot, sidebar: NSView, window: NSWindow) {
        typealias Pane = ChromiumWindowRoot.Pane
        typealias Split = ChromiumWindowRoot.Split
        let pages = (20...23).map { _ in CountingPage() }
        for (offset, page) in pages.enumerated() { Engine.pages[Int32(20 + offset)] = page }
        func pane(_ tab: Int32) -> Pane { Pane(client: 5, tab: tab) }
        let area = CGRect(x: 247, y: 10, width: 943, height: 780)
        window.makeFirstResponder(nil)
        precondition(root.show(tab: 20, of: 5) && inRoot(pages[0], root) == area && window.firstResponder === pages[0].input, "starts on one page, with the keys")

        precondition(root.showSplit(Split(panes: [pane(20), pane(21)], vertical: false, dividers: [0.5], focused: 20)),
                     "two panes of the root's client are shown")
        precondition(inRoot(pages[0], root) == CGRect(x: 247, y: 10, width: 466, height: 780)
                     && inRoot(pages[1], root) == CGRect(x: 723, y: 10, width: 467, height: 780),
                     "side by side with a 10 pt gap, filling the page frame: \(inRoot(pages[0], root)) \(inRoot(pages[1], root))")
        let containers = [pages[0].superview!, pages[1].superview!]
        precondition(containers[0] !== containers[1] && containers.allSatisfy { $0.layer?.cornerRadius == 7 && $0.layer?.masksToBounds == true },
                     "each pane is its own rounded rectangle")
        precondition(root.split?.focused == 20 && root.shownTab == 20 && window.firstResponder === pages[0].input,
                     "the focused pane has the keys")

        func panesFill(_ count: Int, vertical: Bool, in rect: CGRect) -> Bool {
            let frames = pages.prefix(count).map { inRoot($0, root) }
            let along = { (r: CGRect) -> (CGFloat, CGFloat) in vertical ? (r.minY, r.maxY) : (r.minX, r.maxX) }
            let across = { (r: CGRect) -> (CGFloat, CGFloat) in vertical ? (r.minX, r.maxX) : (r.minY, r.maxY) }
            guard along(frames.first!).0 == along(rect).0, along(frames.last!).1 == along(rect).1,
                  frames.allSatisfy({ across($0) == across(rect) && $0.width > 0 && $0.height > 0 }) else { return false }
            return zip(frames, frames.dropFirst()).allSatisfy { along($1).0 - along($0).1 == 10 }
        }
        for count in 2...4 {
            for vertical in [false, true] {
                let dividers = (1..<count).map { CGFloat($0) / CGFloat(count) }
                precondition(root.showSplit(Split(panes: (0..<count).map { pane(Int32(20 + $0)) }, vertical: vertical, dividers: dividers, focused: 20))
                             && panesFill(count, vertical: vertical, in: area),
                             "\(count) panes, \(vertical ? "stacked" : "side by side"), fill the page frame with 10 pt gaps")
            }
        }

        let moves = pages.map(\.windowMoves)
        precondition(root.showSplit(Split(panes: [pane(20), pane(21), pane(22)], vertical: false, dividers: [0.2, 0.7], focused: 20))
                     && root.showSplit(Split(panes: [pane(22), pane(20), pane(21)], vertical: false, dividers: [0.2, 0.7], focused: 20))
                     && root.showSplit(Split(panes: [pane(22), pane(20), pane(21)], vertical: true, dividers: [0.2, 0.7], focused: 20)),
                     "a divider move, a reorder and Convert")
        precondition(pages.prefix(3).map(\.windowMoves) == Array(moves.prefix(3)) && pages.prefix(3).allSatisfy { $0.isDescendant(of: root) }
                     && pages[3].superview == nil,
                     "a pane that keeps its tab never leaves the window; the dropped fourth one does: \(pages.map(\.windowMoves)) \(moves)")
        precondition(inRoot(pages[2], root).minY == area.minY && inRoot(pages[1], root).maxY == area.maxY, "the reorder took effect, stacked")

        precondition(root.show(tab: 21, of: 5) && root.split?.focused == 21 && root.shownTab == 21 && window.firstResponder === pages[1].input
                     && pages.prefix(3).map(\.windowMoves) == Array(moves.prefix(3)) && pages.prefix(3).allSatisfy { $0.isDescendant(of: root) },
                     "showing a pane's tab focuses that pane and moves no pane")
        let field = NSTextField()
        sidebar.addSubview(field)
        window.makeFirstResponder(field)
        precondition(root.show(tab: 22, of: 5) && root.split?.focused == 22 && window.firstResponder is NSText,
                     "a field outside the page keeps the keys when the focused pane changes")
        field.removeFromSuperview()

        precondition(!root.showSplit(Split(panes: [pane(20), pane(24)], vertical: false, dividers: [0.5], focused: 20))
                     && root.split?.panes.count == 3, "a pane with no page view refuses the split and changes nothing")
        precondition(!root.showSplit(Split(panes: [pane(20), Pane(client: 6, tab: 21)], vertical: false, dividers: [0.5], focused: 20))
                     && root.split?.panes.count == 3, "a pane names its tab's own client")
        mixedClientCases(root: root, pages: pages, window: window)

        precondition(root.showSplit(Split(panes: [pane(20), pane(21)], vertical: false, dividers: [0.5], focused: 20)), "two panes again")
        root.sidebar = .hidden
        precondition(panesFill(2, vertical: false, in: CGRect(x: 10, y: 10, width: 1180, height: 780)), "hidden sidebar: the panes fill the wider frame")
        root.sidebar = .revealed
        precondition(panesFill(2, vertical: false, in: CGRect(x: 10, y: 10, width: 1180, height: 780)), "revealed sidebar: it floats over the leading pane")
        root.sidebar = .shown
        root.library = .init(preferredWidth: 417, progress: 0.5)
        let pushed = ChromiumWindowRoot.layout(in: root.bounds, sidebar: .shown, library: root.library, pageFullscreen: false).page
        precondition(panesFill(2, vertical: false, in: pushed), "the Library pushes all panes as it pushes one page: \(pushed)")
        root.library = .shut
        let bar = NSView()
        precondition(root.setHeader(bar, replacing: nil, height: 40)
                     && panesFill(2, vertical: false, in: CGRect(x: 247, y: 50, width: 943, height: 740))
                     && inRoot(bar, root) == CGRect(x: 247, y: 10, width: 943, height: 40), "one bar above all panes")
        precondition(root.setHeader(nil, replacing: bar, height: 0))

        let dividers = root.splitDividers
        precondition(dividers.count == 1 && inRoot(dividers[0], root) == CGRect(x: 713, y: 10, width: 10, height: 780),
                     "the gap between two panes is the divider: \(dividers.map { inRoot($0, root) })")
        var moved: [(Int, CGFloat, CGFloat)] = [], released = 0
        root.dividerMoved = { moved.append(($0, $1, $2)) }
        root.dividerReleased = { released += 1 }
        dividers[0].onResize?(0.6, 943); dividers[0].onResizeEnded?()
        precondition(moved.count == 1 && moved[0] == (0, 0.6, 943) && released == 1, "a drag reports the divider, its place and the page's length")

        Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 21, view: pages[1])
        precondition(root.showsCrashedPage(tab: 21) && !root.showsCrashedPage(tab: 20), "a crashed pane shows the card in that pane only")
        Engine.send(kind: BARC_WINDOW_HOST_PAGE_RESTORED, tab: 21, view: pages[1])
        precondition(!root.showsCrashedPage(tab: 21))

        Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_PAGE)
        precondition(inRoot(pages[0], root) == root.bounds && pages[1].superview!.isHidden && root.splitDividers.isEmpty,
                     "page full screen from a pane: that page fills the window, the other pane leaves it")
        Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_NONE)
        precondition(panesFill(2, vertical: false, in: area) && !pages[1].superview!.isHidden && root.splitDividers.count == 1,
                     "the split is as it was after full screen")

        let empty = NSView()
        root.makeEmptyPane = { empty }
        precondition(root.showSplit(Split(panes: [pane(20), pane(21), nil], vertical: false, dividers: [1.0 / 3, 2.0 / 3], focused: 20))
                     && empty.isDescendant(of: root) && root.splitDividers.isEmpty && pages[1].isDescendant(of: root),
                     "Add Split View's empty pane, with no divider")
        precondition(root.showSplit(Split(panes: [pane(20), pane(21)], vertical: false, dividers: [0.5], focused: 20)) && !empty.isDescendant(of: root),
                     "the empty pane goes when the bar closes")

        Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 21, view: pages[1])
        precondition(pages[1].superview == nil && pages[0].isDescendant(of: root) && root.split != nil,
                     "a closed pane's page leaves; the others stay until the split changes")
        let kept = pages[0].windowMoves
        precondition(root.show(tab: 20, of: 5) && root.split != nil && root.shownTab == 20, "the focused pane stays focused")
        precondition(root.show(tab: 22, of: 5) && root.split == nil && pages[0].superview == nil && inRoot(pages[2], root) == area,
                     "a tab outside the split hides the split; its page fills the frame")
        precondition(root.showSplit(Split(panes: [pane(22), pane(20)], vertical: false, dividers: [0.5], focused: 22)) && pages[2].isDescendant(of: root),
                     "the split shows again around the page that was shown")
        precondition(root.show(tab: 20, of: 5) && root.split?.focused == 20 && pages[0].windowMoves == kept + 2,
                     "only leaving and returning moved a page in and out of the window")
        for tab: Int32 in 20...23 { Engine.pages[tab] = nil }
    }

    /// Panes of two clients, two profiles in one window: each pane's page is its own client's, and
    /// focusing a pane makes its client the one the window answers for without moving any pane.
    @MainActor fileprivate static func mixedClientCases(root: ChromiumWindowRoot, pages: [CountingPage], window: NSWindow) {
        typealias Pane = ChromiumWindowRoot.Pane
        typealias Split = ChromiumWindowRoot.Split
        let others = (30...31).map { _ in CountingPage() }
        Engine.clients = [5, 6]
        for (offset, page) in others.enumerated() { Engine.pages[Int32(30 + offset)] = page; Engine.tabClients[Int32(30 + offset)] = 6 }
        defer { Engine.clients = [5]; Engine.tabClients = [:]; Engine.pages[30] = nil; Engine.pages[31] = nil }
        let shown = root.split
        precondition(root.showSplit(Split(panes: [Pane(client: 5, tab: 20), Pane(client: 6, tab: 30)], vertical: false, dividers: [0.5], focused: 20))
                     && pages[0].isDescendant(of: root) && others[0].isDescendant(of: root) && root.client == 5,
                     "a split of two clients shows each pane's own page")
        let moves = [pages[0].windowMoves, others[0].windowMoves]
        let containers = [pages[0].superview, others[0].superview]
        for _ in 0..<5 {
            precondition(root.show(tab: 30, of: 6) && root.split?.focused == 30 && root.client == 6 && window.firstResponder === others[0].input,
                         "focusing the other profile's pane makes its client the window's, with the keys")
            precondition(root.show(tab: 20, of: 5) && root.split?.focused == 20 && root.client == 5 && window.firstResponder === pages[0].input,
                         "and back")
        }
        precondition([pages[0].windowMoves, others[0].windowMoves] == moves && [pages[0].superview, others[0].superview] == containers,
                     "focus going between the profiles moves no pane")
        Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 30, view: others[0])
        precondition(root.client == 5 && root.showsCrashedPage(tab: 30) && !root.showsCrashedPage(tab: 20), "the other profile's pane crashed")
        let reloads = Engine.reloadClients.count
        reloadButton(in: others[0].superview!)?.performClick(nil)
        precondition(Engine.reloadClients.count == reloads + 1 && Engine.reloadClients.last == 6 && Engine.reloads.last == 30,
                     "its card's Reload reloads the tab through the pane's own client: \(Engine.reloadClients)")
        Engine.send(kind: BARC_WINDOW_HOST_PAGE_RESTORED, tab: 30, view: others[0])
        let four = [Pane(client: 5, tab: 20), Pane(client: 6, tab: 30), Pane(client: 5, tab: 21), Pane(client: 6, tab: 31)]
        precondition(root.showSplit(Split(panes: four, vertical: true, dividers: [0.25, 0.5, 0.75], focused: 31))
                     && ([pages[0], pages[1]] + others).allSatisfy { $0.isDescendant(of: root) } && root.client == 6
                     && window.firstResponder === others[1].input, "four panes of two clients; the focused pane's client answers")
        precondition(!root.showSplit(Split(panes: [Pane(client: 5, tab: 30), Pane(client: 6, tab: 31)], vertical: false, dividers: [0.5], focused: 31))
                     && root.split?.panes == four, "a pane whose client does not hold its tab refuses the split")
        precondition(root.showSplit(shown!), "the split as it was")
    }

    /// The engine selects the second client, as for an empty space of its profile, and the first
    /// client closes: the window is addressed through the selected client for its lights, a page
    /// show and a crashed page's Reload.
    @MainActor static func firstClientGoneCases(root: ChromiumWindowRoot, window: NSWindow) {
        let pages = (40...41).map { _ in CountingPage() }
        Engine.clients = [5, 6]
        for (offset, page) in pages.enumerated() { Engine.pages[Int32(40 + offset)] = page; Engine.tabClients[Int32(40 + offset)] = 6 }
        Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_NONE, window: 6)
        precondition(root.client == 6 && root.shownTab == 11, "the engine's selection names the client the window answers for; the page stays")
        Engine.clients = [6]
        let chromeCalls = Engine.chromeClients.count
        root.sidebar = .hidden
        root.sidebar = .shown
        precondition(Engine.chromeClients.count == chromeCalls + 1 && Engine.chromeClients.last == 6
                     && Engine.chrome.last == ChromiumWindowRoot.Arc.lights, "the lights are placed through the live client: \(Engine.chromeClients)")
        precondition(root.show(tab: 40, of: 6) && pages[0].isDescendant(of: root), "a page of the live client shows")
        precondition(root.show(tab: 41, of: 6) && pages[1].isDescendant(of: root) && pages[0].superview == nil, "and another")
        Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 41, view: pages[1])
        precondition(root.showsCrashedPage, "its crash shows the card")
        let reloads = Engine.reloadClients.count
        reloadButton(in: root)?.performClick(nil)
        precondition(Engine.reloadClients.count == reloads + 1 && Engine.reloadClients.last == 6 && Engine.reloads.last == 41,
                     "the card's Reload reloads the tab through its own client")
        Engine.send(kind: BARC_WINDOW_HOST_PAGE_RESTORED, tab: 41, view: pages[1])
        Engine.clients = [5]; Engine.tabClients = [:]
        Engine.pages[40] = nil; Engine.pages[41] = nil
    }

    /// A download that starts flies over the page into the sidebar's downloads button, as in the WebKit
    /// window; nothing flies while the sidebar is out of the window.
    @MainActor static func downloadFlightCases(root: ChromiumWindowRoot, sidebar: NSView, page: NSView, window: NSWindow) {
        precondition(root.sidebar == .shown && inRoot(page, root) == CGRect(x: 247, y: 10, width: 943, height: 780), "starts beside a shown sidebar")
        let overlay = NSView(), flight = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        overlay.addSubview(flight)
        root.setOverlay(overlay)
        precondition(overlay.isDescendant(of: root) && inRoot(overlay, root) == root.bounds,
                     "the flight overlay spans the window: \(inRoot(overlay, root))")
        let layer = root.subviews.firstIndex { overlay.isDescendant(of: $0) } ?? -1
        precondition(layer > root.subviews.firstIndex { sidebar.isDescendant(of: $0) }! && layer > root.subviews.firstIndex { page.isDescendant(of: $0) }!,
                     "the flight shows over the sidebar and the page")
        let hit = root.hitTest(root.convert(NSPoint(x: 600, y: 400), to: root.superview))
        precondition(hit.map { $0.isDescendant(of: page) } == true, "a click over a flight reaches the page: \(String(describing: hit))")

        precondition(root.downloadLaunchPoint(pointer: NSPoint(x: 600, y: 400)) == NSPoint(x: 600, y: 400),
                     "a download clicked in the page flies from the pointer")
        precondition(root.downloadLaunchPoint(pointer: NSPoint(x: 100, y: 400)) == NSPoint(x: 718.5, y: 400),
                     "a download started away from the page flies from the page's middle")

        let button = NSView(frame: NSRect(x: 20, y: 740, width: 28, height: 28))
        sidebar.addSubview(button)
        root.downloadsButton = button
        let click = NSPoint(x: 600, y: 400)
        let shown = root.downloadFlight(from: click, startedIn: window)
        precondition(shown?.start == CGPoint(x: 600, y: 400) && shown?.end == CGPoint(x: 34, y: 46),
                     "one flight from the click to the downloads button: \(String(describing: shown))")
        precondition(root.downloadFlight(from: click, startedIn: NSWindow()) == nil, "another window's download flies there, not here")
        precondition(root.downloadFlight(from: nil, startedIn: window) == nil, "a download with no launch point does not fly")
        root.sidebar = .revealed
        let revealed = root.downloadFlight(from: click, startedIn: window)
        precondition(revealed?.end == CGPoint(x: 39, y: 41), "into the floating sidebar's button: \(String(describing: revealed))")
        root.sidebar = .hidden
        precondition(root.downloadFlight(from: click, startedIn: window) == nil, "nothing flies while the sidebar is out of the window")
        root.sidebar = .shown
        Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_PAGE)
        precondition(root.downloadFlight(from: click, startedIn: window) == nil, "nothing flies over a full-screen page, whose sidebar is out of the window")
        Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_NONE)
        precondition(root.downloadFlight(from: click, startedIn: window)?.end == CGPoint(x: 34, y: 46), "the button is back once the page leaves full screen")
        button.removeFromSuperview()
        precondition(root.downloadFlight(from: click, startedIn: window) == nil, "nothing flies without a button on screen")

        let next = NSView()
        root.setOverlay(next)
        precondition(overlay.superview == nil && next.isDescendant(of: root), "a new overlay replaces the last")
    }

    /// The Library in a real root: one pass moves the column and the page, the page stays live beside it,
    /// a click beside it puts it away, and full screen and resizes keep it.
    @MainActor static func libraryCases(root: ChromiumWindowRoot, sidebar: NSView, page: NSView, lights: [NSButton]) {
        typealias Library = ChromiumWindowRoot.Library
        let arc = ChromiumWindowRoot.Arc.self
        let list: CGFloat = 417, spaces: CGFloat = 840
        var dismissed = 0
        root.dismissLibrary = { dismissed += 1 }
        let surface = ScrollOnly()
        root.setLibrarySwipeSurface(surface)
        let order = root.subviews
        precondition(surface.superview === root && surface.frame == root.bounds
                     && order.firstIndex(of: surface)! > order.firstIndex(of: sidebar.superview!)!
                     && order.firstIndex(of: surface)! > order.firstIndex(of: page.superview!.superview!)!,
                     "the Library's swipe surface covers the window above the sidebar and the page")
        func hit(_ point: NSPoint) -> NSView? { root.hitTest(root.superview!.convert(point, from: root)) }
        let beside = NSPoint(x: 700, y: 400)
        precondition(hit(beside)?.isDescendant(of: page) == true, "with the Library shut the page takes clicks")

        root.library = Library(preferredWidth: list, progress: 1)
        precondition(inRoot(sidebar, root) == CGRect(x: 0, y: 0, width: 417, height: 800)
                     && inRoot(page, root) == CGRect(x: 417, y: 10, width: 773, height: 780),
                     "the Library widens the sidebar's column to 417 and the page moves beside it in the same pass: \(inRoot(sidebar, root)) \(inRoot(page, root))")
        precondition(page.isDescendant(of: root) && !page.isHidden && root.shownTab == 11, "the page stays placed and live beside the Library")
        precondition(Engine.chrome.last == arc.libraryLights && lights.allSatisfy { !$0.isHidden && $0.alphaValue == 1 },
                     "the lights sit with the Library at (23, 28)")
        precondition(root.libraryWidth == 417, "the root says how wide its Library is")
        let catcher = hit(beside)
        precondition(catcher != nil && catcher?.isDescendant(of: page) == false && catcher !== root,
                     "beside the open Library a click does not reach the page: \(String(describing: catcher))")
        catcher?.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: root.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        precondition(dismissed == 1, "a click beside the Library puts it away")
        precondition(hit(NSPoint(x: 200, y: 400))?.isDescendant(of: sidebar) == true, "the Library takes its own clicks")

        root.library = Library(preferredWidth: list, progress: 0.25)
        precondition(inRoot(sidebar, root).width == 289.5 && inRoot(page, root).minX == 289.5, "a quarter out, the column and the page a quarter of the way: \(inRoot(sidebar, root)) \(inRoot(page, root))")
        precondition(Engine.chrome.last == arc.lights && lights.allSatisfy { !$0.isHidden && $0.alphaValue == 0.5 },
                     "the lights fade out where they were over the first half")
        root.library = Library(preferredWidth: list, progress: 0.75)
        precondition(Engine.chrome.last == arc.libraryLights && lights.allSatisfy { $0.alphaValue == 0.5 },
                     "and fade back in with the Library over the second")
        let placed = Engine.chrome.count
        root.library = Library(preferredWidth: list, progress: 0.8)
        precondition(Engine.chrome.count == placed, "a pull that keeps the lights where they are does not place them again")

        root.library = Library(preferredWidth: spaces, progress: 1)
        precondition(inRoot(sidebar, root).width == 840 && inRoot(page, root) == CGRect(x: 840, y: 10, width: 350, height: 780), "Spaces asks for 840")
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
        precondition(inRoot(sidebar, root).width == 744 && inRoot(page, root) == CGRect(x: 744, y: 10, width: 46, height: 780)
                     && surface.frame == root.bounds, "a narrower window leaves 56 beside the Library: \(inRoot(sidebar, root))")
        root.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)

        root.library = Library(preferredWidth: list, progress: 1)
        root.sidebar = .hidden
        precondition(inRoot(sidebar, root) == CGRect(x: 0, y: 0, width: 417, height: 800)
                     && inRoot(page, root) == CGRect(x: 427, y: 10, width: 763, height: 780),
                     "with the sidebar hidden the Library comes out at the window's edge and the page keeps its margin")
        precondition(lights.allSatisfy { !$0.isHidden } && Engine.chrome.last == arc.libraryLights,
                     "the lights come with the Library while the sidebar is hidden")
        root.library = Library(preferredWidth: list, progress: 0.25)
        precondition(lights.allSatisfy(\.isHidden) && inRoot(sidebar, root).maxX == 104.25, "a quarter out: no lights, a quarter of the Library in")
        root.library = Library(preferredWidth: list, progress: 0)
        precondition(inRoot(sidebar, root).maxX <= 0 && lights.allSatisfy(\.isHidden) && hit(beside)?.isDescendant(of: page) == true,
                     "shut again, the hidden sidebar's column leaves the window and the page takes clicks")
        root.sidebar = .shown

        root.library = Library(preferredWidth: list, progress: 1)
        Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_PAGE)
        precondition(inRoot(page, root) == root.bounds && inRoot(sidebar, root).maxX <= 0 && hit(beside)?.isDescendant(of: page) == true
                     && lights.allSatisfy(\.isHidden), "a full-screen page covers the Library and takes its clicks")
        Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 0, fullscreen: BARC_FULLSCREEN_NONE)
        precondition(inRoot(sidebar, root).width == 417 && inRoot(page, root).minX == 417 && Engine.chrome.last == arc.libraryLights,
                     "leaving full screen brings the Library back")

        root.library = Library(preferredWidth: list, progress: 0)
        precondition(inRoot(sidebar, root) == CGRect(x: 0, y: 0, width: 247, height: 800) && hit(beside)?.isDescendant(of: page) == true
                     && Engine.chrome.last == arc.lights && lights.allSatisfy { !$0.isHidden && $0.alphaValue == 1 },
                     "shut, the sidebar, the page and the lights are back")
        root.sidebarWidth = 300
        precondition(inRoot(sidebar, root).width == 300 && inRoot(page, root).minX == 300, "the column follows the sidebar's width")
        root.library = Library(preferredWidth: list, progress: 1)
        precondition(inRoot(sidebar, root).width == 417 && inRoot(page, root).minX == 417, "and the Library still opens to its own width")
        root.library = Library(preferredWidth: list, progress: 0)
        root.sidebarWidth = arc.sidebarWidth
        precondition(dismissed == 1, "only the click put the Library away")
    }
}

/// A page view that counts how often it entered or left a window.
private final class CountingPage: NSView {
    let input = Focusable()
    private(set) var windowMoves = 0
    override init(frame: NSRect) { super.init(frame: frame); addSubview(input) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowMoves += 1 }
    final class Focusable: NSView { override var acceptsFirstResponder: Bool { true } }
}

/// Stands in for the Library's swipe surface, which takes scroll events only.
private final class ScrollOnly: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
