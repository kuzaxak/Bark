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
    static let token: UInt64 = 77

    static func send(kind: BarcWindowHostEventKind, tab: Int32, view: NSView? = nil,
                     size: Int = MemoryLayout<BarcWindowHostEvent>.size) {
        var event = BarcWindowHostEvent(size: size, kind: Int32(kind.rawValue), window: 5, tab: tab, fullscreen: 0,
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
    return bridge
}

@main struct Main {
    @MainActor static func main() {
        _ = NSApplication.shared
        for (bounds, expected) in [(CGRect(x: 0, y: 0, width: 1920, height: 991), CGRect(x: 0, y: 0, width: 1920, height: 991)),
                                   (CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 0, y: 0, width: 800, height: 600)),
                                   (CGRect.zero, CGRect.zero)] {
            precondition(ChromiumWindowRoot.pageFrame(in: bounds) == expected, "the page fills the root: \(bounds)")
        }

        Engine.rootAccepted = 0
        let refused = ChromiumWindowRoot(bridge: table(), nativeWindow: 5)
        precondition(!refused.attach() && Engine.observations == 0, "a refused root view starts no observation")
        Engine.rootAccepted = 1

        weak var released: ChromiumWindowRoot?
        autoreleasepool {
            let root = ChromiumWindowRoot(bridge: table(), nativeWindow: 5)
            released = root
            root.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            precondition(root.attach(), "an accepted root view observes the window")
            precondition(Engine.roots.last!.1 == Unmanaged.passUnretained(root).toOpaque(), "the root hands itself over")
            precondition(!root.attach() && Engine.observations == 1, "a root attaches once")

            let first = NSView(), second = NSView()
            Engine.pages = [10: first, 11: second]
            precondition(!root.show(tab: 12) && root.subviews.isEmpty && root.shownTab == 0, "no page view, nothing shown")
            precondition(root.show(tab: 10), "a tab with a page view is shown")
            precondition(root.subviews == [first] && first.frame == root.bounds && root.shownTab == 10, "the page fills the root")
            precondition(root.show(tab: 10) && root.subviews == [first], "showing the same tab again adds nothing")
            precondition(root.show(tab: 11) && root.subviews == [second] && first.superview == nil, "the next page replaces the last")
            precondition(!root.show(tab: 12) && root.subviews == [second] && root.shownTab == 11, "a missing page keeps the shown one")

            root.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            root.layoutSubtreeIfNeeded()
            precondition(second.frame == root.bounds, "the page follows the root's size: \(second.frame)")

            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(root.subviews == [second], "another tab's retirement leaves the shown page")
            Engine.send(kind: BARC_WINDOW_HOST_FULLSCREEN_CHANGED, tab: 11)
            precondition(root.subviews == [second], "a full-screen event removes no page")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 11, view: second, size: 8)
            precondition(root.subviews == [second], "an event smaller than this app's is ignored")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 11, view: second)
            precondition(root.subviews.isEmpty && second.superview == nil && root.shownTab == 0, "the retired page leaves the root")
            precondition(root.show(tab: 10) && root.subviews == [first], "a page can be shown after the last one retired")

            let other = NSView()
            other.addSubview(first)
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 10, view: first)
            precondition(first.superview === other && root.shownTab == 0, "a retired page another root holds stays there")
            precondition(root.show(tab: 11) && root.subviews == [second], "a page is shown after the moved one retired")
            other.addSubview(second)
            precondition(root.show(tab: 11) && root.subviews == [second], "a page another root took is shown again")
            let third = NSView()
            Engine.pages[11] = third
            other.addSubview(second)
            precondition(root.show(tab: 11) && root.subviews == [third] && second.superview === other,
                         "a tab's new page replaces only the page this root holds")
            Engine.send(kind: BARC_WINDOW_HOST_PAGE_VIEW_RETIRED, tab: 11, view: second)
            precondition(root.subviews == [third] && root.shownTab == 11, "a late retirement of a tab's old page leaves its new one")
            precondition(Engine.unobserved.isEmpty, "a live root keeps observing")
        }
        precondition(released == nil, "the root is not retained by its observation")
        precondition(Engine.unobserved == [Engine.token], "a released root stops observing")
        print("Window host root: shows one page at the root's size, drops a retired one, observes until released")
    }
}
