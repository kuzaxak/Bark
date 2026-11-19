// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped event monitor. These objects record effects at the shell/model boundary.
import AppKit

@objc(RenderWidgetHostViewCocoa) final class FakePage: NSView {}
@objc(WebContentsViewCocoa) final class FakeContents: NSView {}

enum PageCommand { case goBack, goForward }

@MainActor final class TestPalette {
    private(set) var openCount = 0
    func open() { openCount += 1 }
}

@MainActor final class BrowserWindowState {
    let id = UUID()
    var window: NSWindow?
    var commandPalette: TestPalette? = TestPalette()
    var hoveredFavoriteID: UUID?
    var hoveredItemID: UUID?
    var isSidebarHovered = false
    var nativeSpaceSwitchIsPending = false
    var nativeSpaceSwitchIsUnresolved = false
}

@MainActor final class WindowRegistry {
    var windows: [UUID: BrowserWindowState] = [:]
}

@MainActor final class TestTabs {
    struct Item { let url: URL? }
    var items: [UUID: Item] = [:]
    var resets: [UUID] = []
    var closes: [UUID] = []
    var steps: [(Int, UUID)] = []
    var canStep = false

    func item(_ id: UUID) -> Item? { items[id] }
    func resetToHome(_ id: UUID) { resets.append(id) }
    func close(_ id: UUID) { closes.append(id) }
    func selectPreviousSpace(in window: BrowserWindowState) -> Bool {
        steps.append((-1, window.id))
        return canStep
    }
    func selectNextSpace(in window: BrowserWindowState) -> Bool {
        steps.append((1, window.id))
        return canStep
    }
}

@MainActor final class BrowserManager {
    let tabs = TestTabs()
    var activeWindow: BrowserWindowState?
    var requestedPages: [UUID] = []
    var requestedHistory: [(PageCommand, UUID, UUID)] = []

    func frontPage(in window: BrowserWindowState) -> UUID? {
        requestedPages.append(window.id)
        return window.id
    }

    func performNativePageCommand(_ command: PageCommand, in window: BrowserWindowState, page: UUID) -> Bool {
        requestedHistory.append((command, window.id, page))
        return activeWindow === window && page == window.id
    }
}

@main @MainActor enum Check {
    static func main() {
        let pinned = UUID(), row = UUID()
        typealias A = ChromiumMouseButton
        func act(_ button: Int, page: Bool = false, pinned: UUID? = nil, row: UUID? = nil, sidebar: Bool = false) -> A? {
            A.action(button: button, overPage: page, hoveredPinned: pinned, hoveredRow: row, overSidebar: sidebar)
        }
        precondition(act(2, pinned: pinned, row: row, sidebar: true) == .resetToHome(pinned), "middle-click on a favorite or pinned tab resets it")
        precondition(act(2, row: row, sidebar: true) == .close(row), "middle-click on a tab row closes it")
        precondition(act(2, pinned: pinned, row: row) == .openCommandBar, "an exit still in flight cannot act on a sidebar item from the toolbar")
        precondition(act(2, sidebar: true) == .openCommandBar, "middle-click elsewhere on the app's own views opens the command bar")
        precondition(act(3, sidebar: true) == .previousSpace && act(4, sidebar: true) == .nextSpace, "side buttons over the sidebar switch spaces")
        precondition(act(3) == .goBack && act(4) == .goForward, "side buttons over the app's other views go back and forward")
        for button in 2...4 {
            precondition(act(button, page: true, pinned: pinned, row: row, sidebar: true) == nil, "over the page Chromium keeps button \(button)")
        }
        precondition(act(5, sidebar: true) == nil && act(0) == nil, "other buttons are not the app's")

        let root = NSView(), contents = FakeContents(), page = FakePage(), inner = NSView(), sidebar = NSView()
        root.addSubview(contents); contents.addSubview(page); page.addSubview(inner); root.addSubview(sidebar)
        precondition(ChromiumMouseButton.isPage(inner) && ChromiumMouseButton.isPage(page) && ChromiumMouseButton.isPage(contents), "Chromium's page views are the page")
        precondition(ChromiumMouseButton.isPage(FakePage()), "a render view outside web contents, as a popup's, is the page too")
        precondition(!ChromiumMouseButton.isPage(sidebar) && !ChromiumMouseButton.isPage(root) && !ChromiumMouseButton.isPage(nil), "the rest of the window is the app's")
        let foreground = BrowserWindowState(), background = BrowserWindowState(), manager = BrowserManager()
        manager.activeWindow = foreground
        manager.tabs.items[pinned] = .init(url: URL(string: "https://example.test"))
        manager.tabs.items[row] = .init(url: URL(string: "https://example.test/row"))
        foreground.isSidebarHovered = true
        background.isSidebarHovered = true
        foreground.hoveredFavoriteID = pinned
        background.hoveredItemID = row
        func dispatch(_ button: Int, in window: BrowserWindowState, hit: NSView? = nil) -> Bool {
            ChromiumMouseButtons.handle(button: button, hit: hit, in: window, manager: manager)
        }

        precondition(dispatch(2, in: background), "the background window can handle its own sidebar row")
        precondition(manager.tabs.resets.isEmpty && manager.tabs.closes == [row])
        precondition(dispatch(2, in: foreground) && manager.tabs.resets == [pinned])
        precondition(!dispatch(2, in: background, hit: page) && manager.tabs.closes == [row])
        background.hoveredItemID = nil
        precondition(dispatch(2, in: background))
        precondition(background.commandPalette?.openCount == 1 && foreground.commandPalette?.openCount == 0)

        background.isSidebarHovered = false
        foreground.isSidebarHovered = false
        precondition(!dispatch(3, in: background), "a refused background command remains unhandled")
        precondition(manager.requestedPages == [background.id])
        precondition(manager.requestedHistory.count == 1 && manager.requestedHistory[0].1 == background.id)
        precondition(dispatch(4, in: foreground))
        precondition(manager.requestedHistory.last?.0 == .goForward)
        precondition(manager.requestedHistory.last?.1 == foreground.id && manager.requestedHistory.last?.2 == foreground.id)

        foreground.isSidebarHovered = true
        manager.tabs.canStep = true
        precondition(dispatch(3, in: foreground))
        precondition(manager.tabs.steps.last?.0 == -1 && manager.tabs.steps.last?.1 == foreground.id)
        precondition(manager.requestedHistory.count == 2)
        manager.tabs.canStep = false
        foreground.nativeSpaceSwitchIsPending = true
        precondition(dispatch(4, in: foreground), "a pending switch consumes a boundary press without history")
        precondition(manager.tabs.steps.last?.0 == 1 && manager.requestedHistory.count == 2)
        foreground.nativeSpaceSwitchIsPending = false
        foreground.nativeSpaceSwitchIsUnresolved = true
        precondition(dispatch(3, in: foreground) && manager.requestedHistory.count == 2)
        foreground.nativeSpaceSwitchIsUnresolved = false
        precondition(dispatch(3, in: foreground) && manager.requestedHistory.last?.0 == .goBack)
        print("Mouse buttons preserve page input and keep hover, sidebar steps and history in the event window")
    }
}
