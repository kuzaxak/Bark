// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped card panel and placement; the window stands in for a Chromium window,
// whose content view holds the sidebar's host on the left and the page beside it.
import AppKit
import NookDesign
import SwiftUI

/// Stands in for the sidebar, which mounts the panel as the shell does: inside its own host, updated
/// when the hovered favorite changes.
@MainActor @Observable final class Hover { var tile: CGRect? }
struct MailLikeCard: View {
    var body: some View {
        Text("Sign in to Gmail in this favorite to see new mail").padding(12).frame(width: 240)
    }
}
struct Sidebar: View {
    let hover: Hover
    var body: some View {
        GeometryReader { _ in
            ChromiumFavoriteCardPanel(tile: hover.tile, card: hover.tile == nil ? nil : AnyView(MailLikeCard()),
                place: { tile, card, size in FavoritePreviewPlacement.besideTile(tile, cardHeight: card.height, in: size) })
        }
    }
}

@MainActor func mountedFromTheSidebar() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    window.contentView = root
    let hover = Hover()
    let sidebar = NSHostingView(rootView: Sidebar(hover: hover))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 800)
    root.addSubview(sidebar)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let tile = CGRect(x: 6, y: 92, width: 228, height: 48)
    hover.tile = tile
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    guard let host = root.subviews.last, host !== sidebar else { preconditionFailure("the sidebar's card shows in the window") }
    let card = NSHostingView(rootView: MailLikeCard()).fittingSize
    let top = root.bounds.height - host.frame.maxY
    precondition(host.frame.size == card, "a card mounted from the sidebar's update has the card's size: \(host.frame) against \(card)")
    precondition(host.frame.minX >= tile.maxX && top == tile.maxY - NookDesign.Spacing.md,
                 "it hangs from the tile's corner, not centred on it: \(host.frame)")
    precondition(host.alphaValue == 1)
    hover.tile = nil
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    precondition(host.superview == nil, "and goes with the hover")
}

@main @MainActor enum Check {
    static func main() {
        _ = NSApplication.shared
        mountedFromTheSidebar()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = root
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        let page = NSView(frame: NSRect(x: 240, y: 0, width: 960, height: 800))
        root.addSubview(sidebar); root.addSubview(page)
        let anchor = ChromiumFavoriteCardPanel.Anchor(frame: sidebar.bounds)
        sidebar.addSubview(anchor)

        let tile = CGRect(x: 8, y: 100, width: 70, height: 50)
        anchor.tile = tile
        anchor.place = { tile, card, size in FavoritePreviewPlacement.besideTile(tile, cardHeight: card.height, in: size) }
        anchor.show(AnyView(Color.red.frame(width: 240, height: 120)))
        precondition(anchor.host?.alphaValue == 0, "a card stays out of sight until it has its size, rather than drawn centred on the tile's corner")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let host = anchor.host, host.superview === root else { preconditionFailure("the hovered favorite's card shows in the window, above the page") }
        let expected = CGPoint(x: tile.maxX + NookDesign.Spacing.xs, y: tile.maxY - NookDesign.Spacing.md)
        let top = root.bounds.height - host.frame.maxY
        precondition(host.frame.size == CGSize(width: 240, height: 120), "the card's host is the card's size: \(host.frame)")
        precondition(host.frame.minX == expected.x && top == expected.y, "it hangs from the tile's lower right corner, as in Arc: \(host.frame) against \(expected)")
        precondition(root.subviews.last === host, "it is above the page")
        precondition(root.hitTest(NSPoint(x: 900, y: 100)) === page, "the page keeps the pointer beside the card")
        precondition(root.hitTest(NSPoint(x: 20, y: 300)) === sidebar, "the sidebar keeps the pointer below the card")

        sidebar.frame.origin.x = 30
        anchor.position()
        precondition(host.frame.minX == expected.x + 30, "the tile is measured where the sidebar is")

        anchor.show(nil)
        precondition(host.superview == nil && anchor.host == nil, "no hovered favorite, no card")
        print("Favorite card: a host of the card's size beside the tile, above the page, gone with the hover")
    }
}
