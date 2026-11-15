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
        print("Window host root: Arc's sidebar, page frame and lights; hides, reveals and full screen; one page at a time, crashed and retired pages, observes until released")
    }

    @MainActor static func layoutCases() {
        let window = CGRect(x: 0, y: 0, width: 1920, height: 991)
        typealias L = ChromiumWindowRoot.Layout
        let cases: [(CGRect, ChromiumWindowRoot.Sidebar, Bool, L)] = [
            (window, .shown, false, L(sidebar: CGRect(x: 0, y: 0, width: 247, height: 991),
                                      page: CGRect(x: 247, y: 10, width: 1663, height: 971), pageCornerRadius: 7)),
            (window, .hidden, false, L(sidebar: nil, page: CGRect(x: 10, y: 10, width: 1900, height: 971), pageCornerRadius: 7)),
            (window, .revealed, false, L(sidebar: CGRect(x: 5, y: 5, width: 247, height: 981),
                                         page: CGRect(x: 10, y: 10, width: 1900, height: 971), pageCornerRadius: 7)),
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
    }
}
