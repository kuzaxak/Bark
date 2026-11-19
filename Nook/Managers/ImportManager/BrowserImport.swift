// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserImport.swift
//  Nook
//

import Foundation
import NookTabsCore
import NookWeb
import Observation
import OSLog

/// The browsers onboarding's import stage offers.
enum Browsers {
    case arc
    case chrome
    case safari
    case dia
    case firefox
    case zen
}

extension ImportBrowser {
    /// The import an onboarding choice runs, for the browsers Bark imports from itself.
    init?(_ choice: Browsers) {
        switch choice {
        case .arc: self = .arc
        case .chrome: self = .chrome
        default: return nil
        }
    }
}

/// What Continue does on onboarding's import stage.
enum OnboardingImportStep: Equatable {
    case start(ImportBrowser)
    /// Past the import stage, leaving the result shown there behind.
    case moveOn
    case safariFlow
    case otherImport

    static func next(choice: Browsers, shown: BrowserImportSummary?) -> OnboardingImportStep {
        if let shown, !shown.foundNothing || ImportBrowser(choice) == shown.browser { return .moveOn }
        if let browser = ImportBrowser(choice) { return .start(browser) }
        return choice == .safari ? .safariFlow : .otherImport
    }
}

/// What an import from another browser brought in.
struct BrowserImportSummary: Equatable {
    struct Extension: Equatable, Identifiable {
        let id: String
        /// The imported space of the profile that had it enabled.
        let spaceID: UUID

        var webStoreURL: URL { URL(string: "https://chromewebstore.google.com/detail/\(id)")! }
    }

    struct Skipped: Equatable {
        enum Reason: Equatable {
            case folderMissing
            case historyUnreadable
        }
        let profile: String
        let reason: Reason
    }

    let browser: ImportBrowser
    var spaces = 0
    /// Tabs, favorites and bookmarks.
    var tabs = 0
    var visits = 0
    var extensions: [Extension] = []
    var skipped: [Skipped] = []
    var cancelled = false

    var foundNothing: Bool { spaces == 0 }

    var nothingFoundMessage: String {
        switch browser {
        case .arc: "Bark didn't find any Arc spaces on this Mac."
        case .chrome: "Bark didn't find any Chrome profiles on this Mac."
        }
    }

    static let signInNote = "Cookies and passwords were not imported, so sites will ask you to sign in again."
}

@MainActor
@Observable
final class BrowserImportProgress {
    /// Tabs, bookmarks and folders.
    var itemsDone = 0
    var itemsTotal = 0
    var visitsRead = 0
    var visitsTotal = 0
}

/// The app's one import from another browser, running or finished, which every window and
/// onboarding show. Its result stays until the person dismisses it.
@MainActor
@Observable
final class BrowserImportSession {
    let progress: BrowserImportProgress
    private(set) var browser: ImportBrowser?
    private(set) var summary: BrowserImportSummary?
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        progress = BrowserImportProgress()
    }

    /// Runs the import unless one is running or a result waits to be dismissed. Returns whether it started.
    @discardableResult
    func start(_ browser: ImportBrowser, run: @escaping @MainActor (BrowserImportProgress) async -> BrowserImportSummary) -> Bool {
        guard !isRunning, summary == nil else { return false }
        self.browser = browser
        isRunning = true
        let progress = progress
        task = Task { @MainActor in
            summary = await run(progress)
            isRunning = false
        }
        return true
    }

    func stop() {
        task?.cancel()
    }

    func dismiss() {
        guard !isRunning else { return }
        summary = nil
        browser = nil
    }
}

/// Brings another browser's profiles in as new Bark spaces and profiles, without loading a page
/// and without changing anything the person already has.
@MainActor
struct BrowserImporter {
    static let chromeFolderTitle = "Bookmarks from Chrome"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Import")

    let source: ImportManager
    let tabs: TabsController
    let history: HistoryManager
    let window: BrowserWindowState
    /// Keeps the date of the last import from each browser.
    let lastImports: URL
    /// Onboarding starts with a space holding only a Google tab; imported spaces replace it.
    let replacesStarterSpaces: Bool
    let progress: BrowserImportProgress
    /// Receives counts and error classes only.
    var log: (String) -> Void = { BrowserImporter.logger.info("\($0, privacy: .public)") }

    init(source: ImportManager, tabs: TabsController, history: HistoryManager, window: BrowserWindowState, lastImports: URL,
         replacesStarterSpaces: Bool, progress: BrowserImportProgress) {
        self.source = source
        self.tabs = tabs
        self.history = history
        self.window = window
        self.lastImports = lastImports
        self.replacesStarterSpaces = replacesStarterSpaces
        self.progress = progress
    }

    func run(_ browser: ImportBrowser) async -> BrowserImportSummary {
        var summary = BrowserImportSummary(browser: browser)
        progress.itemsDone = 0
        progress.itemsTotal = 0
        progress.visitsRead = 0
        progress.visitsTotal = 0
        let starters = replacesStarterSpaces ? starterSpaces() : []
        let created = switch browser {
        case .arc: await importArcSpaces(into: &summary)
        case .chrome: await importChromeProfiles(into: &summary)
        }
        guard let first = created.first?.space else {
            log("\(browser.name) import found nothing to import")
            return summary
        }
        if window.spaceID.map(starters.contains) ?? true { tabs.setSpace(first, in: window) }
        starters.forEach { tabs.deleteSpace($0) }
        summary.extensions = extensions(browser, created)
        await importHistory(browser, created, into: &summary)
        Self.recordImport(of: browser, in: lastImports)
        log("\(browser.name) import: \(summary.spaces) spaces, \(summary.tabs) tabs and bookmarks, \(summary.visits) visits, "
            + "\(summary.extensions.count) extensions, \(summary.skipped.count) skipped\(summary.cancelled ? ", cancelled" : "")")
        return summary
    }

    /// Opens an extension's Web Store page, unloaded, at the top of its space's Today section.
    @discardableResult
    func openWebStorePage(_ item: BrowserImportSummary.Extension) -> UUID? {
        tabs.open(url: item.webStoreURL, in: window, placement: .background, parent: .tabs(spaceID: item.spaceID), title: "Chrome Web Store")
    }

    static func lastImport(of browser: ImportBrowser, in file: URL) -> Date? {
        lastImports(in: file)[browser.rawValue]
    }

    // MARK: - Spaces

    /// Arc's spaces in order, each with its pinned and Today sections, nested folders, custom tab
    /// names, icon and colour; a profile's favorites in its first space, which its other spaces
    /// share. Each Arc profile becomes a Bark profile with Arc's name.
    private func importArcSpaces(into summary: inout BrowserImportSummary) async -> [(directory: String, space: UUID)] {
        let result = await source.importArcSidebarData()
        var profileKeys = Set<String>()
        let sections = result.spaces.map { space in
            (favorites: profileKeys.insert(space.profile).inserted ? Self.items(result.favorites[space.profile] ?? []) : [],
             pinned: Self.items(space.pinned), today: Self.items(space.unpinned))
        }
        progress.itemsTotal = sections.flatMap { $0.favorites + $0.pinned + $0.today }.reduce(0) { $0 + $1.count }
        var lastSpace = tabs.orderedSpaces.last?.id
        var profiles: [(key: String, space: UUID)] = []
        for (space, section) in zip(result.spaces, sections) {
            if summary.spaces > 0, Task.isCancelled {
                summary.cancelled = true
                break
            }
            let shared = profiles.first { $0.key == space.profile }?.space
            guard let spaceID = tabs.createSpace(name: space.title, icon: space.emoji ?? "", accentHex: space.accentHex ?? "#7C7C7C",
                                                 after: lastSpace, sharingLoginsWith: shared, profileName: result.profileNames[space.profile])
            else { continue }
            lastSpace = spaceID
            summary.spaces += 1
            if shared == nil { profiles.append((space.profile, spaceID)) }
            do {
                summary.tabs += try await addTree(section.favorites, into: .favorites(spaceID: spaceID))
                summary.tabs += try await addTree(section.pinned, into: .pinned(spaceID: spaceID))
                summary.tabs += try await addTree(section.today, into: .tabs(spaceID: spaceID))
            } catch {
                summary.cancelled = true
                break
            }
        }
        return profiles.map { (ImportManager.arcProfileDirectory($0.key), $0.space) }
    }

    /// Each Chrome profile as a space in a Bark profile of its own, both named as in Chrome, with
    /// its bookmarks in one closed pinned folder.
    private func importChromeProfiles(into summary: inout BrowserImportSummary) async -> [(directory: String, space: UUID)] {
        let profiles = source.chromiumProfiles(.chrome)
        summary.skipped += profiles.missing.map { .init(profile: $0.name, reason: .folderMissing) }
        let trees = profiles.found.map { profile -> [TabsController.ImportedItem] in
            let bookmarks = Self.items(source.chromeBookmarks(profile))
            return bookmarks.isEmpty ? [] : [.folder(title: Self.chromeFolderTitle, children: bookmarks)]
        }
        progress.itemsTotal = trees.joined().reduce(0) { $0 + $1.count }
        var lastSpace = tabs.orderedSpaces.last?.id
        var created: [(directory: String, space: UUID)] = []
        for (profile, tree) in zip(profiles.found, trees) {
            if !created.isEmpty, Task.isCancelled {
                summary.cancelled = true
                break
            }
            guard let spaceID = tabs.createSpace(name: profile.name, icon: "", accentHex: "#7C7C7C", after: lastSpace, profileName: profile.name)
            else { continue }
            lastSpace = spaceID
            summary.spaces += 1
            created.append((profile.directory, spaceID))
            do {
                summary.tabs += try await addTree(tree, into: .pinned(spaceID: spaceID))
            } catch {
                summary.cancelled = true
                break
            }
        }
        return created
    }

    /// Bark's tabs keep web pages and files; anything else another browser had stays behind.
    private static func items(_ nodes: [ArcNode]) -> [TabsController.ImportedItem] {
        nodes.compactMap { node in
            switch node {
            case let .tab(string, title, customTitle):
                guard let url = URL(string: string), ["http", "https", "file"].contains(url.scheme?.lowercased()) else { return nil }
                return .tab(url: url, title: title, customTitle: customTitle)
            case let .folder(title, children):
                return .folder(title: title, children: items(children))
            }
        }
    }

    /// Adds the tree under `parent` in source order, closed and without loading a page, a slice at
    /// a time. Returns how many tabs came in.
    private func addTree(_ items: [TabsController.ImportedItem], into parent: Parent) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        let before = progress.itemsDone, progress = progress
        return try await tabs.importTree(items, into: parent) { progress.itemsDone = before + $0 }
    }

    private func starterSpaces() -> [UUID] {
        tabs.orderedSpaces.filter { space in
            !space.isAgent && tabs.items(inSpace: space.id).allSatisfy {
                $0.parent == .tabs(spaceID: space.id) && $0.url?.host == TabsController.homeURL.host
            }
        }.map(\.id)
    }

    // MARK: - Extensions and history

    /// Each enabled Web Store extension once, with the space of the first profile that had it.
    private func extensions(_ browser: ImportBrowser, _ created: [(directory: String, space: UUID)]) -> [BrowserImportSummary.Extension] {
        var seen = Set<String>()
        return created.flatMap { profile in
            source.extensionIDs(browser, profile.directory).filter { seen.insert($0).inserted }.map { .init(id: $0, spaceID: profile.space) }
        }
    }

    /// Every profile's visits into the Bark profile made for it, a batch at a time, each batch
    /// stored before the next is read. Cancelling stops at the next batch.
    private func importHistory(_ browser: ImportBrowser, _ created: [(directory: String, space: UUID)],
                               into summary: inout BrowserImportSummary) async {
        let names = Dictionary(source.chromiumProfiles(browser).found.map { ($0.directory, $0.name) }, uniquingKeysWith: { a, _ in a })
        let history = history, progress = progress
        for profile in created {
            guard !summary.cancelled, let store = tabs.tree.dataStoreID(for: profile.space),
                  let file = source.profileDirectory(browser, profile.directory)?.appendingPathComponent("History") else { continue }
            let before = progress.visitsRead, totalBefore = progress.visitsTotal
            do {
                _ = try await readChromiumHistory(file, workDirectory: source.workDirectory) { batch, read, total in
                    let visits = batch.compactMap { visit in
                        URL(string: visit.url).map { HistoryVisit(url: $0, title: visit.title, timestamp: visit.date, tabId: nil, profileId: store) }
                    }
                    await history.importVisitsAndWait(visits, claimUnscopedRows: false)
                    await MainActor.run {
                        progress.visitsRead = before + read
                        progress.visitsTotal = totalBefore + total
                    }
                }
            } catch is CancellationError {
                summary.cancelled = true
            } catch {
                summary.skipped.append(.init(profile: names[profile.directory] ?? profile.directory, reason: .historyUnreadable))
                log("\(browser.name) history unreadable: \(error)")
            }
            summary.visits = progress.visitsRead
        }
    }

    // MARK: - Last import

    private static func lastImports(in file: URL) -> [String: Date] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? decoder.decode([String: Date].self, from: $0) } ?? [:]
    }

    private static func recordImport(of browser: ImportBrowser, in file: URL) {
        var dates = lastImports(in: file)
        dates[browser.rawValue] = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(dates).write(to: file, options: .atomic)
    }
}
