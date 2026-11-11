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
        print("PASS")
    }
}
