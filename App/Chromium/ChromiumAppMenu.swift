// Licensed under GPL-3.0. See LICENSE.
import AppKit

/// Routes the Chromium application menu to the controls in Bark's native window.
@MainActor
final class ChromiumAppMenu: NSObject {
    static func buildInformation(in bundle: Bundle) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let chromium = info["BarkChromiumVersion"] as? String ?? "unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var lines = ["Bark \(version) (build \(build))", "Chromium \(chromium)", "Architecture \(architecture)"]
        if let source = info["BarkShellSourceSHA256"] as? String, source.utf8.count == 64,
           source.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            lines.append("Shell source SHA-256\n" + source)
        } else {
            lines.append("Shell source identity unavailable")
        }
        if let name = info["BarkEngineSDKResource"] as? String, name == "BarkEngineSDK.sha256",
           let url = bundle.url(forResource: name, withExtension: nil),
           let data = try? Data(contentsOf: url), data.count == 65, data.last == 10,
           data.dropLast().allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            lines.append("Engine SDK SHA-256\n" + String(decoding: data.dropLast(), as: UTF8.self))
        } else {
            lines.append("Engine SDK identity unavailable")
        }
        return lines.joined(separator: "\n")
    }

    static func aboutOptions(chromiumVersion: String?) -> [NSApplication.AboutPanelOptionKey: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var engine = "Chromium"
        if let chromiumVersion, !chromiumVersion.isEmpty {
            engine += " " + chromiumVersion
        }
        let credits = NSAttributedString(
            string: "\(engine)\nBark is independently maintained and derives from Nook.",
            attributes: [.paragraphStyle: paragraph]
        )
        return [.applicationName: "Bark", .credits: credits]
    }

    enum Command: Equatable {
        case about, settings, importBrowser, quit, newTab, reopenClosedTab, focusAddress, closeTab, history, downloads
        case toggleSidebar, toggleToolbar, toggleAIAssistant, commandBar, addSplitView, resizeSplitPanes
        case nextSpace, previousSpace, manageExtensions, checkForUpdates, barkHelp, buildInformation
    }

    struct BrowserWindow {
        let showsSidebar: Bool
        let canManageExtensions: Bool
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
        static let openFile = 40000, savePage = 35004, clearBrowsingData = 40013
    }

    /// Items with no effect in Bark's windows: toolbar and omnibox options, Cast with no toolbar to
    /// anchor to, and home page.
    private static let hiddenItems = [Tag.bookmarkBar, Tag.fullscreenToolbar, Tag.fullURLs, Tag.touchBar, Tag.verticalTabs,
                                      Tag.verticalTabsCollapse, Tag.searchTheWeb, Tag.lensShortcut,
                                      Tag.aiModeButton, Tag.searchTools, Tag.cast, Tag.home]
    /// Chromium's key for these never reaches it in Bark's windows; the items still work when clicked.
    private static let keylessItems = [Tag.openFile, Tag.clearBrowsingData]
    private var savePage: (item: NSMenuItem, key: Key)?
    private var keptHidden: [NSKeyValueObservation] = []
    private var routedItems: [Command: NSMenuItem] = [:]

    private static let addedIdentifier = NSUserInterfaceItemIdentifier("ee.qdo.nook.menu")
    private let perform: (Command) -> Void
    private let isOffered: (Command) -> Bool
    private let keyBrowserWindow: () -> BrowserWindow?
    private let isToolbarShown: () -> Bool

    init(isOffered: @escaping (Command) -> Bool = { _ in true },
         keyBrowserWindow: @escaping () -> BrowserWindow?, isToolbarShown: @escaping () -> Bool = { false },
         perform: @escaping (Command) -> Void) {
        self.isOffered = isOffered
        self.keyBrowserWindow = keyBrowserWindow
        self.isToolbarShown = isToolbarShown
        self.perform = perform
    }

    private func sidebarTitle(visible: Bool?) -> String { visible == true ? "Hide Sidebar" : "Show Sidebar" }

    private var toolbarTitle: String { isToolbarShown() ? "Hide Toolbar" : "Show Toolbar" }

    func install(in main: NSMenu, showsUpdater: Bool = false) {
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
        if let item = main.item(withTag: Tag.fileMenu)?.submenu?.item(withTag: Tag.savePage),
           savePage?.item !== item {
            savePage = (item, Key(equivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask))
        }
        let routed: [(menu: Int, tag: Int, command: Command)] = [
            (Tag.appMenu, Tag.about, .about), (Tag.appMenu, Tag.settings, .settings),
            (Tag.appMenu, Tag.importSettings, .importBrowser), (Tag.appMenu, Tag.quit, .quit),
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
        routedItems[.importBrowser]?.title = "Import from Another Browser…"
        if showsUpdater, let app = main.item(withTag: Tag.appMenu)?.submenu,
           !app.items.contains(where: { $0.representedObject as? Command == .checkForUpdates }) {
            let index = app.item(withTag: Tag.about).map { app.index(of: $0) + 1 } ?? 0
            app.insertItem(make("Check for Updates…", .checkForUpdates), at: index)
        }
        // Chromium assigns NSApp.helpMenu to an untagged submenu. Its original
        // Help command identifies that submenu in the menu tree being installed.
        if let help = Self.item(withTag: Tag.help, in: main) {
            help.title = "Bark Help"
            help.target = self
            help.action = #selector(run(_:))
            help.representedObject = Command.barkHelp
            if let menu = help.menu, !menu.items.contains(where: { $0.representedObject as? Command == .buildInformation }) {
                menu.insertItem(make("Build Information…", .buildInformation), at: menu.index(of: help) + 1)
            }
        }
        guard !view.items.contains(where: { $0.identifier == Self.addedIdentifier }) else { return }
        let viewItems = [(sidebarTitle(visible: keyBrowserWindow()?.showsSidebar), Command.toggleSidebar), (toolbarTitle, .toggleToolbar),
                         ("Toggle AI Assistant", .toggleAIAssistant),
                         ("Open Command Bar", .commandBar), ("Add Split View", .addSplitView),
                         ("Resize Split Panes", .resizeSplitPanes)]
        for (index, entry) in viewItems.enumerated() {
            let item = make(entry.0, entry.1)
            routedItems[entry.1] = item
            view.insertItem(item, at: index)
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
        // Save Page As and Hide Sidebar both default to Command-S. Keep Save Page
        // available by menu, and give its key back when Bark's binding moves.
        if let savePage, !savePage.key.equivalent.isEmpty {
            let claimed = routedItems.values.contains {
                $0.keyEquivalent == savePage.key.equivalent && $0.keyEquivalentModifierMask == savePage.key.modifiers
            }
            savePage.item.keyEquivalent = claimed ? "" : savePage.key.equivalent
            savePage.item.keyEquivalentModifierMask = claimed ? [] : savePage.key.modifiers
        }
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command, validateMenuItem(sender) else { return }
        perform(command)
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
        switch command {
        case .toggleSidebar:
            let window = keyBrowserWindow()
            item.title = sidebarTitle(visible: window?.showsSidebar)
            guard window != nil else { return false }
        case .manageExtensions:
            guard keyBrowserWindow()?.canManageExtensions == true else { return false }
        case .newTab, .reopenClosedTab, .focusAddress, .history, .downloads, .toggleAIAssistant,
             .commandBar, .addSplitView, .resizeSplitPanes, .nextSpace, .previousSpace:
            guard keyBrowserWindow() != nil else { return false }
        case .toggleToolbar:
            item.title = toolbarTitle
        case .about, .settings, .importBrowser, .quit, .closeTab, .checkForUpdates, .barkHelp, .buildInformation:
            break
        }
        return isOffered(command)
    }
}
