import AppKit
import CryptoKit
import Foundation
import NookSettings
import NookTabsCore
import NookWeb
import Observation
import OSLog
import SQLite3
import SwiftData

/// Copies the WebKit app's app-owned stores into the Chromium app. The source is only read;
/// engine state is never derived from it.
struct ChromiumDataConversion {
    struct Environment {
        var root: URL
        var legacySupport: URL
        var preferencesDomain: String
        var isLegacyAppRunning: () -> Bool
        var availableSpace: () throws -> Int64
        var legacyPreferences: () -> [String: Any]?
        var checkpoint: (String) throws -> Void = { _ in }
    }

    enum Failure: Error, Equatable {
        case legacyAppRunning, destinationOccupied, sourceChanged, diskFull, interrupted
        case sourceUnreadable(String), validationFailed(String), failed(String)
        case insufficientSpace(required: Int64, available: Int64)

        var message: String {
            switch self {
            case .legacyAppRunning:
                return "Quit the old Nook app, then try again. It must not be running while its data is copied."
            case .destinationOccupied:
                return "This browser already has its own data, so your old data was not copied over it."
            case .sourceChanged:
                return "The old Nook app changed its data during the conversion. Quit it, then try again."
            case .diskFull:
                return "The disk ran out of space during the conversion. Free some space, then try again."
            case .interrupted:
                return "An earlier conversion left incomplete data that cannot be resumed. Choose Start Fresh to continue without it."
            case .sourceUnreadable(let store):
                return "Your old \(store) could not be read. Nothing was changed."
            case .validationFailed(let store):
                return "Your old \(store) could not be loaded by this browser, so nothing was converted."
            case .failed(let code):
                return "The conversion stopped unexpectedly (\(code)). Your old data is unchanged."
            case .insufficientSpace(let required, let available):
                let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                return "Not enough free disk space: the conversion needs \(format(required)), and \(format(available)) is free. Nothing was changed."
            }
        }
    }

    static let legacyBundleID = "ee.qdo.nook"
    static let noticeTitle = "Bring your Nook data to this browser?"
    static let noticeBody = """
        Nook can copy your profiles, spaces, tabs, pinned items and folders, history, Boosts, downloads list, \
        AI settings and app settings into this browser. Your old data stays where it is, and the old app keeps working.

        These do not transfer:
        • Cookies and website storage do not transfer yet, so you will need to sign in to websites again.
        • Extensions must be reinstalled for each profile.
        • AI provider API keys must be entered again.
        """

    static let allowedPreferences: Set<String> = [
        "keyboard.shortcuts", "keyboard.shortcuts.version", "sidebarVisible", "sidebarWidth",
        "settings.adBlockerEnabled", "settings.adBlockerWhitelist", "settings.appearanceMode",
        "settings.archiveTabsAfterHours", "settings.askBeforeQuit", "settings.autoPictureInPicture",
        "settings.autoRenamePinnedTabs", "settings.boosts", "settings.browserControlServer",
        "settings.customSearchEngines", "settings.developerMode", "settings.developerSites",
        "settings.didFinishOnboarding", "settings.enabledOptionalFilterLists",
        "settings.enhancedFingerprintingProtection", "settings.externalLinkDestination",
        "settings.facebookHideReels", "settings.facebookHideSuggested", "settings.favoriteMeetingsAndMail",
        "settings.favoritePreviews", "settings.hideWebContentBorder", "settings.historyHalfLifeDays",
        "settings.idleTabUnloadingEnabled", "settings.linkPreviews", "settings.mediaDownloadSites",
        "settings.nestLinkTabsUnderOpener", "settings.newTabsAtTopLevel", "settings.openNewTabLinksInPeek",
        "settings.paletteWordStops", "settings.pawlVaultEnabled", "settings.peekLinksToOtherSites",
        "settings.peekOnShiftClick", "settings.profileDownloads", "settings.redditSortHot",
        "settings.removeTrackingFromLinks", "settings.searchEngine", "settings.searchPageTextInHistory",
        "settings.securityKeysEnabled", "settings.showAIAssistant", "settings.showLinkStatusBar",
        "settings.sidebarPosition", "settings.siteRoutingRules", "settings.siteSearchEntries",
        "settings.sponsorBlockCategoryOptions", "settings.sponsorBlockEnabled", "settings.startupLoadMode",
        "settings.tabLayout", "settings.tabManagementMode", "settings.tabOrganizerEnabled",
        "settings.themeTranslucency", "settings.tidyDownloads", "settings.topBarAddressView",
        "settings.urlShortcuts", "settings.warnBeforeHTTP", "settings.youTubeFrameThumbnails",
        "settings.youTubeHiddenHomeSections", "settings.youTubeHideShorts", "settings.youTubeNoHoverPreview",
        "settings.youTubeVideosPerRow",
    ]

    private enum StoreState: String, Codable { case pending, copying, validated, committed }

    private enum Format { case swiftData, sqlite(table: String), tabs, boosts, downloads, aiConfiguration, settings }

    private struct Store {
        let id: String
        let displayName: String
        let source: URL?
        let destination: String
        let format: Format
    }

    private struct Journal: Codable {
        var fingerprint: String
        var commitStarted = false
        var states: [String: StoreState]
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "DataConversion")
    private static let margin: Int64 = 100 * 1024 * 1024
    // SQLite rebuilds -shm from these on open, and opening the source would rewrite its -shm.
    private static let databaseFileSuffixes = ["", "-wal", "-journal"]

    private let fm = FileManager.default
    let environment: Environment

    init(environment: Environment) { self.environment = environment }

    init?(configuration: ChromiumStartupConfiguration) {
        guard let support = configuration.legacySupport else { return nil }
        let synthetic = support.deletingLastPathComponent()
        let isSynthetic = configuration.isVerification
        self.init(environment: Environment(
            root: configuration.root, legacySupport: support, preferencesDomain: configuration.preferencesDomain,
            isLegacyAppRunning: {
                isSynthetic ? FileManager.default.fileExists(atPath: synthetic.appendingPathComponent("writer-running").path)
                    : !NSRunningApplication.runningApplications(withBundleIdentifier: Self.legacyBundleID).isEmpty
            },
            availableSpace: {
                try configuration.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? 0
            },
            legacyPreferences: {
                guard isSynthetic else { return UserDefaults.standard.persistentDomain(forName: Self.legacyBundleID) }
                let file = synthetic.appendingPathComponent("Preferences/\(Self.legacyBundleID).plist")
                return (try? PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)) as? [String: Any]
            }))
    }

    // MARK: - Paths

    private var app: URL { environment.root.appendingPathComponent("App", isDirectory: true) }
    private var staging: URL { environment.root.appendingPathComponent("App.conversion", isDirectory: true) }
    private var journalURL: URL { staging.appendingPathComponent("journal.json") }
    private var stagedRoot: URL { staging.appendingPathComponent("staged", isDirectory: true) }
    private var scratchRoot: URL { staging.appendingPathComponent("scratch", isDirectory: true) }
    private var marker: URL { environment.root.appendingPathComponent("data-conversion.json") }
    private var legacyData: URL { environment.legacySupport.appendingPathComponent(Self.legacyBundleID, isDirectory: true) }

    private var allStores: [Store] {
        let data = legacyData
        return [
            Store(id: "appData", displayName: "profiles and history", source: data.appendingPathComponent("default.store"),
                  destination: "default.store", format: .swiftData),
            Store(id: "tabs", displayName: "tabs", source: data.appendingPathComponent("Tabs", isDirectory: true),
                  destination: "Tabs", format: .tabs),
            Store(id: "historyIndex", displayName: "history index", source: data.appendingPathComponent("History/history-index.sqlite"),
                  destination: "History/history-index.sqlite", format: .sqlite(table: "visits")),
            Store(id: "pageText", displayName: "page text history", source: data.appendingPathComponent("History/page-text.sqlite"),
                  destination: "History/page-text.sqlite", format: .sqlite(table: "pages")),
            Store(id: "boosts", displayName: "Boosts", source: data.appendingPathComponent("Boosts.json"),
                  destination: "Boosts.json", format: .boosts),
            Store(id: "downloads", displayName: "downloads list", source: data.appendingPathComponent("Downloads.json"),
                  destination: "Downloads.json", format: .downloads),
            Store(id: "aiConfig", displayName: "AI settings",
                  source: environment.legacySupport.appendingPathComponent("Nook/ai_config.json"),
                  destination: "ai_config.json", format: .aiConfiguration),
            Store(id: "settings", displayName: "settings", source: nil, destination: "settings.plist", format: .settings),
        ]
    }

    private func staged(_ store: Store) -> URL { stagedRoot.appendingPathComponent(store.destination) }

    private func allowedLegacyPreferences() -> [String: Any] {
        (environment.legacyPreferences() ?? [:]).filter { Self.allowedPreferences.contains($0.key) }
    }

    private func availableStores() -> [Store] {
        allStores.filter { store in
            guard let source = store.source else { return !allowedLegacyPreferences().isEmpty }
            return fm.fileExists(atPath: source.path)
        }
    }

    // MARK: - Decision

    func shouldOffer() -> Bool {
        if fm.fileExists(atPath: marker.path) {
            if markerOutcome() != "startedFresh" || (try? removeConverted()) != nil {
                try? fm.removeItem(at: staging)
            }
            return false
        }
        let data = legacyData
        return fm.fileExists(atPath: data.appendingPathComponent("default.store").path)
            || fm.fileExists(atPath: data.appendingPathComponent("Tabs/structure.json").path)
            || (fm.fileExists(atPath: data.path) && access(data.path, R_OK | X_OK) != 0)
    }

    func requiredSpace() throws -> Int64 {
        var bytes: Int64 = 0
        for store in availableStores() {
            for file in try sourceFiles(store) {
                bytes += (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return bytes * 2 + Self.margin
    }

    // MARK: - Conversion

    func convert() throws {
        do {
            try performConversion()
            Self.log.notice("data conversion finished outcome=converted")
        } catch {
            let failure = Self.classify(error)
            Self.log.error("data conversion failed reason=\(String(describing: failure), privacy: .public)")
            throw failure
        }
    }

    func startFresh() throws {
        do {
            try writeMarker("startedFresh")
            try environment.checkpoint("fresh.marker")
            try removeConverted()
            try? fm.removeItem(at: staging)
            Self.log.notice("data conversion finished outcome=startedFresh")
        } catch {
            let failure = Self.classify(error)
            Self.log.error("data conversion failed reason=\(String(describing: failure), privacy: .public)")
            throw failure
        }
    }

    /// Removes only what this conversion placed; a same-named entry that is still staged is not ours.
    private func removeConverted() throws {
        guard let journal = readJournal(), journal.commitStarted else { return }
        for store in allStores where journal.states[store.id] != nil {
            if case .settings = store.format {
                clearDestinationPreferences()
            } else if journal.states[store.id] == .committed || !fm.fileExists(atPath: staged(store).path) {
                let destination = app.appendingPathComponent(store.destination)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            }
        }
        rmdir(app.appendingPathComponent("History").path)
    }

    private func performConversion() throws {
        let available = availableStores()
        let existing = readJournal()
        try preflight(available, journal: existing)
        let fingerprint = try fingerprint(of: available)

        var journal: Journal
        if let existing, existing.commitStarted || existing.fingerprint == fingerprint {
            journal = existing
        } else {
            try? fm.removeItem(at: staging)
            journal = Journal(fingerprint: fingerprint,
                              states: Dictionary(uniqueKeysWithValues: available.map { ($0.id, StoreState.pending) }))
        }
        try fm.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        try save(journal)

        if !journal.commitStarted {
            for store in available where journal.states[store.id] != .validated {
                try stage(store, &journal)
            }
            if environment.isLegacyAppRunning() { throw Failure.legacyAppRunning }
            guard try self.fingerprint(of: available) == journal.fingerprint else { throw Failure.sourceChanged }
            journal.commitStarted = true
            try save(journal)
        }
        try environment.checkpoint("staged")
        for store in allStores where journal.states[store.id] != nil {
            try commit(store, &journal)
        }
        try writeMarker("converted")
        try environment.checkpoint("marker")
        try? fm.removeItem(at: staging)
    }

    // MARK: - Preflight

    private func preflight(_ stores: [Store], journal: Journal?) throws {
        if environment.isLegacyAppRunning() { throw Failure.legacyAppRunning }
        try checkSourceReadable(stores)
        try checkDestinationUnoccupied(journal)
        let required = try requiredSpace()
        let available = try environment.availableSpace()
        if available < required { throw Failure.insufficientSpace(required: required, available: available) }
    }

    private func checkSourceReadable(_ stores: [Store]) throws {
        for store in allStores {
            guard let parent = store.source?.deletingLastPathComponent() else { continue }
            if fm.fileExists(atPath: parent.path), access(parent.path, R_OK | X_OK) != 0 {
                throw Failure.sourceUnreadable(store.displayName)
            }
        }
        for store in stores {
            guard let source = store.source else { continue }
            do {
                for file in [source] + (try sourceFiles(store)) {
                    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
                    guard descriptor >= 0 else { throw POSIXError(.EACCES) }
                    close(descriptor)
                }
            } catch {
                throw Failure.sourceUnreadable(store.displayName)
            }
        }
    }

    /// While the offer is unanswered nothing else opens the destination, so once a commit has
    /// started, entries at the journal's own paths are this conversion's.
    private func checkDestinationUnoccupied(_ journal: Journal?) throws {
        let committing = journal?.commitStarted == true
        let ours = committing ? Set(allStores.filter { journal?.states[$0.id] != nil }
            .compactMap { $0.destination.split(separator: "/").first.map(String.init) }) : []
        let entries = (try? fm.contentsOfDirectory(atPath: app.path)) ?? []
        if entries.contains(where: { $0 != ".DS_Store" && !ours.contains($0) }) { throw Failure.destinationOccupied }
        if !committing, !destinationPreferences().isEmpty { throw Failure.destinationOccupied }
    }

    private func sourceFiles(_ store: Store) throws -> [URL] {
        guard let source = store.source else { return [] }
        switch store.format {
        case .swiftData, .sqlite:
            return Self.databaseFileSuffixes.map { URL(fileURLWithPath: source.path + $0) }
                .filter { fm.fileExists(atPath: $0.path) }
        default:
            return try regularFiles(below: source)
        }
    }

    private func regularFiles(below url: URL) throws -> [URL] {
        switch try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType {
        case .typeRegular?:
            return [url]
        case .typeDirectory?:
            return try fm.contentsOfDirectory(atPath: url.path).sorted()
                .flatMap { try regularFiles(below: url.appendingPathComponent($0)) }
        default:
            return []
        }
    }

    private func fingerprint(of stores: [Store]) throws -> String {
        var hash = SHA256()
        for store in stores {
            for file in try sourceFiles(store) {
                let attributes = try fm.attributesOfItem(atPath: file.path)
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                hash.update(data: Data("\(file.path)|\(attributes[.size] ?? 0)|\(modified)".utf8))
            }
        }
        for (key, value) in allowedLegacyPreferences().sorted(by: { $0.key < $1.key }) {
            hash.update(data: Data(key.utf8))
            hash.update(data: try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Staging

    private func stage(_ store: Store, _ journal: inout Journal) throws {
        journal.states[store.id] = .copying
        try save(journal)
        let target = staged(store)
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copy(store, to: target)
        try environment.checkpoint("\(store.id).copying")
        try validate(store, at: target)
        try flush(target)
        journal.states[store.id] = .validated
        try save(journal)
        try environment.checkpoint("\(store.id).validated")
    }

    private func copy(_ store: Store, to target: URL) throws {
        switch store.format {
        case .swiftData, .sqlite:
            try snapshotDatabase(store, to: target)
        case .tabs:
            guard let source = store.source else { return }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in try regularFiles(below: source) {
                let copy = target.appendingPathComponent(String(file.path.dropFirst(source.path.count + 1)))
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: copy)
            }
        case .boosts, .downloads:
            guard let source = store.source else { return }
            try Data(contentsOf: source).write(to: target, options: .atomic)
        case .aiConfiguration:
            guard let source = store.source else { return }
            let data = try Data(contentsOf: source)
            guard let configuration = try? JSONDecoder().decode(AIConfiguration.self, from: data) else {
                throw Failure.validationFailed(store.displayName)
            }
            try JSONEncoder().encode(configuration).write(to: target, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        case .settings:
            try PropertyListSerialization.data(fromPropertyList: allowedLegacyPreferences(), format: .binary, options: 0)
                .write(to: target, options: .atomic)
        }
    }

    private func snapshotDatabase(_ store: Store, to target: URL) throws {
        guard let source = store.source else { return }
        let scratch = scratchRoot.appendingPathComponent(store.id, isDirectory: true)
        try? fm.removeItem(at: scratch)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratchRoot) }
        for suffix in Self.databaseFileSuffixes.dropFirst() { try? fm.removeItem(atPath: target.path + suffix) }
        let database = scratch.appendingPathComponent(source.lastPathComponent)
        for suffix in Self.databaseFileSuffixes where fm.fileExists(atPath: source.path + suffix) {
            try fm.copyItem(atPath: source.path + suffix, toPath: database.path + suffix)
        }

        var from: OpaquePointer?, to: OpaquePointer?
        defer {
            sqlite3_close_v2(from)
            sqlite3_close_v2(to)
        }
        guard sqlite3_open_v2(database.path, &from, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_open_v2(target.path, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(to, "main", from, "main") else {
            throw Failure.validationFailed(store.displayName)
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        if step == SQLITE_FULL || finish == SQLITE_FULL { throw Failure.diskFull }
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.validationFailed(store.displayName) }
    }

    private func flush(_ url: URL) throws {
        for file in try regularFiles(below: url) {
            let descriptor = open(file.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            _ = fcntl(descriptor, F_FULLFSYNC)
        }
    }

    // MARK: - Validation

    private func validate(_ store: Store, at target: URL) throws {
        let invalid = Failure.validationFailed(store.displayName)
        switch store.format {
        case .swiftData:
            try validateAppStore(at: target, invalid: invalid)
        case .sqlite(let table):
            try validateDatabase(at: target, table: table, invalid: invalid)
        case .tabs:
            // Loading writes a dated backup beside the files, so it runs on a throwaway copy.
            let scratch = try scratchCopy(of: target)
            defer { try? fm.removeItem(at: scratchRoot) }
            if case .readOnly = TabStore(directory: scratch).load().outcome { throw invalid }
        case .boosts:
            guard (try? JSONDecoder().decode(LossyBoosts.self, from: Data(contentsOf: target))) != nil else { throw invalid }
        case .downloads:
            guard (try? JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: target))) != nil else { throw invalid }
        case .aiConfiguration:
            guard (try? JSONDecoder().decode(AIConfiguration.self, from: Data(contentsOf: target))) != nil else { throw invalid }
        case .settings:
            try validateSettings(at: target, invalid: invalid)
        }
    }

    private func validateAppStore(at target: URL, invalid: Failure) throws {
        let scratch = try scratchCopy(of: target)
        defer { try? fm.removeItem(at: scratchRoot) }
        do {
            try onMain {
                try autoreleasepool {
                    let context = ModelContext(try Persistence(directory: scratch.deletingLastPathComponent()).container)
                    var sample = FetchDescriptor<HistoryEntity>()
                    sample.fetchLimit = 1
                    _ = try context.fetch(FetchDescriptor<ProfileEntity>())
                    _ = try context.fetch(sample)
                }
            }
        } catch {
            throw invalid
        }
    }

    private func validateDatabase(at target: URL, table: String, invalid: Failure) throws {
        let scratch = try scratchCopy(of: target)
        defer { try? fm.removeItem(at: scratchRoot) }
        var database: OpaquePointer?
        defer { sqlite3_close_v2(database) }
        guard sqlite3_open_v2(scratch.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw invalid }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok",
              sqlite3_exec(database, "SELECT 1 FROM \(table) LIMIT 1", nil, nil, nil) == SQLITE_OK else { throw invalid }
    }

    private func validateSettings(at target: URL, invalid: Failure) throws {
        guard let values = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: target), format: nil)) as? [String: Any] else {
            throw invalid
        }
        let domain = environment.preferencesDomain + ".conversion-probe"
        try fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratchRoot) }
        let boosts = BoostStore(fileURL: scratchRoot.appendingPathComponent("probe-boosts.json"))
        let searchEngine: String? = try onMain {
            guard let probe = UserDefaults(suiteName: domain) else { throw invalid }
            probe.setPersistentDomain(values, forName: domain)
            defer { probe.removePersistentDomain(forName: domain) }
            return NookSettingsService(kagiTokenStore: NoKagiTokens(), userDefaults: probe, boostStore: boosts).searchEngineId
        }
        if let expected = values["settings.searchEngine"] as? String, expected != searchEngine { throw invalid }
    }

    private func scratchCopy(of url: URL) throws -> URL {
        try? fm.removeItem(at: scratchRoot)
        try fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let copy = scratchRoot.appendingPathComponent(url.lastPathComponent)
        try fm.copyItem(at: url, to: copy)
        return copy
    }

    private func onMain<T: Sendable>(_ work: @MainActor () throws -> T) throws -> T {
        try DispatchQueue.main.sync { try MainActor.assumeIsolated(work) }
    }

    // MARK: - Commit

    private func commit(_ store: Store, _ journal: inout Journal) throws {
        guard journal.states[store.id] != .committed else { return }
        if case .settings = store.format {
            guard let values = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: staged(store)), format: nil)) as? [String: Any] else {
                throw Failure.interrupted
            }
            try writeDestinationPreferences(values)
        } else {
            let destination = app.appendingPathComponent(store.destination)
            if fm.fileExists(atPath: staged(store).path) {
                if fm.fileExists(atPath: destination.path) { throw Failure.destinationOccupied }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staged(store), to: destination)
            } else if !fm.fileExists(atPath: destination.path) {
                throw Failure.interrupted
            }
        }
        try environment.checkpoint("\(store.id).committing")
        journal.states[store.id] = .committed
        try save(journal)
        try environment.checkpoint("\(store.id).committed")
    }

    private func destinationPreferences() -> [String: Any] {
        UserDefaults(suiteName: environment.preferencesDomain)?.persistentDomain(forName: environment.preferencesDomain) ?? [:]
    }

    private func writeDestinationPreferences(_ values: [String: Any]) throws {
        let domain = environment.preferencesDomain
        guard let defaults = UserDefaults(suiteName: domain) else { throw Failure.failed("preferences") }
        defaults.setPersistentDomain(values, forName: domain)
        defaults.synchronize()
        guard NSDictionary(dictionary: destinationPreferences()).isEqual(to: values) else { throw Failure.failed("preferences") }
    }

    private func clearDestinationPreferences() {
        let domain = environment.preferencesDomain
        guard let defaults = UserDefaults(suiteName: domain) else { return }
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
    }

    // MARK: - Journal and marker

    private func readJournal() -> Journal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? JSONDecoder().decode(Journal.self, from: data)
    }

    private func markerOutcome() -> String? {
        guard let data = try? Data(contentsOf: marker),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return values["outcome"] as? String
    }

    private func save(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private func writeMarker(_ outcome: String) throws {
        try JSONSerialization.data(withJSONObject: ["outcome": outcome]).write(to: marker, options: .atomic)
        try flush(marker)
    }

    private static func classify(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        let error = error as NSError
        let isFull = (error.domain == NSPOSIXErrorDomain && Int32(error.code) == ENOSPC)
            || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
        return isFull ? .diskFull : .failed("\(error.domain) \(error.code)")
    }
}

private final class NoKagiTokens: KagiTokenStore, @unchecked Sendable {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@MainActor
@Observable
final class ChromiumDataConversionFlow {
    struct MenuBar {
        var get: @MainActor () -> NSMenu?
        var set: @MainActor (NSMenu?) -> Void
    }

    enum Phase: Equatable { case offer, running, failed(String) }
    private(set) var phase = Phase.offer
    private let conversion: ChromiumDataConversion
    private let menuBar: MenuBar
    private let stockMenu: NSMenu?
    private let finished: @MainActor () -> Void

    init(conversion: ChromiumDataConversion, menuBar: MenuBar, finished: @escaping @MainActor () -> Void) {
        self.conversion = conversion
        self.menuBar = menuBar
        self.finished = finished
        stockMenu = menuBar.get()
        menuBar.set(Self.noticeMenu())
    }

    /// With no model window yet, Chromium's stock commands either queue a window for after
    /// startup (New Window) or create a browser at once (New Tab, New Incognito Window).
    private static func noticeMenu() -> NSMenu {
        let applicationMenu = NSMenu()
        applicationMenu.addItem(NSMenuItem(title: "Quit \(ProcessInfo.processInfo.processName)",
                                           action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let item = NSMenuItem()
        item.submenu = applicationMenu
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }

    func convert() { perform { [conversion] in try conversion.convert() } }

    func startFresh() { perform { [conversion] in try conversion.startFresh() } }

    private func perform(_ work: @escaping () throws -> Void) {
        guard phase != .running else { return }
        phase = .running
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: ChromiumDataConversion.Failure?
            do {
                try work()
                failure = nil
            } catch {
                failure = error as? ChromiumDataConversion.Failure ?? .failed("unknown")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failure {
                        self.phase = .failed(failure.message)
                    } else {
                        self.menuBar.set(self.stockMenu)
                        self.finished()
                    }
                }
            }
        }
    }
}
