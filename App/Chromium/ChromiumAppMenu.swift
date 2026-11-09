// Licensed under GPL-3.0. See LICENSE.
import AppKit

/// Chromium builds the application menu for its own tab strip and toolbar, which Nook's windows do
/// not render. This hides what only applies to them, routes tab and address commands to the
/// sidebar, and adds Nook's own commands.
@MainActor
final class ChromiumAppMenu: NSObject {
    enum Command: Equatable {
        case settings, quit, newTab, reopenClosedTab, focusAddress, closeTab, history, downloads
        case toggleSidebar, toggleAIAssistant, commandBar, addSplitView
        case nextSpace, previousSpace, manageExtensions
    }

    // Values from the pinned chrome/app/chrome_command_ids.h.
    private enum Tag {
        static let appMenu = 57325, fileMenu = 57326, viewMenu = 57327, historyMenu = 57324
        static let windowMenu = 57321, bookmarksMenu = 57333, profilesMenu = 57322, tabMenu = 57323
        static let settings = 40015, quit = 34031, newTab = 34014, reopenClosedTab = 34028, focusAddress = 39001
        static let closeTab = 34015, history = 40010, downloads = 40012
        static let bookmarkBar = 40009, fullscreenToolbar = 40250, fullURLs = 40259, touchBar = 40251
        static let verticalTabs = 34058, verticalTabsCollapse = 34061
    }

    private static let addedIdentifier = NSUserInterfaceItemIdentifier("ee.qdo.nook.menu")
    private let perform: (Command) -> Void

    init(perform: @escaping (Command) -> Void) {
        self.perform = perform
    }

    func install(in main: NSMenu) {
        guard let view = main.item(withTag: Tag.viewMenu)?.submenu else { return }
        // Chromium looks these menus up by tag at runtime, so they stay in the menu, hidden.
        for tag in [Tag.bookmarksMenu, Tag.profilesMenu, Tag.tabMenu] {
            main.item(withTag: tag)?.isHidden = true
        }
        for tag in [Tag.bookmarkBar, Tag.fullscreenToolbar, Tag.fullURLs, Tag.touchBar, Tag.verticalTabs, Tag.verticalTabsCollapse] {
            view.item(withTag: tag)?.isHidden = true
        }
        let routed: [(menu: Int, tag: Int, command: Command)] = [
            (Tag.appMenu, Tag.settings, .settings), (Tag.appMenu, Tag.quit, .quit), (Tag.fileMenu, Tag.newTab, .newTab),
            (Tag.fileMenu, Tag.reopenClosedTab, .reopenClosedTab), (Tag.fileMenu, Tag.focusAddress, .focusAddress),
            (Tag.fileMenu, Tag.closeTab, .closeTab), (Tag.historyMenu, Tag.history, .history),
            (Tag.windowMenu, Tag.downloads, .downloads),
        ]
        for route in routed {
            guard let item = main.item(withTag: route.menu)?.submenu?.item(withTag: route.tag) else { continue }
            item.target = self
            item.action = #selector(run(_:))
            item.representedObject = route.command
        }
        guard !view.items.contains(where: { $0.identifier == Self.addedIdentifier }) else { return }
        let viewItems = [("Toggle Sidebar", Command.toggleSidebar), ("Toggle AI Assistant", .toggleAIAssistant),
                         ("Open Command Bar", .commandBar), ("Add Split View", .addSplitView)]
        for (index, entry) in viewItems.enumerated() {
            view.insertItem(make(entry.0, entry.1), at: index)
        }
        view.insertItem(.separator(), at: viewItems.count)
        let before = main.item(withTag: Tag.windowMenu).map { main.index(of: $0) } ?? main.numberOfItems
        main.insertItem(top("Extensions", [("Manage Extensions", .manageExtensions)]), at: before)
        main.insertItem(top("Spaces", [("Next Space", .nextSpace), ("Previous Space", .previousSpace)]), at: before)
    }

    private func make(_ title: String, _ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        item.identifier = Self.addedIdentifier
        return item
    }

    private func top(_ title: String, _ entries: [(String, Command)]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for entry in entries { menu.addItem(make(entry.0, entry.1)) }
        item.submenu = menu
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? Command { perform(command) }
    }
}
