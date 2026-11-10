// Licensed under GPL-3.0. See LICENSE.
import AppKit

/// A dialog drawn over a browser window answers Return and Esc only while nothing in the
/// window holds the keys. It takes them from the page or field that had them, takes them
/// back whenever Chromium hands them to its page while the dialog shows, and gives them
/// back when it closes.
@MainActor
final class ChromiumDialogFocus {
    private weak var window: NSWindow?
    private weak var previous: NSResponder?
    /// What had the keys in the dialog: one of its fields, or nothing.
    private weak var dialogKeys: NSResponder?
    /// The caret of the field that was editing when the window stopped being key.
    private var caret: NSRange?
    private var responderObservation: NSKeyValueObservation?
    private var resignObserver: NSObjectProtocol?

    func take(in window: NSWindow?) {
        guard let window else { return }
        giveBack()
        self.window = window
        let responder = window.firstResponder
        if responder !== window { previous = Self.owner(of: responder) }
        window.makeFirstResponder(nil)
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.responderChanged(in: window) }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: nil) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.caret = (window?.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0.selectedRange() : nil }
            }
        }
    }

    /// `focusPage` runs when what had the keys left the window while the dialog showed,
    /// as the address field's suggestions do when they lose focus.
    func giveBack(orFocusPage focusPage: () -> Void = {}) {
        responderObservation = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        defer { window = nil; previous = nil; dialogKeys = nil; caret = nil }
        guard let window, window.firstResponder === window else { return }
        if let previous, (previous as? NSView)?.window === window {
            window.makeFirstResponder(previous)
        } else {
            focusPage()
        }
    }

    private func responderChanged(in window: NSWindow) {
        guard window === self.window else { return }
        let responder = window.firstResponder
        // A field resigning passes through the window on its way to the next responder.
        guard responder !== window else { return }
        guard Self.isChromiumContent(responder) else {
            // The field editor reports itself before AppKit sets the field as its delegate.
            if let owner = Self.owner(of: responder) { dialogKeys = owner }
            return
        }
        // Chromium sets the keys while it handles the window becoming key; take them back after.
        DispatchQueue.main.async { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, window === self.window, window.firstResponder === responder else { return }
                if let keys = self.dialogKeys, (keys as? NSView)?.window === window {
                    // A field takes the keys with all of its text selected.
                    guard window.makeFirstResponder(keys), let caret = self.caret,
                          let editor = window.firstResponder as? NSTextView,
                          NSMaxRange(caret) <= (editor.string as NSString).length else { return }
                    editor.setSelectedRange(caret)
                } else {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    private static func owner(of responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSResponder }
        return responder
    }

    /// Chromium's page view and its views content view, which Chromium focuses each time the
    /// window becomes key.
    private static func isChromiumContent(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        let name = NSStringFromClass(type(of: responder))
        return name == "RenderWidgetHostViewCocoa" || name == "BridgedContentView"
    }
}
