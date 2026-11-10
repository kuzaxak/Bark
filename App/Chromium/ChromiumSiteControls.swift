import AppKit
import NookDesign
import NookSettings
import NookWeb
import SwiftUI

enum ChromiumPageZoom {
    /// Chromium multiplies a page's devicePixelRatio by its zoom, and the bridge has no zoom reader.
    static func percent(devicePixelRatio: Double, backingScale: Double) -> Int? {
        guard devicePixelRatio > 0, backingScale > 0 else { return nil }
        return Int((devicePixelRatio / backingScale * 100).rounded())
    }
}

/// Where the Site Controls popover sits: centred under its button and inside the window, with
/// its notch on the button.
enum ChromiumSiteControlsPlacement {
    static func popover(button: CGRect, width: CGFloat, in window: CGSize, margin: CGFloat) -> (origin: CGPoint, notchX: CGFloat) {
        let x = min(max(margin, button.midX - width / 2), max(margin, window.width - width - margin))
        return (CGPoint(x: x, y: button.maxY + margin), button.midX - x)
    }
}

/// The address bar's Site Controls button. The popover is a separate host above the page, so it
/// reads where the button is when it shows.
@MainActor final class ChromiumSiteControlsAnchor {
    weak var button: NSView?

    /// In the window's content view, with a top-left origin.
    var buttonFrame: CGRect? {
        guard let button, !button.isHiddenOrHasHiddenAncestor, let root = button.window?.contentView else { return nil }
        var frame = root.convert(button.bounds, from: button)
        if !root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
        return frame.width > 0 && root.bounds.intersects(frame) ? frame : nil
    }
}

extension EnvironmentValues {
    @Entry var chromiumSiteControlsAnchor: ChromiumSiteControlsAnchor? = nil
}

/// Makes the view it backs the button the Site Controls popover hangs from.
struct ChromiumSiteControlsButtonProbe: NSViewRepresentable {
    let anchor: ChromiumSiteControlsAnchor

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        anchor.button = probe
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { anchor.button = probe }
}

/// The address bar's site controls, in the window so page commands still find it key.
struct ChromiumSiteControls: View {
    let browserManager: BrowserManager
    let window: BrowserWindowState
    let settings: NookSettingsService
    let anchor: ChromiumSiteControlsAnchor

    private var opensFromTopBar: Bool {
        browserManager.showsTopBar(in: window) || browserManager.showsDeveloperBar(in: window)
    }

    private var sidebarLeads: Bool { settings.sidebarPosition == .left }
    private let panelGap: CGFloat = 8
    private let notch = CGSize(width: 18, height: 8)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                if let button = anchor.buttonFrame {
                    let place = ChromiumSiteControlsPlacement.popover(button: button, width: ExtensionLibraryView.width,
                                                                      in: proxy.size, margin: panelGap)
                    library
                        .overlay(alignment: .topLeading) {
                            PanelNotch()
                                .fill(NookDesign.Surface.windowBackground)
                                .frame(width: notch.width, height: notch.height)
                                .offset(x: place.notchX - notch.width / 2, y: 1 - notch.height)
                        }
                        .offset(x: place.origin.x, y: place.origin.y)
                } else {
                    library
                        .padding(.top, opensFromTopBar ? TopBarMetrics.height + panelGap : NookDesign.Spacing.sidebarTop)
                        .padding(.horizontal, opensFromTopBar ? panelGap : window.sidebarWidth + panelGap)
                        .frame(maxWidth: .infinity, alignment: opensFromTopBar || !sidebarLeads ? .trailing : .leading)
                }
            }
        }
        .onExitCommand { close() }
    }

    /// Arc's grey panel, on which the action tiles stand out.
    private var library: some View {
        let shape = NookDesign.Radius.shape(NookDesign.Radius.lg)
        return ExtensionLibraryView(browserManager: browserManager, windowState: window, settings: settings,
                                    onDismiss: { close() }, onShowMoreMenu: { openSiteSettings() })
            .clipShape(shape)
            .background(shape.fill(NookDesign.Surface.windowBackground))
            .overlay(shape.strokeBorder(NookDesign.Surface.hairline, lineWidth: NookDesign.Size.hairlineWidth))
            .nookElevation(.floating)
            .fixedSize()
    }

    private func close() {
        withAnimation(.interpolatingSpring(Spring(response: 0.25, dampingRatio: 1))) {
            window.isExtensionLibraryVisible = false
        }
    }

    private func openSiteSettings() {
        close()
        guard let profile = browserManager.frontPage(in: window)?.profile?.id else { return }
        browserManager.tabs.openProfilePage(profileID: profile, destination: .siteSettings) { [browserManager, window] result in
            if case .failure(let error) = result {
                browserManager.showWindowToast(error.localizedDescription, in: window)
            }
        }
    }
}
