// Licensed under GPL-3.0. See LICENSE.
import AppKit

/// Chromium builds the application menu for its own tab strip and toolbar, which Nook's windows do
/// not render. This hides what only applies to them or has no effect in them, routes tab and
/// address commands to the sidebar, and adds Nook's own commands.
@MainActor
final class ChromiumAppMenu: NSObject {
    enum Command: Equatable {
        case about, settings, quit, newTab, reopenClosedTab, focusAddress, closeTab, history, downloads
        case toggleSidebar, toggleAIAssistant, commandBar, addSplitView, resizeSplitPanes
        case nextSpace, previousSpace, manageExtensions
    }

    // Values from the pinned chrome/app/chrome_command_ids.h.
    private enum Tag {
        static let appMenu = 57325, fileMenu = 57326, viewMenu = 57327, historyMenu = 57324
        static let windowMenu = 57321, bookmarksMenu = 57333, profilesMenu = 57322, tabMenu = 57323
        static let about = 40018, settings = 40015, quit = 34031, newTab = 34014, reopenClosedTab = 34028, focusAddress = 39001
        static let closeTab = 34015, history = 40010, downloads = 40012
        static let bookmarkBar = 40009, fullscreenToolbar = 40250, fullURLs = 40259, touchBar = 40251
        static let verticalTabs = 34058, verticalTabsCollapse = 34061
        static let importSettings = 40014, searchTheWeb = 39002, lensShortcut = 40282, aiModeButton = 40299
        static let searchTools = 40296, cast = 35011, home = 33003, help = 40020
        static let openFile = 40000, clearBrowsingData = 40013
    }

    /// Items with no effect in Nook's windows: toolbar and omnibox options, Cast with no toolbar to
    /// anchor to, Chromium's bookmarks import, home page and help.
    private static let hiddenItems = [Tag.bookmarkBar, Tag.fullscreenToolbar, Tag.fullURLs, Tag.touchBar, Tag.verticalTabs,
                                      Tag.verticalTabsCollapse, Tag.importSettings, Tag.searchTheWeb, Tag.lensShortcut,
                                      Tag.aiModeButton, Tag.searchTools, Tag.cast, Tag.home, Tag.help]
    /// Chromium's key for these never reaches it in Nook's windows; the items still work when clicked.
    private static let keylessItems = [Tag.openFile, Tag.clearBrowsingData]
    private var keptHidden: [NSKeyValueObservation] = []
    private var routedItems: [Command: NSMenuItem] = [:]

    private static let addedIdentifier = NSUserInterfaceItemIdentifier("ee.qdo.nook.menu")
    private let perform: (Command) -> Void
    private let isOffered: (Command) -> Bool

    init(isOffered: @escaping (Command) -> Bool = { _ in true }, perform: @escaping (Command) -> Void) {
        self.isOffered = isOffered
        self.perform = perform
    }

    func install(in main: NSMenu) {
        guard let view = main.item(withTag: Tag.viewMenu)?.submenu else { return }
        // Chromium looks these menus up by tag at runtime, so they stay in the menu, hidden.
        let menus = [Tag.bookmarksMenu, Tag.profilesMenu, Tag.tabMenu].compactMap { main.item(withTag: $0) }
        var items = Self.hiddenItems.compactMap { Self.item(withTag: $0, in: main) }
        if let warn = main.item(withTag: Tag.appMenu)?.submenu?.items.first(where: { $0.action == NSSelectorFromString("toggleConfirmToQuit:") }) {
            items.append(warn)
        }
        for item in items {
            item.target = self
            item.action = #selector(ignore(_:))
        }
        // Chromium shows some of these again: the Profiles menu when it rebuilds it, the History
        // menu's items when history changes, and View items when it validates them.
        keptHidden = (menus + items).map { item in
            item.isHidden = true
            return item.observe(\.isHidden) { item, _ in
                if !item.isHidden { item.isHidden = true }
            }
        }
        for item in Self.keylessItems.compactMap({ Self.item(withTag: $0, in: main) }) {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
        let routed: [(menu: Int, tag: Int, command: Command)] = [
            (Tag.appMenu, Tag.about, .about), (Tag.appMenu, Tag.settings, .settings), (Tag.appMenu, Tag.quit, .quit),
            (Tag.fileMenu, Tag.newTab, .newTab), (Tag.fileMenu, Tag.reopenClosedTab, .reopenClosedTab),
            (Tag.fileMenu, Tag.focusAddress, .focusAddress), (Tag.fileMenu, Tag.closeTab, .closeTab),
            (Tag.historyMenu, Tag.history, .history), (Tag.windowMenu, Tag.downloads, .downloads),
        ]
        for route in routed {
            guard let item = main.item(withTag: route.menu)?.submenu?.item(withTag: route.tag) else { continue }
            item.target = self
            item.action = #selector(run(_:))
            item.representedObject = route.command
            routedItems[route.command] = item
        }
        guard !view.items.contains(where: { $0.identifier == Self.addedIdentifier }) else { return }
        let viewItems = [("Toggle Sidebar", Command.toggleSidebar), ("Toggle AI Assistant", .toggleAIAssistant),
                         ("Open Command Bar", .commandBar), ("Add Split View", .addSplitView),
                         ("Resize Split Panes", .resizeSplitPanes)]
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

    struct Key: Equatable {
        var equivalent: String
        var modifiers: NSEvent.ModifierFlags
    }

    /// The keys the person bound in Settings > Shortcuts, for the routed commands that have one.
    func showKeys(_ keys: [Command: Key]) {
        for (command, key) in keys {
            guard let item = routedItems[command] else { continue }
            item.keyEquivalent = key.equivalent
            item.keyEquivalentModifierMask = key.modifiers
        }
    }

    @objc private func run(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? Command { perform(command) }
    }

    @objc private func ignore(_ sender: NSMenuItem) {}

    private static func item(withTag tag: Int, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.tag == tag { return item }
            if let submenu = item.submenu, let found = Self.item(withTag: tag, in: submenu) { return found }
        }
        return nil
    }
}

extension ChromiumAppMenu: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? Command else { return true }
        return isOffered(command)
    }
}
