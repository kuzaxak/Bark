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
            if let hoveredPinned { return .resetToHome(hoveredPinned) }
            if let hoveredRow { return .close(hoveredRow) }
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
            MainActor.assumeIsolated {
                guard let manager, let registry,
                      let window = registry.windows.values.first(where: { $0.window === event.window }) else { return event }
                let hit = event.window?.contentView?.hitTest(event.locationInWindow)
                let pinned = manager.hoveredPinnedTabId.flatMap { manager.tabs.item($0)?.url == nil ? nil : $0 }
                guard let action = ChromiumMouseButton.action(button: event.buttonNumber, overPage: ChromiumMouseButton.isPage(hit),
                    hoveredPinned: pinned, hoveredRow: window.hoveredItemID, overSidebar: window.isSidebarHovered) else { return event }
                switch action {
                case .resetToHome(let id): manager.tabs.resetToHome(id)
                case .close(let id): manager.tabs.close(id)
                case .openCommandBar: window.commandPalette?.open()
                case .previousSpace: if !manager.tabs.selectPreviousSpace(in: window) { manager.perform(.goBack) }
                case .nextSpace: if !manager.tabs.selectNextSpace(in: window) { manager.perform(.goForward) }
                case .goBack: manager.perform(.goBack)
                case .goForward: manager.perform(.goForward)
                }
                return nil
            }
        }
    }

    isolated deinit { monitor.map(NSEvent.removeMonitor) }
}
