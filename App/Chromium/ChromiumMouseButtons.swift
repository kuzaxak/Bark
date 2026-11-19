import AppKit
import NookWeb

/// What an extra mouse button does over a Chromium window's own views, as in WebKit windows.
/// Over the page, Chromium keeps the button: links open on middle-click and history follows the side buttons.
enum ChromiumMouseButton: Equatable {
    case resetToHome(UUID), close(UUID), openCommandBar, previousSpace, nextSpace, goBack, goForward

    static func action(button: Int, overPage: Bool, hoveredPinned: UUID?, hoveredRow: UUID?, overSidebar: Bool) -> ChromiumMouseButton? {
        guard !overPage else { return nil }
        switch button {
        case 2:
            if overSidebar, let hoveredPinned { return .resetToHome(hoveredPinned) }
            if overSidebar, let hoveredRow { return .close(hoveredRow) }
            return .openCommandBar
        case 3: return overSidebar ? .previousSpace : .goBack
        case 4: return overSidebar ? .nextSpace : .goForward
        default: return nil
        }
    }

    /// Chromium's web contents and the render view inside it.
    static func isPage(_ view: NSView?) -> Bool {
        var view = view
        while let current = view {
            if ["RenderWidgetHostViewCocoa", "WebContentsViewCocoa"].contains(NSStringFromClass(type(of: current))) { return true }
            view = current.superview
        }
        return false
    }
}

// MARK: - Monitor

/// Takes the extra buttons over the app's own views in its windows.
@MainActor final class ChromiumMouseButtons {
    private var monitor: Any?

    init(manager: BrowserManager, registry: WindowRegistry) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak manager, weak registry] event in
            let handled = MainActor.assumeIsolated {
                guard let manager, let registry, let eventWindow = event.window,
                      let window = registry.windows.values.first(where: { $0.window === eventWindow }) else { return false }
                let hit = eventWindow.contentView?.hitTest(event.locationInWindow)
                return Self.handle(button: event.buttonNumber, hit: hit, in: window, manager: manager)
            }
            return handled ? nil : event
        }
    }

    @discardableResult
    static func handle(button: Int, hit: NSView?, in window: BrowserWindowState, manager: BrowserManager) -> Bool {
        let pinned = window.hoveredFavoriteID.flatMap { manager.tabs.item($0)?.url == nil ? nil : $0 }
        let row = window.hoveredItemID.flatMap { manager.tabs.item($0) == nil ? nil : $0 }
        guard let action = ChromiumMouseButton.action(button: button, overPage: ChromiumMouseButton.isPage(hit),
            hoveredPinned: pinned, hoveredRow: row, overSidebar: window.isSidebarHovered) else { return false }
        switch action {
        case .resetToHome(let id): manager.tabs.resetToHome(id)
        case .close(let id): manager.tabs.close(id)
        case .openCommandBar:
            guard let palette = window.commandPalette else { return false }
            palette.open()
        case .previousSpace:
            if !manager.tabs.selectPreviousSpace(in: window) { return history(.goBack, in: window, manager: manager) }
        case .nextSpace:
            if !manager.tabs.selectNextSpace(in: window) { return history(.goForward, in: window, manager: manager) }
        case .goBack: return history(.goBack, in: window, manager: manager)
        case .goForward: return history(.goForward, in: window, manager: manager)
        }
        return true
    }

    private static func history(_ command: PageCommand, in window: BrowserWindowState, manager: BrowserManager) -> Bool {
        // Keep unresolved sidebar side presses from navigating the outgoing page.
        if window.nativeSpaceSwitchIsPending || window.nativeSpaceSwitchIsUnresolved { return true }
        guard let page = manager.frontPage(in: window) else { return false }
        return manager.performNativePageCommand(command, in: window, page: page)
    }

    isolated deinit { monitor.map(NSEvent.removeMonitor) }
}
