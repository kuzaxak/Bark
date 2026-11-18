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
    private var resizeRange: ClosedRange<CGFloat>?
    var onLeave: (() -> Void)?
    var onTab: ((Bool) -> Void)?
    private var dragStart: CGFloat?
    private var dragStartPosition: CGFloat = 0.5

    override var acceptsFirstResponder: Bool { resizeRange != nil }

    func configureAccessibility(index: Int, count: Int, range: ClosedRange<CGFloat>) {
        let value = Double(position * 100)
        let changed = resizeRange != nil && (accessibilityValue() as? Double) != value
        resizeRange = range
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(vertical ? .horizontal : .vertical)
        setAccessibilityLabel(count == 1 ? "Split Divider" : "Split Divider \(index + 1) of \(count)")
        setAccessibilityHelp(vertical ? "Use Up and Down to resize. Press Escape to return to the page."
                                      : "Use Left and Right to resize. Press Escape to return to the page.")
        setAccessibilityMinValue(Double(range.lowerBound * 100))
        setAccessibilityMaxValue(Double(range.upperBound * 100))
        setAccessibilityValue(value)
        setAccessibilityValueDescription(Double(position).formatted(.percent.precision(.fractionLength(0))))
        if changed { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformIncrement) || selector == #selector(accessibilityPerformDecrement) {
            return resizeRange != nil && onResize != nil
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func accessibilityPerformIncrement() -> Bool { resize(by: 0.05) }
    override func accessibilityPerformDecrement() -> Bool { resize(by: -0.05) }

    private func resize(by change: CGFloat) -> Bool {
        guard let parent = superview, let range = resizeRange, let onResize else { return false }
        let length = vertical ? parent.bounds.height : parent.bounds.width
        guard length > 0 else { return false }
        let next = min(range.upperBound, max(range.lowerBound, position + change))
        guard change > 0 ? next > position : next < position else { return false }
        onResize(next, length)
        onResizeEnded?()
        return true
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setFill()
        bounds.fill()
    }

    override func keyDown(with event: NSEvent) {
        guard resizeRange != nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        if event.charactersIgnoringModifiers == "\u{1b}" {
            onLeave?()
            return
        }
        if event.charactersIgnoringModifiers == "\t" || event.specialKey == .backTab {
            onTab?(event.modifierFlags.contains(.shift))
            return
        }
        switch event.specialKey {
        case .leftArrow where !vertical, .upArrow where vertical:
            _ = accessibilityPerformDecrement()
        case .rightArrow where !vertical, .downArrow where vertical:
            _ = accessibilityPerformIncrement()
        default:
            super.keyDown(with: event)
        }
    }

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
