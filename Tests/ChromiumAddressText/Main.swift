// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped rule verbatim.
import AppKit

@main enum Check {
    @MainActor static func main() {
        checkLongAddressEditing()
        func shown(_ string: String, developer: Bool = false) -> String { URLBarView.shownPath(of: URL(string: string)!, developerPage: developer) }
        precondition(shown("https://github.com/nook/pulls?q=open") == "", "a page shows its host alone, as Arc's address does")
        precondition(shown("https://github.com/") == "")
        precondition(shown("http://localhost:3000/checkout?step=2", developer: true) == "/checkout?step=2", "a developer's own server keeps its path and query")
        precondition(shown("http://localhost:3000/checkout", developer: true) == "/checkout")
        precondition(shown("http://localhost:3000/", developer: true) == "", "nor a bare slash")
        precondition(shown("http://localhost:3000/?step=2", developer: true) == "/?step=2", "the slash stays before a query")
        precondition(shown("about:blank", developer: true) == "", "nothing after a page with no host")
        print("Address: a page shows its host alone; a developer's server keeps its path and query")
    }

    @MainActor static func checkLongAddressEditing() {
        let address = "https://example.invalid/redirect?synthetic=" + String(repeating: "é🙂a", count: 150)
        let length = address.utf16.count
        let caret = 20
        for width: CGFloat in [220, 440] {
            let field = ChromiumAddressTextField(frame: NSRect(x: 0, y: 0, width: width, height: 22))
            let editor = NSTextView(frame: field.bounds)
            editor.isFieldEditor = true
            let nativeEditor = field.cell!.setUpFieldEditorAttributes(editor) as! NSTextView
            nativeEditor.string = address
            precondition(field.usesSingleLineMode && field.cell!.isScrollable)
            precondition(field.intrinsicContentSize.width == NSView.noIntrinsicMetric)
            precondition(nativeEditor.isHorizontallyResizable && !nativeEditor.isVerticallyResizable)
            let layout = nativeEditor.layoutManager!
            layout.ensureLayout(for: nativeEditor.textContainer!)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in
                lines += 1
            }
            precondition(lines == 1, "A long address must scroll on one line")

            nativeEditor.setSelectedRange(NSRange(location: caret, length: 0))
            precondition(ChromiumAddressTextField.moveToDocumentEdge(
                #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)), in: nativeEditor))
            precondition(nativeEditor.selectedRange() == NSRange(location: caret, length: length - caret))

            nativeEditor.setSelectedRange(NSRange(location: caret, length: 0))
            precondition(ChromiumAddressTextField.moveToDocumentEdge(
                #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)), in: nativeEditor))
            precondition(nativeEditor.selectedRange() == NSRange(location: 0, length: caret))
            precondition(!ChromiumAddressTextField.moveToDocumentEdge(#selector(NSResponder.moveLeft(_:)), in: nativeEditor))
            precondition(nativeEditor.string == address)
        }
        print("Long address stays on one editable line and selects to the full URL boundaries")
    }
}
