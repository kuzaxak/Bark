// Licensed under GPL-3.0. See LICENSE.
import AppKit

/// Native events keep the drag captured when the pointer moves over either web page.
final class SplitDividerView: NSView {
    var vertical = false
    /// Where the divider sits, as a fraction of the page from its leading or top edge.
    var position: CGFloat = 0.5
    /// The new position and the page's length along the split.
    var onResize: ((CGFloat, CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    private var dragStart: CGFloat?
    private var dragStartPosition: CGFloat = 0.5

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight)
    }

    /// The pointer's distance from the page's leading or top edge; the page is not flipped.
    private func along(_ event: NSEvent) -> CGFloat? {
        guard let parent = superview else { return nil }
        let point = parent.convert(event.locationInWindow, from: nil)
        return vertical ? parent.bounds.maxY - point.y : point.x - parent.bounds.minX
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = along(event)
        dragStartPosition = position
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview, let dragStart, let now = along(event) else { return }
        let length = vertical ? parent.bounds.height : parent.bounds.width
        guard length > 0 else { return }
        onResize?(dragStartPosition + (now - dragStart) / length, length)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        mouseDragged(with: event)
        dragStart = nil
        onResizeEnded?()
    }
}
