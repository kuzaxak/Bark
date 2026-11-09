// Licensed under GPL-3.0. See LICENSE.
import AppKit

@main
@MainActor
enum Check {
    static func stockMenu() -> NSMenu {
        let main = NSMenu()
        func top(_ tag: Int, _ title: String, _ items: [(Int, String)]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            let menu = NSMenu(title: title)
            for (tag, title) in items {
                let entry = NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
                entry.tag = tag
                menu.addItem(entry)
            }
            item.submenu = menu
            main.addItem(item)
        }
        top(57325, "Chromium", [(40015, "Settings…"), (34031, "Quit Chromium")])
        top(57326, "File", [(34014, "New Tab"), (34000, "New Window"), (34028, "Reopen Closed Tab"), (39001, "Open Location…"), (34015, "Close Tab")])
        top(57343, "Edit", [(50100, "Copy")])
        top(57327, "View", [(40009, "Always Show Bookmarks Bar"), (40250, "Always Show Toolbar"), (40259, "Always Show Full URLs"), (40251, "Customize Touch Bar"), (34058, "Vertical Tabs"), (34061, "Collapse Vertical Tabs"), (34030, "Enter Full Screen")])
        top(57324, "History", [(40010, "Show Full History")])
        top(57333, "Bookmarks", [])
        top(57322, "Profiles", [])
        top(57323, "Tab", [(34016, "Next Tab")])
        top(57321, "Window", [(40012, "Downloads")])
        top(57330, "Help", [])
        return main
    }

    static func item(_ menu: NSMenu, _ top: Int, _ tag: Int) -> NSMenuItem {
        menu.item(withTag: top)!.submenu!.item(withTag: tag)!
    }

    static func main() {
        var ran: [ChromiumAppMenu.Command] = []
        let main = stockMenu()
        let installer = ChromiumAppMenu { ran.append($0) }
        installer.install(in: main)

        // Chromium looks these menus up by tag at runtime, so they stay in the menu, hidden.
        for tag in [57333, 57322, 57323] {
            precondition(main.item(withTag: tag)?.isHidden == true, "tag \(tag) must be hidden, not removed")
        }
        for tag in [40009, 40250, 40259, 40251, 34058, 34061] {
            precondition(item(main, 57327, tag).isHidden, "stock toolbar option \(tag) must be hidden")
        }

        let routed: [(Int, Int, ChromiumAppMenu.Command)] = [
            (57325, 40015, .settings), (57325, 34031, .quit), (57326, 34014, .newTab), (57326, 34028, .reopenClosedTab),
            (57326, 39001, .focusAddress), (57326, 34015, .closeTab), (57324, 40010, .history),
            (57321, 40012, .downloads),
        ]
        for (top, tag, command) in routed {
            let entry = item(main, top, tag)
            ran = []
            precondition(entry.target != nil && entry.action != #selector(NSApplication.terminate(_:)), "\(command) was not routed")
            _ = entry.target?.perform(entry.action, with: entry)
            precondition(ran == [command], "\(command) ran \(ran)")
        }

        precondition(item(main, 57326, 34000).action == #selector(NSApplication.terminate(_:)), "New Window stays Chromium's")
        precondition(item(main, 57343, 50100).action == #selector(NSApplication.terminate(_:)), "Edit stays Chromium's")

        func added(_ title: String, in menu: NSMenu?) -> ChromiumAppMenu.Command? {
            guard let entry = menu?.items.first(where: { $0.title == title }) else { return nil }
            ran = []
            _ = entry.target?.perform(entry.action, with: entry)
            return ran.first
        }
        let view = main.item(withTag: 57327)!.submenu
        precondition(added("Toggle Sidebar", in: view) == .toggleSidebar)
        precondition(added("Toggle AI Assistant", in: view) == .toggleAIAssistant)
        precondition(added("Open Command Bar", in: view) == .commandBar)
        precondition(added("Add Split View", in: view) == .addSplitView)
        let spaces = main.items.first { $0.title == "Spaces" }?.submenu
        precondition(added("Next Space", in: spaces) == .nextSpace)
        precondition(added("Previous Space", in: spaces) == .previousSpace)
        let extensions = main.items.first { $0.title == "Extensions" }?.submenu
        precondition(added("Manage Extensions", in: extensions) == .manageExtensions)
        let order = main.items.map(\.title)
        precondition(order.firstIndex(of: "Spaces")! < order.firstIndex(of: "Window")!, "Spaces belongs before Window")

        let count = main.items.count
        installer.install(in: main)
        precondition(main.items.count == count && view!.items.filter { $0.title == "Toggle Sidebar" }.count == 1, "install must not duplicate items")

        let empty = NSMenu()
        ChromiumAppMenu { _ in }.install(in: empty)
        print("PASS chromium-app-menu")
    }
}
