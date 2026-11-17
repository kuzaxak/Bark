import AppKit

@main
enum Check {
    static func main() {
        commandWindowCases()
        var offeredButIdle: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            let runs = action.pageCommand?.supportsNativePage ?? (action.runsInChromium
                || [.newTab, .focusAddressBar, .openCommandPalette].contains(action))
            if !runs { offeredButIdle.append(action) }
        }
        precondition(offeredButIdle.isEmpty, "offered on Chromium but not run: \(offeredButIdle)")

        for action in [ShortcutAction.newWindow, .closeWindow, .toggleFullScreen, .capturePortrait, .toggleBookmark] {
            let key = KeyCombination(key: "j", modifiers: [.command, .control])
            precondition(action.takesKeyInChromium(key), "\(action) must take its rebound key")
        }

        let commandZ = KeyCombination(key: "z", modifiers: [.command])
        precondition(!ShortcutAction.undoCloseTab.takesKeyInChromium(commandZ), "Command-Z stays with the page")
        precondition(ShortcutAction.undoCloseTab.takesKeyInChromium(KeyCombination(key: "z", modifiers: [.command, .shift])),
                     "Undo Close Tab takes a key the person bound to it")
        precondition(ShortcutAction.undoCloseTab.runsInChromium, "Its command bar row runs")
        precondition(!ShortcutAction.undoCloseTab.runsInChromiumSidebar, "runsInChromiumSidebar decides plain key handling")

        precondition(!ShortcutAction.organizeTabs.isAvailable(organizerModel: false, organizerEnabled: true),
                     "Organize Tabs stays out of the command bar and keys without its model")
        precondition(!ShortcutAction.organizeTabs.isAvailable(organizerModel: true, organizerEnabled: false),
                     "Organize Tabs stays out of the command bar and keys while it is off in Settings")
        precondition(ShortcutAction.organizeTabs.isAvailable(organizerModel: true, organizerEnabled: true),
                     "Organize Tabs is offered once its model is there and it is on")
        precondition(ShortcutAction.allCases.filter { $0 != .organizeTabs }.allSatisfy { $0.isAvailable(organizerModel: false, organizerEnabled: false) },
                     "No other action depends on the organizer")

        precondition(!ShortcutAction.installExtension.isOffered(chromium: true, privateWindow: false), "Install Extension stays out of the command bar and Settings")
        precondition(!ShortcutAction.manageExtensions.isOffered(chromium: true, privateWindow: true),
                     "Manage Extensions stays out of a private window, where it cannot open")
        precondition(ShortcutAction.manageExtensions.isOffered(chromium: true, privateWindow: false), "Manage Extensions is offered in a regular window")
        precondition(ShortcutAction.allCases.filter { $0 != .installExtension }.allSatisfy { $0.isOffered(chromium: true, privateWindow: false) },
                     "Every other action is offered")
        precondition(ShortcutAction.allCases.filter { $0 != .installExtension && $0 != .manageExtensions }.allSatisfy { $0.isOffered(chromium: true, privateWindow: true) },
                     "Every other action is offered in a private window")
        precondition(ShortcutAction.allCases.allSatisfy { $0.isOffered(chromium: false, privateWindow: true) }, "WebKit offers every action")
        precondition(!ShortcutAction.undoCloseTab.showsKey(commandZ, chromium: true), "Undo Close Tab shows no Command-Z on Chromium")
        precondition(ShortcutAction.undoCloseTab.showsKey(commandZ, chromium: false), "WebKit shows Command-Z")
        precondition(ShortcutAction.undoCloseTab.showsKey(KeyCombination(key: "t", modifiers: [.command, .shift]), chromium: true),
                     "A key the person bound to Undo Close Tab shows")
        precondition(ShortcutAction.zoomIn.showsKey(KeyCombination(key: "=", modifiers: [.command]), chromium: true), "Other actions show their keys")

        let defaults = KeyboardShortcut.defaultShortcuts
        let bound = defaults.filter { !$0.keyCombination.key.isEmpty }
        let shared = Dictionary(grouping: bound, by: \.keyCombination.lookupKey).filter { $0.value.count > 1 }.mapValues { $0.map(\.action) }
        precondition(shared.isEmpty, "Defaults sharing a key, where the later one silently wins: \(shared)")
        let commandShift = { (key: String) in bound.first { $0.keyCombination == KeyCombination(key: key, modifiers: [.command, .shift]) }?.action }
        precondition(commandShift("p") == .togglePictureInPicture, "Command-Shift-P toggles picture in picture, as on develop")
        precondition(commandShift("e") == .manageExtensions,
                     "Command-Shift-E opens the Extensions page, where Chromium installs extensions, for develop's Install Extension")
        let library = commandShift("l")
        precondition(library?.rawValue == "open_library" && library?.runsInChromiumSidebar == true,
                     "Command-Shift-L opens the Library, as Arc's Open Library, and the app takes the key before the page: \(String(describing: library))")
        for action in [ShortcutAction.openCommandPalette, .expandAllFolders, .installExtension] {
            precondition(defaults.contains { $0.action == action && $0.keyCombination.key.isEmpty }, "\(action) is listed unbound, so Settings offers it")
        }
        migrationCases(defaults: defaults)
        print("PASS")
    }

    /// Version 18's migration: a version-17 list gets Open Library, and every shortcut the person set stays as set.
    static func migrationCases(defaults: [KeyboardShortcut]) {
        let openLibrary = KeyCombination(key: "l", modifiers: [.command, .shift])
        let bookmark = KeyCombination(key: "b", modifiers: [.command, .option])
        func saved(_ change: (inout [KeyboardShortcut]) -> Void) -> [String: KeyboardShortcut] {
            var list = defaults.filter { $0.action != .openLibrary }
            change(&list)
            return Dictionary(uniqueKeysWithValues: list.map { ($0.lookupKey, $0) })
        }
        func rebind(_ action: ShortcutAction, to key: KeyCombination) -> (inout [KeyboardShortcut]) -> Void {
            { list in
                let index = list.firstIndex { $0.action == action }!
                list[index].keyCombination = key
            }
        }

        let customized = saved(rebind(.toggleBookmark, to: bookmark))
        var merged = KeyboardShortcut.addingMissingDefaults(to: customized)
        precondition(merged[openLibrary.lookupKey]?.action == .openLibrary, "A version-17 list gets Open Library on Command-Shift-L")
        precondition(merged.filter { $0.key != openLibrary.lookupKey } == customized,
                     "Every saved shortcut stays as the person set it: \(merged.filter { $0.key != openLibrary.lookupKey && customized[$0.key] != $0.value })")
        precondition(merged.values.filter { $0.action == .toggleBookmark }.map(\.keyCombination) == [bookmark],
                     "A rebound default is not added again on its old key")

        let taken = saved(rebind(.toggleBookmark, to: openLibrary))
        merged = KeyboardShortcut.addingMissingDefaults(to: taken)
        precondition(merged[openLibrary.lookupKey]?.action == .toggleBookmark, "Command-Shift-L stays with the action the person gave it")
        precondition(merged["none:open_library"]?.action == .openLibrary && merged.count == taken.count + 1,
                     "Open Library is listed unbound, so Settings offers it: \(merged.values.filter { $0.action == .openLibrary })")
        precondition(merged.filter { $0.key != "none:open_library" } == taken, "Every saved shortcut stays as the person set it")
    }
}

/// A child window that takes the keys, as a page's bubble, prompt or dialog does, acts for the
/// window it belongs to: Close Tab closes the tab there, never the window.
@MainActor private func commandWindowCases() {
    func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
    let browser = window(), bubble = window(), dialog = window(), other = window()
    browser.addChildWindow(bubble, ordered: .above)
    bubble.addChildWindow(dialog, ordered: .above)
    precondition(CommandWindow.resolve(browser) === browser, "the browser window acts for itself")
    precondition(CommandWindow.resolve(bubble) === browser, "a bubble with the keys acts for its browser window")
    precondition(CommandWindow.resolve(dialog) === browser, "so does a dialog over the bubble")
    precondition(CommandWindow.resolve(other) === other, "a window of its own, as Settings, acts for itself")
    precondition(CommandWindow.resolve(nil) == nil)
    browser.removeChildWindow(bubble)
    bubble.removeChildWindow(dialog)

    let sheetOwner = window(), sheet = window()
    sheetOwner.orderBack(nil)
    sheetOwner.beginSheet(sheet)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    precondition(sheet.isSheet, "the panel is attached as a sheet")
    precondition(CommandWindow.keepsKeys(sheet) && CommandWindow.resolve(sheet) == nil,
                 "a sheet keeps its keys: no command acts on the window behind it (its parent: \(String(describing: sheet.parent)))")
    sheetOwner.endSheet(sheet)
    sheetOwner.orderOut(nil)
}
