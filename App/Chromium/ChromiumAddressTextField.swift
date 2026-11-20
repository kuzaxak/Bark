// Licensed under GPL-3.0. See LICENSE.
import AppKit

/// Lets the field editor scroll a complete address within the panel's width.
class ChromiumAddressTextField: NSTextField {
    private final class AddressCell: NSTextFieldCell {
        override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
            let configured = super.setUpFieldEditorAttributes(textObj)
            if let editor = configured as? NSTextView, let container = editor.textContainer {
                editor.isHorizontallyResizable = true
                editor.isVerticallyResizable = false
                container.widthTracksTextView = false
                container.size.width = .greatestFiniteMagnitude
            }
            return configured
        }
    }

    override class var cellClass: AnyClass? {
        get { AddressCell.self }
        set { }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }

    /// Use AppKit's document movement to extend the selection.
    static func moveToDocumentEdge(_ command: Selector, in editor: NSTextView) -> Bool {
        guard !editor.hasMarkedText() else { return false }
        switch command {
        case #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
             #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)):
            editor.moveToBeginningOfDocumentAndModifySelection(nil)
        case #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
             #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)):
            editor.moveToEndOfDocumentAndModifySelection(nil)
        default:
            return false
        }
        return true
    }
}
