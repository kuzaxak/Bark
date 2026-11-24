import AppKit

@main
enum Check {
    @MainActor static func main() async {
        commandWindowCases()
        await extensionCommandCases()
        var offeredButIdle: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            let runs = action.pageCommand?.supportsNativePage ?? (action.runsInChromium
                || [.newTab, .focusAddressBar, .openCommandPalette].contains(action))
            if !runs { offeredButIdle.append(action) }
        }
        precondition(offeredButIdle.isEmpty, "offered on Chromium but not run: \(offeredButIdle)")

        for action in [ShortcutAction.newWindow, .closeWindow, .toggleFullScreen, .capturePortrait, .toggleBookmark, .toggleTopBarAddressView, .addSplitView] {
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

        precondition(!ShortcutAction.installExtension.isOffered(privateWindow: false), "Install Extension stays out of the command bar and Settings")
        precondition(!ShortcutAction.manageExtensions.isOffered(privateWindow: true),
                     "Manage Extensions stays out of a private window, where it cannot open")
        precondition(ShortcutAction.manageExtensions.isOffered(privateWindow: false), "Manage Extensions is offered in a regular window")
        precondition(ShortcutAction.allCases.filter { $0 != .installExtension }.allSatisfy { $0.isOffered(privateWindow: false) },
                     "Every other action is offered")
        precondition(ShortcutAction.allCases.filter { $0 != .installExtension && $0 != .manageExtensions }.allSatisfy { $0.isOffered(privateWindow: true) },
                     "Every other action is offered in a private window")
        precondition(!ShortcutAction.undoCloseTab.showsKey(commandZ), "Undo Close Tab shows no Command-Z on Chromium")
        precondition(ShortcutAction.undoCloseTab.showsKey(KeyCombination(key: "t", modifiers: [.command, .shift])),
                     "A key the person bound to Undo Close Tab shows")
        precondition(ShortcutAction.zoomIn.showsKey(KeyCombination(key: "=", modifiers: [.command])), "Other actions show their keys")

        let zoomShortcuts: [ShortcutAction] = [.zoomIn, .zoomOut, .actualSize]
        precondition(zoomShortcuts.allSatisfy { $0.pageCommand?.isZoomCommand == true },
                     "All three zoom shortcuts receive page zoom feedback")
        precondition(PageCommand.allCases.filter(\.isZoomCommand).count == zoomShortcuts.count,
                     "Other page commands leave the zoom indicator alone")

        let defaults = KeyboardShortcut.defaultShortcuts
        let bound = defaults.filter { !$0.keyCombination.key.isEmpty }
        let shared = Dictionary(grouping: bound, by: \.keyCombination.lookupKey).filter { $0.value.count > 1 }.mapValues { $0.map(\.action) }
        precondition(shared.isEmpty, "Defaults sharing a key, where the later one silently wins: \(shared)")
        let commandShift = { (key: String) in bound.first { $0.keyCombination == KeyCombination(key: key, modifiers: [.command, .shift]) }?.action }
        precondition(commandShift("p") == .togglePictureInPicture, "Command-Shift-P toggles picture in picture, as on develop")
        precondition(commandShift("d") == .toggleTopBarAddressView, "Command-Shift-D toggles the toolbar")
        precondition(ShortcutAction.toggleTopBarAddressView.rawValue == "toggle_top_bar_address_view", "The stored toolbar binding keeps its identifier")
        precondition(commandShift("e") == .manageExtensions,
                     "Command-Shift-E opens the Extensions page, where Chromium installs extensions, for develop's Install Extension")
        let library = commandShift("l")
        precondition(library?.rawValue == "open_library" && library?.runsInChromiumSidebar == true,
                     "Command-Shift-L opens the Library, as Arc's Open Library, and the app takes the key before the page: \(String(describing: library))")
        for action in [ShortcutAction.openCommandPalette, .expandAllFolders, .installExtension] {
            precondition(defaults.contains { $0.action == action && $0.keyCombination.key.isEmpty }, "\(action) is listed unbound, so Settings offers it")
        }
        migrationCases(defaults: defaults)
        zoomInKeyCases(defaults: defaults)
        zoomInMigrationCases(defaults: defaults)
        print("PASS")
    }

    @MainActor static func extensionCommandCases() async {
        let browser = ExtensionBrowserFixture()
        let shortcuts = ExtensionShortcutFixture(browserManager: browser)
        let window = ExtensionWindowFixture()
        let successor = ExtensionWindowFixture()
        let profile = window.profileID
        browser.windowRegistry?.windows = [window.id: window, successor.id: successor]

        func select(_ target: ExtensionWindowFixture) {
            browser.windowRegistry?.activeWindow = target
            browser.keyWindow = target.window
        }
        func drain() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        select(window)
        shortcuts.executeAction(.manageExtensions)
        await drain()
        precondition(browser.tabs.opened == [profile])

        shortcuts.executeAction(.manageExtensions)
        select(successor)
        await drain()
        precondition(browser.tabs.opened == [profile], "The next window does not receive the previous shortcut")

        for state in ["space", "pane", "profile", "preparing", "unresolved"] {
            select(window)
            shortcuts.executeAction(.manageExtensions)
            switch state {
            case "space": window.spaceID = UUID()
            case "pane": window.selectedItemID = UUID()
            case "profile": window.profileID = UUID()
            case "preparing": window.nativePresentationIsPreparing = true
            default: window.nativeSpaceSwitchIsUnresolved = true
            }
            await drain()
            precondition(browser.tabs.opened == [profile], "Superseded context: \(state)")
            window.nativePresentationIsPreparing = false
            window.nativeSpaceSwitchIsUnresolved = false
        }
        browser.manageExtensions()
        precondition(browser.tabs.opened == [profile, window.profileID], "Direct menu path still runs")
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

        let movePeekToSplit = KeyCombination(key: "j", modifiers: [.command, .control])
        merged = KeyboardShortcut.addingMissingDefaults(to: saved(rebind(.addSplitView, to: movePeekToSplit)))
        precondition(merged.values.filter { $0.action == .addSplitView }.map(\.keyCombination) == [movePeekToSplit],
                     "Opening a Peek in Split View keeps the existing Add Split View shortcut")

        let taken = saved(rebind(.toggleBookmark, to: openLibrary))
        merged = KeyboardShortcut.addingMissingDefaults(to: taken)
        precondition(merged[openLibrary.lookupKey]?.action == .toggleBookmark, "Command-Shift-L stays with the action the person gave it")
        precondition(merged["none:open_library"]?.action == .openLibrary && merged.count == taken.count + 1,
                     "Open Library is listed unbound, so Settings offers it: \(merged.values.filter { $0.action == .openLibrary })")
        precondition(merged.filter { $0.key != "none:open_library" } == taken, "Every saved shortcut stays as the person set it")
    }
}

/// The shortcut a key press runs, as KeyboardShortcutManager looks it up.
private func action(typing typed: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags,
                    in shortcuts: [KeyboardShortcut]) -> ShortcutAction? {
    let byKey = Dictionary(shortcuts.filter { !$0.keyCombination.key.isEmpty }.map { ($0.lookupKey, $0.action) },
                           uniquingKeysWith: { first, _ in first })
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: typed, charactersIgnoringModifiers: typed,
                                       isARepeat: false, keyCode: keyCode) else { return nil }
    return KeyCombination.lookupKeys(for: event).lazy.compactMap { byKey[$0] }.first
}

/// Zoom In is the key right of 0 on a US keyboard (kVK_ANSI_Equal, 24), which types = and with
/// Shift +, and the + key that Nordic, Estonian (27) and German (30) layouts have.
private func zoomInKeyCases(defaults: [KeyboardShortcut]) {
    precondition(action(typing: "=", keyCode: 24, [.command], in: defaults) == .zoomIn, "US Command-= zooms in")
    precondition(action(typing: "+", keyCode: 24, [.command, .shift], in: defaults) == .zoomIn, "US Command-Shift-= types + and zooms in")
    precondition(action(typing: "+", keyCode: 27, [.command], in: defaults) == .zoomIn, "Nordic and Estonian Command-+ zooms in")
    precondition(action(typing: "+", keyCode: 30, [.command], in: defaults) == .zoomIn, "German Command-+ zooms in")
    precondition(action(typing: "-", keyCode: 27, [.command], in: defaults) == .zoomOut, "US Command-- zooms out")
    precondition(action(typing: "+", keyCode: 24, [.control, .shift], in: defaults) == .addSplitView, "Control-Shift-= stays Add Split View")
    precondition(action(typing: "+", keyCode: 24, [.shift], in: defaults) == nil, "Shift alone types +")
    precondition(defaults.first { $0.action == .zoomIn }?.keyCombination.displayString == "⌘=", "Settings shows the key pressed")
}

@MainActor final class ShortcutDefaults {
    var values: [String: Any] = [:]
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// Version 19's migration: Zoom In leaves Command-+, which no US key press is, for Command-=, and
/// every shortcut the person set stays as set.
@MainActor private func zoomInMigrationCases(defaults: [KeyboardShortcut]) {
    let commandPlus = KeyCombination(key: "+", modifiers: [.command])
    let commandEquals = KeyCombination(key: "=", modifiers: [.command])
    func load(_ change: (inout [KeyboardShortcut]) -> Void = { _ in }) -> (ShortcutStoreFixture, ShortcutDefaults) {
        var list = defaults
        list[list.firstIndex { $0.action == .zoomIn }!].keyCombination = commandPlus
        change(&list)
        let store = ShortcutDefaults()
        store.set(try! JSONEncoder().encode(list), forKey: "keyboard.shortcuts")
        store.set(18, forKey: "keyboard.shortcuts.version")
        return (ShortcutStoreFixture(userDefaults: store), store)
    }
    func rebind(_ action: ShortcutAction, to key: KeyCombination) -> (inout [KeyboardShortcut]) -> Void {
        { list in list[list.firstIndex { $0.action == action }!].keyCombination = key }
    }
    func keys(_ shortcuts: [KeyboardShortcut]) -> [ShortcutAction: KeyCombination] {
        Dictionary(shortcuts.map { ($0.action, $0.keyCombination) }, uniquingKeysWith: { first, _ in first })
    }

    let (moved, store) = load()
    precondition(moved.shortcut(for: .zoomIn)?.keyCombination == commandEquals, "a version-18 Zoom In on Command-+ moves to Command-=")
    precondition(action(typing: "=", keyCode: 24, [.command], in: moved.shortcuts) == .zoomIn, "and US Command-= runs it")
    precondition(keys(moved.shortcuts).filter { $0.key != .zoomIn } == keys(defaults).filter { $0.key != .zoomIn },
                 "every other shortcut stays")
    let saved = try! JSONDecoder().decode([KeyboardShortcut].self, from: store.data(forKey: "keyboard.shortcuts")!)
    precondition(keys(saved)[.zoomIn] == commandEquals && store.integer(forKey: "keyboard.shortcuts.version") == 19,
                 "the move is saved once")

    let chosen = KeyCombination(key: "z", modifiers: [.command, .option])
    precondition(load(rebind(.zoomIn, to: chosen)).0.shortcut(for: .zoomIn)?.keyCombination == chosen,
                 "a Zoom In key the person chose stays")
    let (taken, _) = load(rebind(.toggleBookmark, to: commandEquals))
    precondition(taken.shortcut(for: commandEquals)?.action == .toggleBookmark &&
                 taken.shortcut(for: .zoomIn)?.keyCombination == commandPlus,
                 "Command-= stays with the action the person gave it")
    precondition(action(typing: "+", keyCode: 27, [.command], in: taken.shortcuts) == .zoomIn &&
                 action(typing: "+", keyCode: 24, [.command, .shift], in: taken.shortcuts) == .zoomIn,
                 "and Command-+ still zooms in")
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

@MainActor final class ExtensionWindowFixture {
    final class Key {}
    let id = UUID()
    let window = Key()
    var spaceID = UUID()
    var selectedItemID = UUID()
    var profileID = UUID()
    var nativePresentationIsPreparing = false
    var nativeSpaceSwitchIsUnresolved = false
    var copyToastText: String?
    var isShowingCopyURLToast = false
}

@MainActor final class ExtensionBrowserFixture {
    final class Registry {
        var windows: [UUID: ExtensionWindowFixture] = [:]
        var activeWindow: ExtensionWindowFixture?
    }
    final class Tabs {
        var opened: [UUID] = []
        @MainActor func extensionControlsProfileID(in window: ExtensionWindowFixture) -> UUID? {
            window.profileID
        }
        @MainActor func openExtensionControls(in window: ExtensionWindowFixture,
                                              completion: (Result<Void, Error>) -> Void) {
            opened.append(window.profileID)
            completion(.success(()))
        }
    }
    var keyWindow: ExtensionWindowFixture.Key?
    let windowRegistry: Registry? = Registry()
    let tabs = Tabs()
}

@MainActor final class ExtensionShortcutFixture {
    let browserManager: ExtensionBrowserFixture?

    init(browserManager: ExtensionBrowserFixture) {
        self.browserManager = browserManager
    }
}
