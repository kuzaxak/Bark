import AppKit
import SwiftUI

enum ChromiumPanelFill { case fitted, window, page }

struct ChromiumWindowPanelInput {
    let containsCardPoint: @MainActor (NSPoint, NSWindow) -> Bool
    let containsControlPoint: @MainActor (NSPoint, NSWindow) -> Bool
    let onOutsideClick: @MainActor () -> Void
}

/// A window root that lays out the page itself (`ChromiumWindowRoot`, host mode). Panels declared in
/// its sidebar go where it says, whether the sidebar is shown, hidden or floating.
@MainActor
protocol ChromiumPanelHost: NSView {
    /// The view a panel of `fill` goes into: the page frame, or the whole window for `.window`.
    func panelContainer(for fill: ChromiumPanelFill) -> NSView
}

/// A bounded sibling above Chromium's surface, like the existing address editor.
/// Only the panel receives input; no full-window overlay or second window.
struct ChromiumPagePanel<Content: View>: NSViewRepresentable {
    typealias Fill = ChromiumPanelFill

    let content: Content
    var fill = Fill.fitted
    var windowInput: ChromiumWindowPanelInput?

    /// A window-sized popover owns its clicks at the AppKit boundary. Within
    /// the card SwiftUI handles its controls and passive space stays inert.
    private final class PanelHostingView: NSHostingView<AnyView> {
        private enum OwnedPress { case card, outside }

        var windowInput: ChromiumWindowPanelInput?
        private var ownedPress: OwnedPress?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let windowInput else { return super.hitTest(point) }
            guard let window, let superview, !isHiddenOrHasHiddenAncestor else { return nil }
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            let windowPoint = convert(localPoint, to: nil)
            guard ownedPress == nil,
                  windowInput.containsCardPoint(windowPoint, window),
                  windowInput.containsControlPoint(windowPoint, window) else { return self }
            return super.hitTest(point) ?? self
        }

        override func mouseDown(with event: NSEvent) {
            ownedPress = nil
            if let windowInput, let window = event.window {
                let point = event.locationInWindow
                if !windowInput.containsCardPoint(point, window) {
                    ownedPress = .outside
                    return
                }
                if !windowInput.containsControlPoint(point, window) {
                    ownedPress = .card
                    return
                }
            }
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            if ownedPress == nil { super.mouseDragged(with: event) }
        }

        override func mouseUp(with event: NSEvent) {
            guard let ownedPress else { super.mouseUp(with: event); return }
            self.ownedPress = nil
            if ownedPress == .outside, let windowInput, let window = event.window,
               !windowInput.containsCardPoint(event.locationInWindow, window) {
                windowInput.onOutsideClick()
            }
        }
    }

    final class Anchor: NSView {
        var content: Content?
        var fill = Fill.fitted
        var windowInput: ChromiumWindowPanelInput?
        private var host: PanelHostingView?
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
            if let panelHost {
                place(in: panelHost)
                return
            }
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
            let panel: PanelHostingView
            if let host {
                panel = host
                if heightLimit != height { panel.rootView = view }
            }
            else {
                panel = PanelHostingView(rootView: view)
                panel.safeAreaRegions = []
                host = panel
                root.addSubview(panel, positioned: .above, relativeTo: nil)
            }
            heightLimit = height
            switch fill {
            case .window:
                panel.frame = root.bounds
                panel.windowInput = windowInput
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

        private var panelHost: (any ChromiumPanelHost)? {
            var ancestor = superview
            while let view = ancestor {
                if let host = view as? any ChromiumPanelHost { return host }
                ancestor = view.superview
            }
            return nil
        }

        /// In the container the host gives this panel's fill, at that container's size.
        private func place(in panelHost: any ChromiumPanelHost) {
            guard !updating, !isHiddenOrHasHiddenAncestor, let window, window !== closedWindow, let content else { return }
            updating = true
            defer { updating = false }
            let container = panelHost.panelContainer(for: fill)
            let area = container.bounds
            let height = max(0, area.height - 24)
            let view = fill == .fitted ? AnyView(content.frame(maxHeight: height, alignment: .top)) : AnyView(content)
            if host?.superview !== container { removePanel() }
            let panel: PanelHostingView
            if let host {
                panel = host
                if heightLimit != height { panel.rootView = view }
            } else {
                panel = PanelHostingView(rootView: view)
                panel.safeAreaRegions = []
                host = panel
                container.addSubview(panel, positioned: .above, relativeTo: nil)
            }
            heightLimit = height
            guard fill == .fitted else {
                panel.frame = area
                panel.autoresizingMask = [.width, .height]
                if fill == .window { panel.windowInput = windowInput }
                return
            }
            let size = panel.fittingSize
            let width = min(size.width, max(0, area.width - 24))
            let panelHeight = min(size.height, height)
            panel.frame = NSRect(x: area.maxX - width - 12, y: container.isFlipped ? area.minY + 12 : area.maxY - 12 - panelHeight,
                                 width: width, height: panelHeight)
            panel.autoresizingMask = [.minXMargin, container.isFlipped ? .maxYMargin : .minYMargin]
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
        let anchor = Anchor()
        anchor.content = content
        anchor.fill = fill
        anchor.windowInput = windowInput
        return anchor
    }
    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.windowInput = windowInput
        anchor.setContent(content)
    }
    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.stop() }
}
