import AppKit
import NookDesign
import SwiftUI

/// The band at the top of the sidebar that its title row shares with the window's traffic lights.
struct SidebarTitleBand: Equatable {
    var height: CGFloat
    var leadingInset: CGFloat
    /// Where the content below the row starts: where Arc's address field does, or below a taller band.
    var contentTop: CGFloat

    init(height: CGFloat, leadingInset: CGFloat) {
        self.height = height
        self.leadingInset = leadingInset
        contentTop = max(height, Self.arcContentTop)
    }

    /// A window with a unified toolbar, which centres its lights in the design's band.
    static let design = SidebarTitleBand(height: NookDesign.Spacing.sidebarTop, leadingInset: NookDesign.SidebarChrome.trafficLightsInset)

    /// How far past the zoom button's frame the sidebar button's frame starts, as the design's inset does.
    static let gapAfterZoom: CGFloat = 4

    /// The top of Arc's address field, measured from its window's top.
    static let arcContentTop: CGFloat = 46

    /// Centred on the lights and starting past the zoom light, in `view`'s space with a top-left
    /// origin; nil when `view` shows no lights of its own window.
    @MainActor static func measure(in view: NSView) -> SidebarTitleBand? {
        guard let window = view.window, let zoom = window.standardWindowButton(.zoomButton),
              zoom.window === window, !zoom.isHiddenOrHasHiddenAncestor else { return nil }
        let frame = view.convert(zoom.bounds, from: zoom)
        let top = view.isFlipped ? frame.minY : view.bounds.height - frame.maxY
        return SidebarTitleBand(height: 2 * (top + frame.height / 2), leadingInset: frame.maxX + gapAfterZoom)
    }
}

extension EnvironmentValues {
    @Entry var sidebarTitleBand: SidebarTitleBand = .design
}

/// Reports the title band for the view it backs when it moves to a window, lays out or updates,
/// and when its window enters or leaves full screen, which moves the lights to another window and back.
struct SidebarTitleBandReader: NSViewRepresentable {
    let onChange: (SidebarTitleBand?) -> Void

    final class Probe: NSView {
        var onChange: ((SidebarTitleBand?) -> Void)?
        private var reported: SidebarTitleBand?
        private var hasReported = false
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observe(window)
            report()
        }
        override func layout() { super.layout(); report() }

        private func observe(_ window: NSWindow?) {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
        }

        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func report() {
            let band = SidebarTitleBand.measure(in: self)
            guard !hasReported || band != reported else { return }
            hasReported = true
            reported = band
            DispatchQueue.main.async { [weak self] in self?.onChange?(band) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
        probe.report()
    }
}
