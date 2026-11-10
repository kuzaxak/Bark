// Licensed under GPL-3.0. See LICENSE.
import AppKit

@main
private enum DialogFocusChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let page = ChromiumPage(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let field = NSTextField(frame: NSRect(x: 220, y: 10, width: 160, height: 24))
        let button = FocusableView(frame: NSRect(x: 220, y: 50, width: 60, height: 24))
        window.contentView?.addSubview(page)
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(button)
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func editing(_ field: NSTextField) -> Bool { (window.firstResponder as? NSTextView)?.delegate === field }

        let focus = ChromiumDialogFocus()
        precondition(window.makeFirstResponder(page))
        focus.take(in: window)
        precondition(window.firstResponder === window, "The dialog takes Return and Esc from the page")
        // Chromium gives its page the keys again whenever the window becomes key, as after
        // "Leave site?" closes.
        precondition(window.makeFirstResponder(page)); drain()
        precondition(window.firstResponder === window, "The dialog takes the keys back from the page")
        // A field in the dialog keeps the keys and its caret when the window becomes key again,
        // after Cmd+Tab.
        precondition(window.makeFirstResponder(field)); drain()
        let editor = window.firstResponder as! NSTextView
        editor.insertText("abc", replacementRange: editor.selectedRange())
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        precondition(window.makeFirstResponder(page)); drain()
        precondition(editing(field), "The dialog's field keeps its focus")
        precondition((window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 3, length: 0),
                     "Typing continues where it stopped")
        field.stringValue = ""
        // The dialog's own controls take focus as usual.
        precondition(window.makeFirstResponder(button)); drain()
        precondition(window.firstResponder === button)
        precondition(window.makeFirstResponder(nil))
        var fallbacks = 0
        focus.giveBack(orFocusPage: { fallbacks += 1 })
        precondition(window.firstResponder === page, "Typing reaches the page again")
        precondition(fallbacks == 0)
        precondition(window.makeFirstResponder(field)); precondition(window.makeFirstResponder(page)); drain()
        precondition(window.firstResponder === page, "A closed dialog leaves later focus alone")

        // An editing field gets its focus back, not its field editor.
        precondition(window.makeFirstResponder(field))
        precondition((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        focus.take(in: window)
        precondition(window.firstResponder === window)
        focus.giveBack()
        precondition(editing(field), "Typing reaches the address field again")

        // Focus the person moved while the dialog was up stays where they put it.
        precondition(window.makeFirstResponder(page))
        focus.take(in: window)
        precondition(window.makeFirstResponder(field))
        focus.giveBack(orFocusPage: { fallbacks += 1 })
        precondition(editing(field))
        precondition(fallbacks == 0, "Focus the person placed is kept")

        // A field that closed while the dialog showed hands the keys to the page instead.
        precondition(window.makeFirstResponder(page))
        focus.take(in: window)
        page.removeFromSuperview()
        focus.giveBack(orFocusPage: { fallbacks += 1 })
        precondition(window.firstResponder === window && fallbacks == 1, "Typing reaches the page when the field is gone")
        print("Chromium dialog focus checks PASS")
    }
}

private class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Stands in for Chromium's page view, by its Objective-C class name.
@objc(RenderWidgetHostViewCocoa)
private final class ChromiumPage: FocusableView {}
