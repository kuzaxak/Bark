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
    static var reloads: [Int32] = []
    static let token: UInt64 = 77

    static func send(kind: BarcWindowHostEventKind, tab: Int32, view: NSView? = nil, fullscreen: BarcFullscreenKind = BARC_FULLSCREEN_NONE,
                     size: Int = MemoryLayout<BarcWindowHostEvent>.size) {
        var event = BarcWindowHostEvent(size: size, kind: Int32(kind.rawValue), window: 5, tab: tab,
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
            precondition(window == 5, "asks the window it belongs to")
            return Engine.pages[tab].map { Unmanaged.passUnretained($0).toOpaque() }
        }
    }
    bridge.window_set_chrome = { window, chrome in
        MainActor.assumeIsolated {
            precondition(window == 5 && chrome!.pointee.size == MemoryLayout<BarcWindowChrome>.size, "a whole chrome for its window")
            Engine.chrome.append(.init(titlebarHeight: chrome!.pointee.titlebar_height, leadingInset: chrome!.pointee.leading_inset))
            return 1
        }
    }
    bridge.tab_reload = { _, tab in MainActor.assumeIsolated { Engine.reloads.append(tab); return 1 } }
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

@main struct Main {
    @MainActor static func main() {
        _ = NSApplication.shared
        layoutCases()
        libraryLayoutCases()
        lightsCases()

        Engine.rootAccepted = 0
        let refused = ChromiumWindowRoot(bridge: table(), nativeWindow: 5)
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
            let root = ChromiumWindowRoot(bridge: table(), nativeWindow: 5)
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
            precondition(!root.show(tab: 12) && root.shownTab == 0, "no page view, nothing shown")
            precondition(root.show(tab: 10), "a tab with a page view is shown")
            precondition(first.isDescendant(of: root) && inRoot(first, root) == CGRect(x: 247, y: 10, width: 643, height: 680)
                         && root.shownTab == 10, "the page fills the page frame: \(inRoot(first, root))")
            precondition(first.autoresizingMask == [.width, .height] && first.superview!.autoresizingMask == [.width, .height],
                         "the page and its frame follow a live resize without a layout pass")
            precondition(root.show(tab: 10) && first.superview != nil, "showing the same tab again keeps it")
            precondition(root.show(tab: 11) && second.isDescendant(of: root) && first.superview == nil, "the next page replaces the last")
            precondition(!root.show(tab: 12) && second.isDescendant(of: root) && root.shownTab == 11, "a missing page keeps the shown one")

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
            precondition(root.show(tab: 10) && window.firstResponder === first.input, "a newly shown page takes the keys")
            precondition(root.show(tab: 11) && window.firstResponder === second.input, "a tab switch moves the keys to the new page")
            window.makeFirstResponder(field)
            let editing = window.firstResponder
            precondition(editing is NSText, "the sidebar field edits")
            precondition(root.show(tab: 10) && window.firstResponder === editing, "a sidebar field keeps the keys when the page changes")
            precondition(root.show(tab: 11), "back to the second page")
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
            precondition(root.subviews.firstIndex(of: sidebar.superview!)! > root.subviews.firstIndex(of: second.superview!)!,
                         "the revealed sidebar is above the page")
            precondition(!lights.contains(where: \.isHidden) && Engine.chrome.last == ChromiumWindowRoot.Arc.revealedLights,
                         "the lights come back inside the revealed sidebar")
            root.sidebar = .shown
            precondition(inRoot(second, root) == shown && Engine.chrome.last == ChromiumWindowRoot.Arc.lights,
                         "showing the sidebar again restores the page frame and the lights")

            downloadFlightCases(root: root, sidebar: sidebar, page: second, window: window)
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
            precondition(root.panelContainer(for: .window) === root && root.panelContainer(for: .page) === second.superview
                         && root.panelContainer(for: .fitted) === second.superview, "panels go into the page frame, window panels over everything")
            precondition(!root.setHeader(nil, replacing: NSView(), height: 0), "another caller's bar is not removed")
            precondition(root.setHeader(nil, replacing: bar, height: 0) && bar.superview == nil && inRoot(second, root) == shown,
                         "removing the bar gives the page its height back")

            Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 10, view: first)
            precondition(!root.showsCrashedPage, "another tab's crash leaves the shown page")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 11, view: second)
            precondition(root.showsCrashedPage, "the shown page's crash shows the crashed state")
            precondition(root.show(tab: 10) && root.showsCrashedPage, "a crashed tab shows its state when selected")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_RESTORED, tab: 10, view: first)
            precondition(!root.showsCrashedPage, "a reloaded page hides the crashed state")
            precondition(root.show(tab: 11) && root.showsCrashedPage, "the other crashed tab still shows its state")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_RESTORED, tab: 11, view: second)
            precondition(!root.showsCrashedPage, "both pages restored")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_CRASHED, tab: 10, view: first)
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(root.show(tab: 10) && !root.showsCrashedPage, "a tab that left the window forgets its crash here")
            precondition(root.show(tab: 11), "back to the second page")

            root.pageHidden = true
            precondition(second.isHidden, "a window that shows no page of its own hides the page")
            precondition(root.show(tab: 10) && first.isHidden, "a page shown while the window shows none stays hidden")
            root.pageHidden = false
            precondition(!first.isHidden, "the page shows again")
            precondition(root.show(tab: 11), "back to the second page")

            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(second.isDescendant(of: root), "another tab's retirement leaves the shown page")
            Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 11)
            precondition(second.isDescendant(of: root), "a full-screen event removes no page")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 11, view: second, size: 8)
            precondition(second.isDescendant(of: root), "an event smaller than this app's is ignored")
            Engine.pages[11] = nil
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 11, view: second)
            precondition(second.superview == nil && root.shownTab == 0, "a closed tab's page leaves the root")
            precondition(root.show(tab: 10) && first.isDescendant(of: root), "a page can be shown after the last one retired")

            let replacement = PageView()
            Engine.pages[10] = replacement
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(first.superview == nil && replacement.isDescendant(of: root) && root.shownTab == 10,
                         "a tab that replaced its contents shows its new page")
            Engine.pages[10] = first
            precondition(root.show(tab: 10) && first.isDescendant(of: root), "back to the first page")

            let other = NSView()
            other.addSubview(first)
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(first.superview === other && root.shownTab == 0, "a retired page another root holds stays there")
            Engine.pages[11] = second
            precondition(root.show(tab: 11) && second.isDescendant(of: root), "a page is shown after the moved one retired")
            other.addSubview(second)
            precondition(root.show(tab: 11) && second.isDescendant(of: root), "a page another root took is shown again")
            let third = PageView()
            Engine.pages[11] = third
            other.addSubview(second)
            precondition(root.show(tab: 11) && third.isDescendant(of: root) && second.superview === other,
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
                     && order.firstIndex(of: surface)! > order.firstIndex(of: page.superview!)!,
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

/// Stands in for the Library's swipe surface, which takes scroll events only.
private final class ScrollOnly: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
