// Licensed under GPL-3.0. See LICENSE.
// The model import, on a TabsController and a HistoryManager of the harness's own.
import Foundation
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
import NookWeb
import SwiftData

/// A TabsController with one window and an in-memory history, on a throwaway directory.
@MainActor
final class Host {
    let tabs: TabsController
    let history: HistoryManager
    let window = BrowserWindowState()
    let registry = WindowRegistry()
    let directory: URL
    var logged: [String] = []

    /// `onDisk` stores history in files as the app does, with its frecency and page-text indexes.
    init(onDisk: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChromiumImportCheck-\(UUID().uuidString)", isDirectory: true)
        let tabsDirectory = directory.appendingPathComponent("Tabs", isDirectory: true)
        try FileManager.default.createDirectory(at: tabsDirectory, withIntermediateDirectories: true)
        let settings = NookSettingsService()
        tabs = TabsController(settings: settings, windowRegistry: registry, blocker: ContentBlockerManager(settings: settings),
                              sponsorBlock: SponsorBlockManager(settings: settings), siteRouting: SiteRoutingManager(settings: settings),
                              directory: tabsDirectory)
        if onDisk {
            let container = try ModelContainer(for: HistoryEntity.self, configurations: ModelConfiguration(url: directory.appendingPathComponent("History.store")))
            history = HistoryManager(context: ModelContext(container), pageTextURL: directory.appendingPathComponent("History/page-text.sqlite"),
                                     indexURL: directory.appendingPathComponent("History/history-index.sqlite"))
        } else {
            let container = try ModelContainer(for: HistoryEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            history = HistoryManager(context: ModelContext(container))
        }
        registry.register(window)
        registry.setActive(window)
        tabs.attach(window: window)
    }

    func importer(_ source: ImportManager, starters: Bool = false, progress: BrowserImportProgress? = nil) -> BrowserImporter {
        var importer = BrowserImporter(source: source, tabs: tabs, history: history, window: window,
                                       lastImports: directory.appendingPathComponent("LastImports.json"),
                                       replacesStarterSpaces: starters, progress: progress ?? BrowserImportProgress())
        importer.log = { [weak self] in self?.logged.append($0) }
        return importer
    }

    /// A space's pinned section as the importer's own tree, folders open or closed.
    func tree(_ parent: Parent) -> [ArcNode] {
        tabs.children(of: parent).map { item in
            if item.isFolder { return .folder(title: item.customTitle ?? "", children: tree(.folder(itemID: item.id))) }
            guard case let .tab(url, title) = item.kind else { preconditionFailure() }
            return .tab(url: url.absoluteString, title: title, customTitle: item.customTitle)
        }
    }

    /// Every item under the space's three sections, folders included, in sidebar order.
    func everything(in spaceID: UUID) -> [Item] {
        func walk(_ parent: Parent) -> [Item] {
            tabs.children(of: parent).flatMap { [$0] + ($0.isFolder ? walk(.folder(itemID: $0.id)) : []) }
        }
        return [Parent.favorites(spaceID: spaceID), .pinned(spaceID: spaceID), .tabs(spaceID: spaceID)].flatMap(walk)
    }

    func folders(in spaceID: UUID) -> [UUID] {
        everything(in: spaceID).filter(\.isFolder).map(\.id)
    }

    func visits(_ profile: UUID?) async -> [HistoryEntry] {
        history.switchProfile(profile)
        return await history.getHistory(days: 36_500, limit: 1_000).entries
    }

    func profile(_ spaceID: UUID) -> UUID { tabs.tree.dataStoreID(for: spaceID)! }
}

extension Check {
    static func source(_ root: URL) -> ImportManager {
        ImportManager(sources: .fixtures(in: root), workDirectory: root.appendingPathComponent("App/ImportCopies", isDirectory: true))
    }

    static func modelImport() async throws {
        try await chromeIntoTabs()
        try await chromeHistoryKeepsUnscopedRows()
        try await arcIntoTabs()
        try await nothingToImport()
        try await startersAndChoice()
        try await manyBookmarks()
        try await oneImportSession()
        onboardingContinue()
    }

    /// Review M1: one import at a time, and its result kept until the person dismisses it.
    static func oneImportSession() async throws {
        let host = try Host()
        let session = BrowserImportSession()
        let run: @MainActor (BrowserImportProgress) async -> BrowserImportSummary = { progress in
            await host.importer(source(root), progress: progress).run(.chrome)
        }
        func finished() async throws {
            while session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        }
        precondition(session.start(.chrome, run: run) && session.isRunning && session.browser == .chrome, "an import starts")
        precondition(!session.start(.arc, run: run) && session.browser == .chrome, "a second one is refused while it runs")
        try await finished()
        precondition(session.summary?.spaces == 2 && session.summary?.visits == 4 && session.progress.visitsRead == 4,
                     "its result stays when it ends: \(String(describing: session.summary))")
        precondition(!session.start(.chrome, run: run) && session.summary?.spaces == 2, "and no new import replaces it before it is dismissed")
        session.dismiss()
        precondition(session.summary == nil && session.browser == nil, "dismissing forgets it")
        precondition(session.start(.chrome, run: run), "then a new import can start")
        session.stop()
        try await finished()
        precondition(session.summary?.cancelled == true, "and stopping it keeps what came in: \(String(describing: session.summary))")
        precondition(host.tabs.orderedSpaces.count == 1 + 2 + 1, "two imports ran, never three: \(host.tabs.orderedSpaces.map(\.name))")
    }

    /// Review minor 1: Continue after "nothing found" moves on instead of asking again.
    static func onboardingContinue() {
        let arcNothing = BrowserImportSummary(browser: .arc)
        var chromeFound = BrowserImportSummary(browser: .chrome)
        chromeFound.spaces = 2
        let cases: [(Browsers, BrowserImportSummary?, OnboardingImportStep)] = [
            (.chrome, nil, .start(.chrome)), (.arc, nil, .start(.arc)),
            (.arc, arcNothing, .moveOn), (.chrome, arcNothing, .start(.chrome)), (.chrome, chromeFound, .moveOn),
            (.safari, nil, .safariFlow), (.dia, nil, .otherImport),
        ]
        for (choice, shown, step) in cases {
            precondition(OnboardingImportStep.next(choice: choice, shown: shown) == step,
                         "Continue with \(choice) after \(String(describing: shown?.browser)) \(shown?.foundNothing == true ? "nothing" : "something"): \(step)")
        }
    }

    /// Ruling 2: 5,000 bookmarks come in without freezing the window.
    static func manyBookmarks() async throws {
        let host = try Host()
        let probe = MainProbe()
        probe.start()
        try await Task.sleep(for: .milliseconds(20))
        let progress = BrowserImportProgress()
        var seen = Set<Int>()
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                seen.insert(progress.itemsDone)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let summary = await host.importer(source(URL(fileURLWithPath: arguments[6], isDirectory: true)), progress: progress).run(.chrome)
        watcher.cancel()
        probe.stop()
        precondition(seen.filter { $0 > 0 && $0 < 5_101 }.count >= 10 && progress.itemsDone == 5_101 && progress.itemsTotal == 5_101,
                     "progress moves while bookmarks come in: \(seen.count) values, \(progress.itemsDone)/\(progress.itemsTotal)")
        precondition(summary.tabs == 5_000, "every bookmark came in: \(summary.tabs)")
        precondition(probe.longestStall < .milliseconds(500), "the main actor waited \(probe.longestStall) while bookmarks came in")
    }

    /// An imported visit must not take ownership of existing legacy history for the same URL.
    static func chromeHistoryKeepsUnscopedRows() async throws {
        let host = try Host(onDisk: true)
        let originalProfile = host.profile(try requireValue(host.window.spaceID))
        let url = URL(string: "https://fixture.test/work-wiki")!
        await host.history.importVisitsAndWait([
            HistoryVisit(url: url, title: "Bark Legacy Wiki", timestamp: Date(), tabId: nil, profileId: nil)
        ])
        let legacy = try requireValue(await host.visits(originalProfile).first { $0.url == url })
        precondition(legacy.title == "Bark Legacy Wiki" && legacy.visitCount == 1)
        let summary = await host.importer(source(root)).run(.chrome)
        precondition(summary.visits == 4)

        let originalRows = await host.visits(originalProfile).filter { $0.url == url }
        precondition(originalRows.count == 1 && originalRows[0].id == legacy.id
                     && originalRows[0].title == legacy.title && originalRows[0].visitCount == 1,
                     "Chrome import must preserve the original unscoped history row")
        let originalIndex = await host.history.indexRows(matching: "Bark Legacy Wiki")
        precondition(originalIndex?.first(where: { $0.url == url.absoluteString })?.visitCount == 1,
                     "Chrome import must preserve the original unscoped palette entry")

        let work = try requireValue(host.tabs.orderedSpaces.first { $0.name == "Work" })
        let importedRows = await host.visits(host.profile(work.id)).filter { $0.url == url }
        precondition(importedRows.count == 2 && importedRows.contains {
            $0.id != legacy.id && $0.title == "Work Wiki" && $0.visitCount == 1
        }, "Chrome history must have a separate row in the imported Work profile")
        let importedIndex = await host.history.indexRows(matching: "Work Wiki")
        precondition(importedIndex?.contains { $0.url == url.absoluteString &&
            $0.title == "Work Wiki" && $0.visitCount == 1 } == true,
            "the imported profile must get its own palette entry")
    }

    /// I4–I6 for Chrome: profiles become profiles and spaces, bookmarks one closed pinned folder,
    /// history goes to its own profile, and the extension list names each id once.
    static func chromeIntoTabs() async throws {
        let host = try Host()
        let own = try requireValue(host.window.spaceID)
        let ownTab = try requireValue(host.tabs.open(url: URL(string: "https://person.test/own")!, in: host.window, placement: .background,
                                                     parent: .pinned(spaceID: own)))
        let ownItems = host.everything(in: own)
        let progress = BrowserImportProgress()
        let importer = host.importer(source(root), progress: progress)
        let summary = await importer.run(.chrome)
        host.history.switchProfile(host.tabs.tree.dataStoreID(for: host.tabs.orderedSpaces[2].id))
        let stored = await host.history.autofillHost(prefix: "fixture", minVisits: 2)
        precondition(stored == "fixture.test", "each batch is stored before the import goes on: \(String(describing: stored))")

        let spaces = host.tabs.orderedSpaces
        precondition(spaces.map(\.name) == [spaces[0].name, "Work", "Fixture Person"] && spaces[0].id == own,
                     "each Chrome profile becomes a space, in the person's order, after the person's own: \(spaces.map(\.name))")
        precondition(host.everything(in: own) == ownItems && ownItems.contains { $0.id == ownTab },
                     "the person's own space is untouched")
        let work = spaces[1].id, person = spaces[2].id
        let profiles = host.tabs.tree.profiles
        for (space, name) in [(work, "Work"), (person, "Fixture Person")] {
            let profile = host.profile(space)
            precondition(profile != host.profile(own) && profiles.first { $0.id == profile }?.name == name,
                         "in a Bark profile of its own, named as in Chrome: \(profiles.map(\.name))")
        }
        precondition(host.profile(work) != host.profile(person), "one profile per Chrome profile")

        for (space, expected) in [(work, [ArcNode.tab(url: "https://fixture.test/board", title: "Work Board", customTitle: nil),
                                          .tab(url: "https://fixture.test/account", title: "Work Account", customTitle: nil)]),
                                  (person, importer.source.chromeBookmarks(ChromiumProfile(directory: "Default", name: "Fixture Person")))] {
            precondition(host.tree(.pinned(spaceID: space)) == [.folder(title: "Bookmarks from Chrome", children: expected)],
                         "the profile's bookmarks sit in one pinned folder: \(host.tree(.pinned(spaceID: space)))")
            precondition(host.tabs.children(of: .tabs(spaceID: space)).isEmpty && host.tabs.children(of: .favorites(spaceID: space)).isEmpty,
                         "and nowhere else")
            precondition(host.folders(in: space).allSatisfy { !host.tabs.isOpen(folder: $0) }, "closed, with every folder inside it")
        }
        precondition(host.folders(in: person).count == 4, "Reading, Deep and Other Bookmarks keep their nesting")
        precondition(host.tabs.sessions.isEmpty, "no page is loaded")

        let workVisits = await host.visits(host.profile(work)), personVisits = await host.visits(host.profile(person))
        precondition(workVisits.map(\.url.absoluteString) == ["https://fixture.test/work-wiki"],
                     "Work's history is under Work's profile and no other: \(workVisits.map(\.url))")
        precondition(Set(personVisits.map(\.url.absoluteString)) == ["https://fixture.test/news", "https://fixture.test/docs"]
                     && personVisits.first { $0.url.absoluteString == "https://fixture.test/news" }?.visitCount == 2
                     && personVisits.first { $0.url.absoluteString == "https://fixture.test/news" }?.lastVisited == daysAgo(1),
                     "the person's history keeps its visits and times: \(personVisits.map { ($0.url, $0.visitCount, $0.lastVisited) })")
        let ownVisits = await host.visits(host.profile(own))
        precondition(ownVisits.isEmpty, "the person's own profile gets none of it")

        precondition(summary.spaces == 2 && summary.tabs == 6 && summary.visits == 4 && !summary.cancelled,
                     "the result counts what came in: \(summary)")
        precondition(summary.extensions == [.init(id: String(repeating: "a", count: 32), spaceID: work),
                                            .init(id: String(repeating: "e", count: 32), spaceID: work),
                                            .init(id: String(repeating: "g", count: 32), spaceID: person)],
                     "enabled Web Store extensions once each, without disabled, unpacked or built-in ones: \(summary.extensions)")
        precondition(summary.skipped == [.init(profile: "Gone", reason: .folderMissing)], "and names the profile it could not find: \(summary.skipped)")
        precondition(progress.visitsRead == 4 && progress.visitsTotal == 4 && progress.itemsDone == 11 && progress.itemsTotal == 11,
                     "progress ends at the totals: \(progress.itemsDone)/\(progress.itemsTotal) \(progress.visitsRead)/\(progress.visitsTotal)")
        let firstDate = try requireValue(BrowserImporter.lastImport(of: .chrome, in: importer.lastImports))
        precondition(BrowserImporter.lastImport(of: .arc, in: importer.lastImports) == nil, "the date of the last import is kept per browser")

        let store = try requireValue(importer.openWebStorePage(summary.extensions[2]))
        precondition(host.tabs.children(of: .tabs(spaceID: person)).map(\.url) == [URL(string: "https://chromewebstore.google.com/detail/" + String(repeating: "g", count: 32))]
                     && host.tabs.children(of: .tabs(spaceID: person)).first?.id == store && host.tabs.sessions.isEmpty,
                     "an extension's button opens its Web Store page as a tab in the space of the profile that had it")

        let again = await importer.run(.chrome)
        precondition(again.spaces == 2 && again.visits == 4 && host.tabs.orderedSpaces.count == 5 && host.everything(in: own) == ownItems,
                     "a second import adds again and leaves everything else alone")
        let secondDate = try requireValue(BrowserImporter.lastImport(of: .chrome, in: importer.lastImports))
        precondition(secondDate >= firstDate, "and moves the date")

        let cancelledHost = try Host()
        let task = Task { await cancelledHost.importer(source(root)).run(.chrome) }
        task.cancel()
        let cancelled = await task.value
        precondition(cancelled.cancelled && cancelled.spaces == 1 && cancelled.visits == 0,
                     "a cancelled import stops before the next profile and before history: \(cancelled)")
        precondition(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("App/ImportCopies").path)) ?? []).isEmpty,
                     "and leaves no copy")
        let resumed = await cancelledHost.importer(source(root)).run(.chrome)
        precondition(resumed.visits == 4 && !resumed.cancelled, "importing again after a cancel brings everything: \(resumed)")

        let errorsHost = try Host()
        let broken = await errorsHost.importer(source(URL(fileURLWithPath: arguments[2], isDirectory: true))).run(.chrome)
        precondition(broken.spaces == 2 && broken.tabs == 0 && broken.extensions.isEmpty
                     && broken.skipped == [.init(profile: "Broken", reason: .historyUnreadable)],
                     "malformed or missing files bring nothing, and an unreadable history is named: \(broken)")
        precondition(errorsHost.tabs.orderedSpaces.dropFirst().allSatisfy { errorsHost.tabs.children(of: .pinned(spaceID: $0.id)).isEmpty },
                     "a profile with no bookmarks gets no folder")

        for host in [host, cancelledHost, errorsHost] { noPrivateData(in: host.logged) }
    }

    /// B2, I5, I6 for Arc: the sidebar as before, each Arc profile's history in its own Bark profile.
    static func arcIntoTabs() async throws {
        let host = try Host()
        let summary = await host.importer(source(root)).run(.arc)
        let spaces = Array(host.tabs.orderedSpaces.dropFirst())
        precondition(spaces.map(\.name) == ["Fixture Space", "Arc Work Space", "Fixture Errands"], "Arc's spaces in order: \(spaces.map(\.name))")
        let (fixture, work, errands) = (spaces[0].id, spaces[1].id, spaces[2].id)
        precondition(spaces[0].icon == "🧪" && spaces[0].accentHex == "#FF8000", "with icon and colour")
        precondition(host.profile(fixture) == host.profile(errands) && host.profile(fixture) != host.profile(work),
                     "spaces of one Arc profile share one Bark profile")
        precondition(host.tabs.tree.profiles.first { $0.id == host.profile(work) }?.name == "Arc Work", "named as in Arc")
        precondition(host.tree(.pinned(spaceID: fixture)) == [.tab(url: "https://fixture.test/pinned", title: "Pinned", customTitle: "Mine"),
                                                            .folder(title: "Reading", children: [.tab(url: "https://fixture.test/read", title: "Read", customTitle: nil)])]
                     && host.tree(.tabs(spaceID: fixture)) == [.tab(url: "https://fixture.test/today", title: "Today", customTitle: nil)],
                     "pinned tabs, folders and Today tabs: \(host.tree(.pinned(spaceID: fixture)))")
        let favorite = [URL(string: "https://fixture.test/favorite")!]
        precondition(host.tabs.favorites(of: fixture).map(\.url) == favorite && host.tabs.favorites(of: errands).map(\.url) == favorite
                     && host.tabs.favorites(of: work).isEmpty, "a profile's favorites show once in each of its spaces")
        precondition(host.folders(in: fixture).allSatisfy { !host.tabs.isOpen(folder: $0) } && host.tabs.sessions.isEmpty,
                     "folders closed, no page loaded")
        let fixtureVisits = await host.visits(host.profile(fixture)), workVisits = await host.visits(host.profile(work))
        precondition(fixtureVisits.map(\.url.absoluteString) == ["https://fixture.test/arc-history"]
                     && workVisits.map(\.url.absoluteString) == ["https://fixture.test/arc-work-history"],
                     "each Arc profile's history in its own Bark profile: \(fixtureVisits.map(\.url)) \(workVisits.map(\.url))")
        precondition(summary.spaces == 3 && summary.tabs == 6 && summary.visits == 2 && summary.skipped.isEmpty,
                     "the result counts what came in: \(summary)")
        precondition(summary.extensions == [.init(id: String(repeating: "f", count: 32), spaceID: fixture)], "with Arc's extensions: \(summary.extensions)")
        noPrivateData(in: host.logged)

        let outside = try Host()
        let escaped = await outside.importer(source(URL(fileURLWithPath: arguments[2], isDirectory: true))).run(.arc)
        precondition(escaped.spaces == 1 && escaped.tabs == 1 && escaped.visits == 0 && escaped.skipped.isEmpty,
                     "an Arc profile named as a path out of Arc's folder brings its space and no files from outside: \(escaped)")
    }

    /// B8: a source with nothing to read says so and changes nothing.
    static func nothingToImport() async throws {
        for root in [URL(fileURLWithPath: arguments[3], isDirectory: true), root.appendingPathComponent("nothing")] {
            for browser in ImportBrowser.allCases {
                let host = try Host()
                let before = host.tabs.tree
                let importer = host.importer(source(root))
                let summary = await importer.run(browser)
                precondition(summary.foundNothing && host.tabs.tree == before, "\(browser) with nothing to read creates nothing")
                precondition(summary.nothingFoundMessage == (browser == .chrome ? "Bark didn't find any Chrome profiles on this Mac."
                                                                                : "Bark didn't find any Arc spaces on this Mac."), "and says so")
                precondition(BrowserImporter.lastImport(of: browser, in: importer.lastImports) == nil, "and keeps no date")
            }
        }
        let host = try Host()
        precondition(!host.importer(source(URL(fileURLWithPath: arguments[3], isDirectory: true))).source.isInstalled(.arc)
                     && host.importer(source(root)).source.isInstalled(.chrome)
                     && !host.importer(source(root.appendingPathComponent("nothing"))).source.isInstalled(.chrome),
                     "a browser is offered only when its Local State is there")
    }

    /// B7 and I7: onboarding's starter space goes when spaces came in; onboarding's Chrome choice imports Chrome.
    static func startersAndChoice() async throws {
        precondition(ImportBrowser(Browsers.chrome) == .chrome && ImportBrowser(Browsers.arc) == .arc && ImportBrowser(Browsers.safari) == nil,
                     "onboarding's Chrome and Arc choices are Bark's own imports")
        let host = try Host()
        let starter = try requireValue(host.window.spaceID)
        host.tabs.open(url: TabsController.homeURL, in: host.window, placement: .background, parent: .tabs(spaceID: starter))
        let summary = await host.importer(source(root), starters: true).run(try requireValue(ImportBrowser(Browsers.chrome)))
        precondition(summary.spaces == 2 && host.tabs.space(starter) == nil && host.tabs.orderedSpaces.map(\.name) == ["Work", "Fixture Person"],
                     "the starter space is dropped once Chrome's spaces came in: \(host.tabs.orderedSpaces.map(\.name))")
        precondition(host.window.spaceID == host.tabs.orderedSpaces.first?.id, "and the window shows the first imported space")
    }

    /// B9: log lines carry counts and error classes, never a URL, a title, a name or a path.
    static func noPrivateData(in lines: [String]) {
        precondition(!lines.isEmpty, "the import logs its outcome")
        let forbidden = ["fixture.test", "Fixture", "Work", "Gone", "Broken", "Empty", "Errand", "/", "aaaaaaaa", "gggggggg"]
        for line in lines {
            precondition(!forbidden.contains { line.contains($0) }, "a log line names the person's data: \(line)")
        }
    }

    static func requireValue<T>(_ value: T?, _ line: Int = #line) throws -> T {
        guard let value else { preconditionFailure("nil at Model.swift:\(line)") }
        return value
    }
}
