import AppKit
import NookWeb
import SwiftUI

/// The hovered favorite's card in a Chromium window, hung from the tile the sidebar reports.
struct ChromiumFavoriteCard: View {
    let anchor: Anchor<CGRect>?
    let window: BrowserWindowState
    let tabs: TabsController

    private let preview = FavoritePreview.shared

    var body: some View {
        GeometryReader { proxy in
            let itemID = preview.isCurrent(in: window, tabs: tabs) ? preview.itemID : nil
            ChromiumFavoriteCardPanel(tile: itemID == nil ? nil : anchor.map { proxy[$0] },
                card: itemID.map { AnyView(FavoritePreviewCard(itemID: $0).environment(tabs).environment(window)) },
                place: { [live = preview.live != nil] tile, card, size in
                    live ? FavoritePreviewPlacement.besideTile(tile, cardHeight: card.height, in: size)
                         : FavoritePreviewPlacement.underTile(tile, in: size)
                })
        }
        .dismissesFavoritePreview(when: window)
    }
}

struct ChromiumFavoriteCardPanel: NSViewRepresentable {
    /// The tile, in this view's space with a top-left origin; nil takes the card down.
    let tile: CGRect?
    let card: AnyView?
    /// The card's top-left in the window's content view, from the tile there and the card's size.
    let place: (_ tile: CGRect, _ card: CGSize, _ window: CGSize) -> CGPoint

    final class Anchor: NSView {
        var tile: CGRect?
        var place: ((CGRect, CGSize, CGSize) -> CGPoint)?
        private(set) var host: NSHostingView<AnyView>?
        private var cardSize = CGSize.zero

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); position() }
        override func layout() { super.layout(); position() }

        func show(_ card: AnyView?) {
            guard let card else { return removeCard() }
            let sized = AnyView(card.fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                self?.cardSize = size
                self?.position()
            })
            if let host { host.rootView = sized } else {
                let host = NSHostingView(rootView: sized)
                host.safeAreaRegions = []
                self.host = host
            }
            position()
        }

        func position() {
            guard let host, let tile, let place, let root = window?.contentView, !isHiddenOrHasHiddenAncestor else {
                host?.removeFromSuperview()
                return
            }
            if host.superview !== root { root.addSubview(host, positioned: .above, relativeTo: nil) }
            let mine = root.convert(bounds, from: self)
            let top = root.isFlipped ? mine.minY : root.bounds.height - mine.maxY
            let size = cardSize
            let origin = place(tile.offsetBy(dx: mine.minX, dy: top), size, root.bounds.size)
            host.frame = NSRect(x: origin.x, y: root.isFlipped ? origin.y : root.bounds.height - origin.y - size.height,
                                width: size.width, height: size.height)
            host.alphaValue = size == .zero ? 0 : 1
        }

        func removeCard() {
            host?.removeFromSuperview()
            host = nil
            cardSize = .zero
        }

        isolated deinit { host?.removeFromSuperview() }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.tile = tile
        anchor.place = place
        anchor.show(tile == nil ? nil : card)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.removeCard() }
}
