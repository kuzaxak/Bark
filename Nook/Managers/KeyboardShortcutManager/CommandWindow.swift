// Licensed under GPL-3.0. See LICENSE.

import AppKit

/// The window a command chosen by key or from the menu acts on.
enum CommandWindow {
    /// `key` itself, or, for a child window that took the keys (a page's bubble, prompt or
    /// dialog), the top window it belongs to. Chromium hands a child's Close to its parent. Nil
    /// for a sheet or a window over one, which keeps its keys.
    static func resolve(_ key: NSWindow?) -> NSWindow? {
        guard !keepsKeys(key) else { return nil }
        var window = key
        while let parent = window?.parent { window = parent }
        return window
    }

    /// Whether `key` is a sheet, or a child of one: an open or save panel, an alert.
    static func keepsKeys(_ key: NSWindow?) -> Bool {
        var window = key
        while let current = window {
            if current.isSheet { return true }
            window = current.parent
        }
        return false
    }

    /// The application's key window, resolved.
    @MainActor static var key: NSWindow? { resolve(NSApp.keyWindow) }

    @MainActor static var keyKeepsKeys: Bool { keepsKeys(NSApp.keyWindow) }
}
