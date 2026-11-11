import AppKit
import SwiftUI

/// A bounded sibling above Chromium's surface, like the existing address editor.
/// Only the panel receives input; no full-window overlay or second window.
struct ChromiumPagePanel<Content: View>: NSViewRepresentable {
    enum Fill { case fitted, window, page }

    let content: Content
    var fill = Fill.fitted

    final class Anchor: NSView {
        var content: Content?
        var fill = Fill.fitted
        private var host: NSHostingView<AnyView>?
        private var resizeObserver: NSObjectProtocol?
        private var closeObserver: NSObjectProtocol?
        private weak var closedWindow: NSWindow?
        private var updating = false
        private var heightLimit: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            if let window {
                resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                    object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updatePanel() }
                    }
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                    object: window, queue: .main) { [weak self] note in
                        MainActor.assumeIsolated {
                            self?.closedWindow = note.object as? NSWindow
                            self?.removePanel()
                        }
                    }
            }
            updatePanel()
        }
        override func viewDidHide() { super.viewDidHide(); removePanel() }
        override func viewDidUnhide() { super.viewDidUnhide(); updatePanel() }
        override func layout() { super.layout(); updatePanel() }

        func updatePanel() {
            guard !updating, !isHiddenOrHasHiddenAncestor, let window, window !== closedWindow,
                  let root = window.contentView,
                  bounds.height > 0, let content else { return }
            updating = true
            defer { updating = false }
            let region = root.convert(bounds, from: self).intersection(root.bounds)
            let height = max(0, region.height - 24)
            guard height > 0 else { removePanel(); return }
            let view = fill == .fitted ? AnyView(content.frame(maxHeight: height, alignment: .top)) : AnyView(content)
            if host?.superview !== root { removePanel() }
            let panel: NSHostingView<AnyView>
            if let host {
                panel = host
                if heightLimit != height { panel.rootView = view }
            }
            else {
                panel = NSHostingView(rootView: view)
                panel.safeAreaRegions = []
                host = panel
                root.addSubview(panel, positioned: .above, relativeTo: nil)
            }
            heightLimit = height
            switch fill {
            case .window:
                panel.frame = root.bounds
                return
            case .page:
                // The anchor spans the sidebar, on whichever side it sits.
                let sidebarLeads = region.minX <= root.bounds.minX
                panel.frame = NSRect(x: sidebarLeads ? region.maxX : root.bounds.minX, y: root.bounds.minY,
                                     width: root.bounds.width - region.width, height: root.bounds.height)
                return
            case .fitted:
                break
            }
            let size = panel.fittingSize
            let width = min(size.width, max(0, root.bounds.width - 24))
            let panelHeight = min(size.height, height)
            let top = root.isFlipped ? region.minY + 12 : region.maxY - 12
            panel.frame = NSRect(x: root.bounds.maxX - width - 12,
                y: root.isFlipped ? top : top - panelHeight, width: width, height: panelHeight)
        }

        func removePanel() {
            host?.removeFromSuperview()
            host = nil
            heightLimit = nil
        }
        func setContent(_ content: Content) {
            self.content = content
            // SwiftUI updates replace content; AppKit layout only positions it.
            heightLimit = nil
            updatePanel()
        }
        func stop() {
            removePanel()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            resizeObserver = nil
            closeObserver = nil
        }
        isolated deinit { stop() }
    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor(); anchor.content = content; anchor.fill = fill; return anchor
    }
    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.setContent(content)
    }
    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.stop() }
}
