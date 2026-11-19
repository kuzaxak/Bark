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
        top(57325, "Chromium", [(40018, "About Chromium"), (40015, "Settings…"), (40013, "Delete Browsing Data…"), (40014, "Import Bookmarks and Settings…"), (34031, "Quit Chromium")])
        let warn = NSMenuItem(title: "Warn Before Quitting", action: NSSelectorFromString("toggleConfirmToQuit:"), keyEquivalent: "")
        main.item(withTag: 57325)!.submenu!.insertItem(warn, at: 4)
        top(57326, "File", [(34014, "New Tab"), (34000, "New Window"), (34028, "Reopen Closed Tab"), (40000, "Open File…"), (39001, "Open Location…"), (34015, "Close Tab")])
        main.item(withTag: 57326)!.submenu!.item(withTag: 40000)!.keyEquivalent = "o"
        for (top, tag, key) in [(57325, 40015, ","), (57325, 34031, "q"), (57326, 34014, "t"), (57326, 39001, "l"), (57326, 34015, "w")] {
            main.item(withTag: top)!.submenu!.item(withTag: tag)!.keyEquivalent = key
        }
        main.item(withTag: 57325)!.submenu!.item(withTag: 40013)!.keyEquivalent = "\u{8}"
        top(57343, "Edit", [(50100, "Copy")])
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        find.submenu = NSMenu(title: "Find")
        let searchWeb = NSMenuItem(title: "Search the Web…", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        searchWeb.tag = 39002
        find.submenu!.addItem(searchWeb)
        main.item(withTag: 57343)!.submenu!.addItem(find)
        top(57327, "View", [(40009, "Always Show Bookmarks Bar"), (40250, "Always Show Toolbar"), (40259, "Always Show Full URLs"), (40251, "Customize Touch Bar"), (40282, "Always Show Image Search Shortcut"), (40299, "Always Show AI Mode"), (40296, "Show Search Shortcuts"), (34058, "Vertical Tabs"), (34061, "Collapse Vertical Tabs"), (34030, "Enter Full Screen"), (35011, "Cast…"), (35002, "View Source")])
        top(57324, "History", [(33003, "Home"), (40010, "Show Full History")])
        top(57333, "Bookmarks", [])
        top(57322, "Profiles", [])
        top(57323, "Tab", [(34016, "Next Tab")])
        top(57321, "Window", [(40012, "Downloads")])
        // Chromium tags the Help command, but leaves the owning top-level item untagged.
        top(0, "Help", [(40020, "Chromium Help")])
        let help = main.items.last!.submenu!.item(withTag: 40020)!
        // Chromium's Cocoa accelerator converts the shifted slash to "?".
        help.keyEquivalent = "?"
        help.keyEquivalentModifierMask = .command
        return main
    }

    static func item(_ menu: NSMenu, _ top: Int, _ tag: Int) -> NSMenuItem {
        menu.item(withTag: top)!.submenu!.item(withTag: tag)!
    }

    static func main() {
        _ = NSApplication.shared
        var ran: [ChromiumAppMenu.Command] = []
        let main = stockMenu()
        let help = main.items.last!.submenu!
        let originalHelp = help.item(withTag: 40020)!
        var privateWindow = false
        var canResize = false
        var canUpdate = false
        var toolbarShown = false
        let installer = ChromiumAppMenu(isOffered: {
            if $0 == .checkForUpdates { return canUpdate }
            if $0 == .resizeSplitPanes { return canResize }
            return $0 != .manageExtensions || !privateWindow
        }, isToolbarShown: { toolbarShown }) { command in
            ran.append(command)
            if command == .toggleToolbar { toolbarShown.toggle() }
        }
        installer.install(in: main)

        // Chromium looks these menus up by tag at runtime, so they stay in the menu, hidden.
        for tag in [57333, 57322, 57323] {
            precondition(main.item(withTag: tag)?.isHidden == true, "tag \(tag) must be hidden, not removed")
        }
        for tag in [40009, 40250, 40259, 40251, 40282, 40299, 40296, 34058, 34061, 35011] {
            precondition(item(main, 57327, tag).isHidden, "View item \(tag) must be hidden")
        }
        precondition(item(main, 57324, 33003).isHidden)
        precondition(!originalHelp.isHidden)
        precondition(main.item(withTag: 57343)!.submenu!.items.last!.submenu!.item(withTag: 39002)!.isHidden, "Search the Web must be hidden")
        let warn = main.item(withTag: 57325)!.submenu!.items.first { $0.title == "Warn Before Quitting" }!
        precondition(warn.isHidden, "Chromium's Warn Before Quitting must be hidden; Nook asks before quitting itself")
        precondition(!item(main, 57327, 35002).isHidden && !item(main, 57327, 34030).isHidden, "View Source and Full Screen stay")

        // Chromium validates a hidden item and may show it again; a hidden item no longer reaches it.
        for tag in [34058, 35011] {
            let entry = item(main, 57327, tag)
            precondition(entry.action != #selector(NSApplication.terminate(_:)) && entry.target != nil, "item \(tag) still reaches Chromium")
        }
        // Chromium shows the Profiles menu again when it rebuilds it, and the History menu's items when history changes.
        main.item(withTag: 57322)!.isHidden = false
        precondition(main.item(withTag: 57322)!.isHidden, "the Profiles menu must stay hidden after Chromium shows it")
        item(main, 57324, 33003).isHidden = false
        precondition(item(main, 57324, 33003).isHidden, "Home must stay hidden after Chromium shows it")
        item(main, 57324, 40010).isHidden = true
        item(main, 57324, 40010).isHidden = false
        precondition(!item(main, 57324, 40010).isHidden, "Show Full History is not held hidden")

        precondition(item(main, 57326, 40000).keyEquivalent.isEmpty && item(main, 57325, 40013).keyEquivalent.isEmpty,
                     "Open File and Delete Browsing Data show no key Chromium never receives")
        precondition(item(main, 57326, 40000).action == #selector(NSApplication.terminate(_:)), "Open File still goes to Chromium")

        let routed: [(Int, Int, ChromiumAppMenu.Command)] = [
            (57325, 40018, .about), (57325, 40015, .settings), (57325, 40014, .importBrowser), (57325, 34031, .quit),
            (57326, 34014, .newTab), (57326, 34028, .reopenClosedTab),
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

        precondition(!item(main, 57325, 40014).isHidden && item(main, 57325, 40014).title == "Import from Another Browser…",
                     "Chromium's import item opens Bark's import from Arc or Chrome")

        // A key the person moved in Settings > Shortcuts: the menu shows the new one and no longer runs the old one.
        installer.showKeys([.closeTab: .init(equivalent: "k", modifiers: [.command, .option]), .newTab: .init(equivalent: "", modifiers: [])])
        func press(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> [ChromiumAppMenu.Command] {
            ran = []
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                                         characters: modifiers.contains(.shift) ? key.uppercased() : key,
                                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            _ = main.performKeyEquivalent(with: event)
            return ran
        }
        precondition(press("w", .command).isEmpty, "the old Close Tab key runs nothing")
        precondition(press("t", .command).isEmpty, "the old New Tab key runs nothing")
        precondition(press("k", [.command, .option]) == [.closeTab], "the bound key runs Close Tab")
        precondition(item(main, 57326, 34015).keyEquivalent == "k" && item(main, 57326, 34015).keyEquivalentModifierMask == [.command, .option],
                     "Close Tab shows the key the person bound")
        precondition(item(main, 57326, 34014).keyEquivalent.isEmpty, "New Tab, left unbound, shows no key")
        precondition(item(main, 57325, 40015).keyEquivalent == "," && item(main, 57326, 39001).keyEquivalent == "l", "Commands not given keep Chromium's key")

        precondition(item(main, 57326, 34000).action == #selector(NSApplication.terminate(_:)), "New Window stays Chromium's")
        precondition(item(main, 57343, 50100).action == #selector(NSApplication.terminate(_:)), "Edit stays Chromium's")

        func added(_ title: String, in menu: NSMenu?) -> ChromiumAppMenu.Command? {
            guard let entry = menu?.items.first(where: { $0.title == title }) else { return nil }
            ran = []
            _ = entry.target?.perform(entry.action, with: entry)
            return ran.first
        }
        let application = main.item(withTag: 57325)!.submenu!
        precondition(application.items.allSatisfy { $0.title != "Check for Updates…" })
        installer.install(in: main, showsUpdater: true)
        let update = application.items.first { $0.title == "Check for Updates…" }!
        precondition(!installer.validateMenuItem(update))
        canUpdate = true
        precondition(installer.validateMenuItem(update))
        precondition(added("Check for Updates…", in: application) == .checkForUpdates)
        installer.install(in: main, showsUpdater: true)
        precondition(application.items.filter { $0.title == "Check for Updates…" }.count == 1)

        let view = main.item(withTag: 57327)!.submenu
        precondition(help.items.count == 2 && help.items.first === originalHelp)
        precondition(originalHelp.title == "Bark Help")
        precondition(originalHelp.keyEquivalent == "?" && originalHelp.keyEquivalentModifierMask == .command)
        precondition(press("?", [.command, .shift]) == [.barkHelp], "Command-Shift-/ opens Bark Help")
        precondition(added("Bark Help", in: help) == .barkHelp)
        precondition(added("Build Information…", in: help) == .buildInformation)
        precondition(added("Toggle Sidebar", in: view) == .toggleSidebar)
        let toolbar = view!.items[1]
        precondition(view!.items[0].title == "Toggle Sidebar" && toolbar.title == "Show Toolbar")
        precondition(added("Show Toolbar", in: view) == .toggleToolbar && ran == [.toggleToolbar] && toolbarShown)
        view!.update()
        precondition(toolbar.title == "Hide Toolbar")
        toolbarShown = false // Settings can also change the toolbar visibility.
        view!.update()
        precondition(toolbar.title == "Show Toolbar")

        installer.showKeys([.toggleToolbar: .init(equivalent: "d", modifiers: [.command, .shift])])
        precondition(toolbar.keyEquivalent == "d" && toolbar.keyEquivalentModifierMask == [.command, .shift])
        precondition(press("d", [.command, .shift]) == [.toggleToolbar] && toolbarShown)
        installer.showKeys([.toggleToolbar: .init(equivalent: "j", modifiers: [.command, .control])])
        precondition(press("d", [.command, .shift]).isEmpty)
        precondition(press("j", [.command, .control]) == [.toggleToolbar] && !toolbarShown)
        installer.showKeys([.toggleToolbar: .init(equivalent: "", modifiers: [])])
        precondition(toolbar.keyEquivalent.isEmpty && press("j", [.command, .control]).isEmpty)

        precondition(added("Toggle AI Assistant", in: view) == .toggleAIAssistant)
        precondition(added("Open Command Bar", in: view) == .commandBar)
        precondition(added("Add Split View", in: view) == .addSplitView)
        let resize = view!.items.first { $0.title == "Resize Split Panes" }!
        view!.update()
        precondition(!resize.isEnabled)
        canResize = true
        view!.update()
        precondition(resize.isEnabled && added("Resize Split Panes", in: view) == .resizeSplitPanes)
        let spaces = main.items.first { $0.title == "Spaces" }?.submenu
        precondition(added("Next Space", in: spaces) == .nextSpace)
        precondition(added("Previous Space", in: spaces) == .previousSpace)
        let extensions = main.items.first { $0.title == "Extensions" }?.submenu
        precondition(added("Manage Extensions", in: extensions) == .manageExtensions)
        let manage = extensions!.items.first { $0.title == "Manage Extensions" }!
        privateWindow = true
        extensions!.update()
        precondition(!manage.isEnabled, "Manage Extensions is off while the window in front is private")
        privateWindow = false
        extensions!.update()
        precondition(manage.isEnabled, "Manage Extensions is on in a regular window")
        let order = main.items.map(\.title)
        precondition(order.firstIndex(of: "Spaces")! < order.firstIndex(of: "Window")!, "Spaces belongs before Window")

        let count = main.items.count
        installer.install(in: main)
        precondition(main.items.count == count && view!.items.filter { $0.title == "Toggle Sidebar" }.count == 1, "install must not duplicate items")
        precondition(help.items.count == 2 && help.items.first === originalHelp)
        precondition(press("?", [.command, .shift]) == [.barkHelp], "reinstall preserves Help shortcut")
        precondition(view!.items.filter { $0.representedObject as? ChromiumAppMenu.Command == .toggleToolbar }.count == 1)

        let empty = NSMenu()
        ChromiumAppMenu { _ in }.install(in: empty)
        let about = ChromiumAppMenu.aboutOptions(chromiumVersion: "156.1.2.3")
        precondition(Set(about.keys) == [.applicationName, .credits], "Keep bundle versions and copyright")
        precondition(about[.applicationName] as? String == "Bark")
        precondition((about[.credits] as? NSAttributedString)?.string ==
            "Chromium 156.1.2.3\nBark is independently maintained and derives from Nook.")
        let unversioned = ChromiumAppMenu.aboutOptions(chromiumVersion: nil)
        precondition((unversioned[.credits] as? NSAttributedString)?.string.hasPrefix("Chromium\n") == true)
        verifyUpdateConfiguration()
        precondition(ChromiumAppMenu.buildInformation(in: .main).hasSuffix("Engine SDK identity unavailable"),
                     "The standalone shell must not invent an engine identity")
        print("PASS chromium-app-menu")
    }
    private static func verifyUpdateConfiguration() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let feedPath = ChromiumUpdateConfiguration.rehearsalFeedPath
        let production: [String: Any] = [
            "SUFeedURL": "https://updates.synthetic.invalid/releases" + feedPath, "SUPublicEDKey": key,
        ]
        let otherFeedPath = feedPath.contains("arm64") ? "/bark-macos-x86_64.xml" : "/bark-macos-arm64.xml"
        var wrongArchitecture = production
        wrongArchitecture["SUFeedURL"] = "https://updates.synthetic.invalid/releases" + otherFeedPath
        precondition(ChromiumUpdateConfiguration(info: wrongArchitecture, isVerification: false,
                                                 isRehearsal: false) == nil, "Reject the other CPU's update feed")
        precondition(ChromiumUpdateConfiguration(info: production, isVerification: false, isRehearsal: false) != nil)
        var custom = production
        custom["SUFeedURL"] = "https://updates.synthetic.invalid/bark.xml"
        precondition(ChromiumUpdateConfiguration(info: custom, isVerification: false, isRehearsal: false) != nil)
        precondition(ChromiumUpdateConfiguration(info: production, isVerification: true, isRehearsal: false) == nil)
        precondition(ChromiumUpdateConfiguration(info: production, isVerification: true, isRehearsal: true) == nil)
        precondition(ChromiumUpdateConfiguration(info: ["SUFeedURL": production["SUFeedURL"]!],
                                                 isVerification: false, isRehearsal: false) == nil)
        precondition(ChromiumUpdateConfiguration(info: ["SUFeedURL": production["SUFeedURL"]!, "SUPublicEDKey": "invalid"],
                                                 isVerification: false, isRehearsal: false) == nil)

        let profile = UUID(), identity = "ee.qdo.bark.test." + UUID().uuidString
        // Chromium registers <bundle ID>.apps.<SHA256 hex> with launchd.
        precondition(identity.utf8.count + ".apps.".utf8.count + 64 < 128)
        let root = "/private/tmp/bark-updates-test-" + UUID().uuidString
        let signedMetadata = ["BarkUpdateRehearsal": ["Profile": profile.uuidString, "DataRoot": root]]
        let rehearsal = try! ChromiumUpdateRehearsal.read(identifier: identity, info: signedMetadata)!
        let isolation = (root: rehearsal.root, profile: rehearsal.profile)
        let relaunched = try! ChromiumStartupConfiguration(arguments: ["Bark"], rehearsal: isolation)
        precondition(relaunched.isVerification && relaunched.root.path == root && relaunched.profileID == profile)
        precondition(relaunched.preferencesDomain.contains("verification."))
        precondition(relaunched.engineArguments(executable: "Bark").contains("--use-mock-keychain"))
        precondition((try? ChromiumStartupConfiguration(
            arguments: ["Bark", "--barc-app-data-dir=/private/tmp/other", "--barc-app-profile=" + profile.uuidString],
            rehearsal: isolation)) == nil)
        precondition((try? ChromiumUpdateRehearsal.read(identifier: identity, info: [:])) == nil)
        precondition((try? ChromiumUpdateRehearsal.read(identifier: "ee.qdo.bark", info: signedMetadata)) == nil)

        let path = ChromiumUpdateConfiguration.rehearsalFeedPath
        let valid = "http://127.0.0.1:43210" + path
        for (feed, automatic, expected) in [(valid, false, true), (valid, true, false),
            ("http://localhost:43210" + path, false, false), ("http://127.0.0.1" + path, false, false),
            (valid + "?override=anything", false, false), ("http://127.0.0.1:43210/other.xml", false, false)] {
            let info: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": key, "SUEnableAutomaticChecks": automatic]
            precondition((ChromiumUpdateConfiguration(info: info, isVerification: true, isRehearsal: true) != nil) == expected)
            precondition(ChromiumUpdateConfiguration(info: info, isVerification: false, isRehearsal: false) == nil)
        }
    }

}
