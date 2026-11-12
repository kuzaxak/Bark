import AppKit

@main
enum Check {
    static func main() {
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
        for action in [ShortcutAction.openCommandPalette, .expandAllFolders, .installExtension] {
            precondition(defaults.contains { $0.action == action && $0.keyCombination.key.isEmpty }, "\(action) is listed unbound, so Settings offers it")
        }
        print("PASS")
    }
}
