import AppKit
import Darwin
import Foundation
import NookSettings
import NookTabsCore
import SQLite3
import SwiftData

// Statically linked NookSettings resolves its Keychain calls here, so any access traps.
@_cdecl("SecItemCopyMatching") func trappedCopy(_: CFDictionary, _: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { fatalError("Keychain opened") }
@_cdecl("SecItemAdd") func trappedAdd(_: CFDictionary, _: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { fatalError("Keychain opened") }
@_cdecl("SecItemUpdate") func trappedUpdate(_: CFDictionary, _: CFDictionary) -> OSStatus { fatalError("Keychain opened") }
@_cdecl("SecItemDelete") func trappedDelete(_: CFDictionary) -> OSStatus { fatalError("Keychain opened") }

private let fm = FileManager.default
private let destinationDomain = "ee.qdo.nook.chromium-conversion-test"
private let secretMark = "FAKE-SECRET"

private func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String,
                   file: StaticString = #fileID, line: UInt = #line) {
    if !condition() {
        print("FAIL \(file):\(line): \(message())")
        exit(1)
    }
}

private enum IDs {
    static let personal = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    static let work = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
    static let workNotes = UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!
    static let kept = UUID(uuidString: "A0000000-0000-4000-8000-000000000004")!
    static let personalTab = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
    static let favorite = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!
    static let pinned = UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!
    static let outerFolder = UUID(uuidString: "B0000000-0000-4000-8000-000000000004")!
    static let innerFolder = UUID(uuidString: "B0000000-0000-4000-8000-000000000005")!
    static let nestedTab = UUID(uuidString: "B0000000-0000-4000-8000-000000000006")!
    static let window = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!
    static let walOnlyVisit = UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!
    static let boost = UUID(uuidString: "E0000000-0000-4000-8000-000000000001")!
    static let engine = UUID(uuidString: "E0000000-0000-4000-8000-000000000002")!
    static let historyRows = 4
}

// MARK: - Fixture

private enum Fixture {
    static func sourceData(_ base: URL) -> URL { base.appendingPathComponent("Application Support/ee.qdo.nook", isDirectory: true) }
    static func sourceConfig(_ base: URL) -> URL { base.appendingPathComponent("Application Support/Nook", isDirectory: true) }

    /// Live SQLite files are copied while their writers hold them open, so rows sit only in the WAL.
    @MainActor static func build(at base: URL) async throws {
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let data = sourceData(base), config = sourceConfig(base)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: config, withIntermediateDirectories: true)

        let live = base.appendingPathComponent(".live", isDirectory: true)
        let persistence = try Persistence(directory: live)
        let context = ModelContext(persistence.container)
        context.insert(ProfileEntity(id: IDs.personal, name: "Personal", index: 0))
        context.insert(ProfileEntity(id: IDs.work, name: "Work", index: 1))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(HistoryEntity(url: "https://personal.invalid/one", title: "Personal one", visitDate: date, lastVisited: date, profileId: IDs.personal))
        context.insert(HistoryEntity(url: "https://work.invalid/one", title: "Work one", visitDate: date, lastVisited: date, profileId: IDs.work))
        context.insert(HistoryEntity(url: "https://work.invalid/two", title: "Work two", visitDate: date, lastVisited: date, profileId: IDs.work))
        context.insert(HistoryEntity(id: IDs.walOnlyVisit, url: "https://work.invalid/wal", title: "WAL only", visitDate: date, lastVisited: date, profileId: IDs.work))
        try context.save()
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            try fm.copyItem(at: live.appendingPathComponent(name), to: data.appendingPathComponent(name))
        }
        let walSize = (try fm.attributesOfItem(atPath: data.appendingPathComponent("default.store-wal").path)[.size] as? Int) ?? 0
        check(walSize > 0, "fixture store has no WAL state")

        let historyDirectory = data.appendingPathComponent("History", isDirectory: true)
        try fm.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let liveIndex = live.appendingPathComponent("history-index.sqlite")
        let index = HistoryIndex(fileURL: liveIndex, halfLife: 864_000)
        _ = await index.needsMigration()
        await index.migrate([])
        await index.record(url: "https://work.invalid/indexed", title: "Indexed work page", profile: IDs.work, at: date, weight: 1)
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: liveIndex.path + suffix) {
            try fm.copyItem(atPath: liveIndex.path + suffix, toPath: historyDirectory.appendingPathComponent("history-index.sqlite" + suffix).path)
        }
        let liveText = live.appendingPathComponent("page-text.sqlite")
        await HistoryTextIndex(fileURL: liveText).record(url: "https://work.invalid/indexed", title: "Indexed work page", body: "synthetic marmalade body", visitedAt: date)
        try fm.copyItem(at: liveText, to: historyDirectory.appendingPathComponent("page-text.sqlite"))
        withExtendedLifetime((persistence, index)) {}

        let order = OrderKey.sequence(count: 6)
        let tree = TabTree(
            spaces: [
                SpaceRecord(id: IDs.personal, name: "Personal", icon: "house", accentHex: "#111111", order: order[0], modifiedAt: date),
                SpaceRecord(id: IDs.work, name: "Work", icon: "briefcase", accentHex: "#222222", order: order[1], modifiedAt: date, profileName: "Work"),
                SpaceRecord(id: IDs.workNotes, name: "Work Notes", icon: "note", accentHex: "#333333", order: order[2], modifiedAt: date, dataStoreID: IDs.work, profileName: "Work"),
            ],
            items: [
                Item(id: IDs.personalTab, parent: .tabs(spaceID: IDs.personal), order: order[0], kind: .tab(url: URL(string: "https://personal.invalid/tab")!, pageTitle: "Personal tab"), modifiedAt: date),
                Item(id: IDs.favorite, parent: .favorites(spaceID: IDs.personal), order: order[1], kind: .tab(url: URL(string: "https://personal.invalid/favorite")!, pageTitle: "Favorite"), modifiedAt: date),
                Item(id: IDs.pinned, parent: .pinned(spaceID: IDs.work), order: order[2], kind: .tab(url: URL(string: "https://work.invalid/pinned")!, pageTitle: "Pinned"), customTitle: "Pinned name", modifiedAt: date),
                Item(id: IDs.outerFolder, parent: .pinned(spaceID: IDs.workNotes), order: order[3], kind: .folder, customTitle: "Outer", modifiedAt: date),
                Item(id: IDs.innerFolder, parent: .folder(itemID: IDs.outerFolder), order: order[4], kind: .folder, customTitle: "Inner", modifiedAt: date),
                Item(id: IDs.nestedTab, parent: .folder(itemID: IDs.innerFolder), order: order[5], kind: .tab(url: URL(string: "https://work.invalid/nested")!, pageTitle: "Nested"), modifiedAt: date),
            ])
        var device = DeviceState()
        device.firstLaunchCompleted = true
        device.windows = [WindowRecord(id: IDs.window, spaceID: IDs.workNotes, selectedItemBySpace: [IDs.workNotes: IDs.nestedTab], frame: "{{10, 20}, {800, 600}}")]
        device.keptProfiles = [KeptProfile(id: IDs.kept, name: "Kept")]
        let store = TabStore(directory: data.appendingPathComponent("Tabs", isDirectory: true))
        store.save(tree, device)
        store.flush()
        let backup = data.appendingPathComponent("Tabs/Backups/2026-11-01", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.copyItem(at: data.appendingPathComponent("Tabs/structure.json"), to: backup.appendingPathComponent("structure.json"))

        BoostStore.write([Boost(id: IDs.boost, name: "Synthetic", host: "synthetic.invalid")], to: data.appendingPathComponent("Boosts.json"))

        let downloaded = data.appendingPathComponent("synthetic-download.bin")
        try Data("synthetic".utf8).write(to: downloaded)
        let records = [DownloadRecord(originalURL: URL(string: "https://work.invalid/file")!, path: downloaded.path, date: date, size: 9, renamedFrom: nil, profileID: IDs.work)]
        try JSONEncoder().encode(records).write(to: data.appendingPathComponent("Downloads.json"))

        var ai = AIConfiguration(
            providers: [AIProviderConfig(id: "openai", displayName: "OpenAI", providerType: .openAI)],
            models: [], activeProviderId: "openai",
            mcpServers: [MCPServerConfig(id: "mcp", name: "Synthetic MCP", transport: .sse(url: "https://mcp.invalid"))])
        ai.translationProviderId = "openai"
        var aiJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ai)) as! [String: Any]
        var providers = aiJSON["providers"] as! [[String: Any]]
        providers[0]["apiKey"] = secretMark + "-plaintext-provider-key"
        aiJSON["providers"] = providers
        aiJSON["apiKey"] = secretMark + "-plaintext-top-level-key"
        try JSONSerialization.data(withJSONObject: aiJSON).write(to: config.appendingPathComponent("ai_config.json"))

        let engines = try JSONEncoder().encode([CustomSearchEngine(id: IDs.engine, name: "Synthetic", urlTemplate: "https://search.invalid/?q=%@")])
        let preferences: [String: Any] = [
            "settings.searchEngine": IDs.engine.uuidString,
            "settings.customSearchEngines": engines,
            "settings.tabLayout": TabLayout.topOfWindow.rawValue,
            "settings.askBeforeQuit": false,
            "settings.archiveTabsAfterHours": 24,
            "settings.didFinishOnboarding": true,
            "keyboard.shortcuts": Data("[]".utf8),
            "sidebarWidth": 321.0,
            "settings.geminiApiKey": secretMark + "-gemini",
            "settings.openRouterApiKey": secretMark + "-openrouter",
            "settings.sitePermissions": Data((secretMark + "-site-permissions").utf8),
            "settings.pinnedExtensionIDs": Data((secretMark + "-extensions").utf8),
            "security.acceptedCertificateExceptions": ["host": secretMark + "-certificate"],
            "Nook.WKWebExtensionController.Identifier": secretMark + "-controller",
            "SUEnableAutomaticChecks": true,
            "CKSyncState": secretMark + "-cloudkit",
            "UnknownFutureKey": secretMark + "-unknown",
        ]
        let preferenceFile = base.appendingPathComponent("Preferences/ee.qdo.nook.plist")
        try fm.createDirectory(at: preferenceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0).write(to: preferenceFile)

        let decoys = [
            data.appendingPathComponent("SessionCookies/\(IDs.work.uuidString).plist"),
            data.appendingPathComponent("Sync/spaces.json"),
            data.appendingPathComponent("dev-mcp-token"),
            data.appendingPathComponent("ContentBlocker/FilterLists/list.txt"),
            data.appendingPathComponent("TranslationCache/\(IDs.work.uuidString).sqlite"),
            data.appendingPathComponent("Backups/default_backup_2026/default.store"),
            data.appendingPathComponent("ArcMembershipCard.json"),
            config.appendingPathComponent("Extensions/synthetic/manifest.json"),
            config.appendingPathComponent("NativeMessagingHosts/synthetic.json"),
            base.appendingPathComponent("WebKit/ee.qdo.nook/WebsiteDataStore/\(IDs.work.uuidString)/cookies"),
            base.appendingPathComponent("Caches/FaviconCache/icon"),
        ]
        for decoy in decoys {
            try fm.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(secretMark)-\(decoy.lastPathComponent)".utf8).write(to: decoy)
        }
        try fm.removeItem(at: live)
    }
}

// MARK: - Sandbox

/// A byte, type, mode and modification record of every entry below a root.
private func digest(_ root: URL) -> [String: String] {
    var result: [String: String] = [:]
    guard let walker = fm.enumerator(atPath: root.path) else { return result }
    while let relative = walker.nextObject() as? String {
        let path = root.appendingPathComponent(relative).path
        guard let attributes = try? fm.attributesOfItem(atPath: path) else { result[relative] = "unreadable"; continue }
        let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "?"
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = fm.contents(atPath: path).map { $0.base64EncodedString() } ?? ""
        result[relative] = "\(type)|\(mode)|\(modified)|\(bytes)"
    }
    return result
}

private func inode(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue }

private func clearDestinationPreferences() {
    let defaults = UserDefaults(suiteName: destinationDomain)!
    defaults.removePersistentDomain(forName: destinationDomain)
    defaults.synchronize()
}

private func destinationPreferences() -> [String: Any] {
    let defaults = UserDefaults(suiteName: destinationDomain)!
    defaults.synchronize()
    return defaults.persistentDomain(forName: destinationDomain) ?? [:]
}

private struct Sandbox {
    let base: URL
    let baseline: [String: String]
    var root: URL { base.appendingPathComponent("NookChromium", isDirectory: true) }
    var app: URL { root.appendingPathComponent("App", isDirectory: true) }
    var engine: URL { root.appendingPathComponent("Engine", isDirectory: true) }
    var staging: URL { root.appendingPathComponent("App.conversion", isDirectory: true) }
    var marker: URL { root.appendingPathComponent("data-conversion.json") }

    init(from fixture: URL, name: String) throws {
        base = fixture.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: base)
        try fm.copyItem(at: fixture, to: base)
        try fm.createDirectory(at: base.appendingPathComponent("NookChromium/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("NookChromium/Engine"), withIntermediateDirectories: true)
        try Data("engine".utf8).write(to: base.appendingPathComponent("NookChromium/Engine/Local State"))
        baseline = Sandbox.sourceDigest(base)
        clearDestinationPreferences()
    }

    static func sourceDigest(_ base: URL) -> [String: String] {
        var result: [String: String] = [:]
        for name in ["Application Support/ee.qdo.nook", "Application Support/Nook", "Preferences", "WebKit", "Caches"] {
            for (key, value) in digest(base.appendingPathComponent(name)) { result[name + "/" + key] = value }
        }
        return result
    }

    func assertSourceIntact(file: StaticString = #fileID, line: UInt = #line) {
        let now = Sandbox.sourceDigest(base)
        for key in Set(now.keys).union(baseline.keys) where now[key] != baseline[key] {
            check(false, "source changed at \(key)", file: file, line: line)
        }
    }

    func environment(running: @escaping () -> Bool = { false }, available: Int64 = .max,
                     checkpoint: @escaping (String) throws -> Void = { _ in }) -> ChromiumDataConversion.Environment {
        let preferenceFile = base.appendingPathComponent("Preferences/ee.qdo.nook.plist")
        return .init(root: root, legacySupport: base.appendingPathComponent("Application Support", isDirectory: true),
                     preferencesDomain: destinationDomain, isLegacyAppRunning: running,
                     availableSpace: { available },
                     legacyPreferences: {
                         (try? PropertyListSerialization.propertyList(from: Data(contentsOf: preferenceFile), format: nil)) as? [String: Any]
                     }, checkpoint: checkpoint)
    }

    func conversion(running: @escaping () -> Bool = { false }, available: Int64 = .max,
                    checkpoint: @escaping (String) throws -> Void = { _ in }) -> ChromiumDataConversion {
        ChromiumDataConversion(environment: environment(running: running, available: available, checkpoint: checkpoint))
    }
}

/// Validators hop to the main actor, as they do under Chromium's run loop.
private func run(_ work: @escaping () throws -> Void) async -> Error? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
        DispatchQueue.global().async {
            do { try work(); continuation.resume(returning: nil) } catch { continuation.resume(returning: error) }
        }
    }
}

private func failure(_ work: @escaping () throws -> Void, file: StaticString = #fileID, line: UInt = #line) async -> ChromiumDataConversion.Failure? {
    guard let error = await run(work) else { return nil }
    guard let failure = error as? ChromiumDataConversion.Failure else {
        check(false, "unexpected error \(error)", file: file, line: line)
        return nil
    }
    return failure
}

@MainActor private func waitFor(_ label: String, condition: () -> Bool, file: StaticString = #fileID, line: UInt = #line) async throws {
    let deadline = Date(timeIntervalSinceNow: 60)
    while !condition() {
        check(Date() < deadline, "timed out waiting for \(label)", file: file, line: line)
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

private func tree(_ root: URL) -> [String] {
    (fm.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
}

// MARK: - Assertions over the real stores

@MainActor
private func assertConverted(_ sandbox: Sandbox, file: StaticString = #fileID, line: UInt = #line) async throws {
    let app = sandbox.app
    check(fm.fileExists(atPath: sandbox.marker.path), "no completion marker", file: file, line: line)
    check(!fm.fileExists(atPath: sandbox.staging.path), "staging left behind", file: file, line: line)
    for sidecar in ["default.store-wal", "default.store-shm", "History/history-index.sqlite-wal", "History/history-index.sqlite-shm"] {
        check(!fm.fileExists(atPath: app.appendingPathComponent(sidecar).path), "sidecar committed: \(sidecar)", file: file, line: line)
    }
    check(digest(sandbox.engine).keys.sorted() == ["Local State"], "engine directory changed", file: file, line: line)

    for (relative, _) in digest(sandbox.root) {
        let path = sandbox.root.appendingPathComponent(relative).path
        if let bytes = fm.contents(atPath: path) {
            check(bytes.range(of: Data(secretMark.utf8)) == nil, "secret or excluded store reached \(relative)", file: file, line: line)
        }
    }
    let topLevel = Set(try fm.contentsOfDirectory(atPath: app.path))
    check(topLevel == ["default.store", "Tabs", "History", "Boosts.json", "Downloads.json", "ai_config.json"],
          "unexpected App contents: \(topLevel.sorted())", file: file, line: line)

    // A copy keeps later scenarios' inode and backup assertions independent of these loads.
    let inspection = app.deletingLastPathComponent().appendingPathComponent("Inspect-\(UUID().uuidString)", isDirectory: true)
    try fm.copyItem(at: app, to: inspection)
    defer { try? fm.removeItem(at: inspection) }

    let loaded = TabStore(directory: inspection.appendingPathComponent("Tabs", isDirectory: true)).load()
    check(loaded.outcome == .loaded, "tabs outcome \(loaded.outcome)", file: file, line: line)
    let profiles = loaded.tree.profiles
    check(Set(profiles.map(\.id)) == [IDs.personal, IDs.work], "profiles \(profiles.map(\.id))", file: file, line: line)
    check(Set(profiles.first { $0.id == IDs.work }?.spaceIDs ?? []) == [IDs.work, IDs.workNotes], "shared-profile spaces lost", file: file, line: line)
    check(loaded.tree.items[IDs.personalTab]?.parent == .tabs(spaceID: IDs.personal), "plain tab parent", file: file, line: line)
    check(loaded.tree.items[IDs.favorite]?.parent == .favorites(spaceID: IDs.personal), "favorite parent", file: file, line: line)
    check(loaded.tree.items[IDs.pinned]?.parent == .pinned(spaceID: IDs.work), "pinned parent", file: file, line: line)
    check(loaded.tree.items[IDs.pinned]?.customTitle == "Pinned name", "pinned custom title", file: file, line: line)
    check(loaded.tree.items[IDs.outerFolder]?.parent == .pinned(spaceID: IDs.workNotes), "outer folder parent", file: file, line: line)
    check(loaded.tree.items[IDs.innerFolder]?.parent == .folder(itemID: IDs.outerFolder), "inner folder parent", file: file, line: line)
    check(loaded.tree.items[IDs.nestedTab]?.parent == .folder(itemID: IDs.innerFolder), "nested tab parent", file: file, line: line)
    check(loaded.tree.items.count == 6, "tab records duplicated or lost: \(loaded.tree.items.count)", file: file, line: line)
    check(loaded.device.windows.first?.id == IDs.window && loaded.device.windows.first?.spaceID == IDs.workNotes, "window record", file: file, line: line)
    check(loaded.device.keptProfiles?.map(\.id) == [IDs.kept], "kept profile", file: file, line: line)
    check(fm.fileExists(atPath: app.appendingPathComponent("Tabs/Backups/2026-11-01/structure.json").path), "tab backups", file: file, line: line)

    let persistence = try Persistence(directory: inspection)
    let context = ModelContext(persistence.container)
    let storedProfiles = try context.fetch(FetchDescriptor<ProfileEntity>(sortBy: [SortDescriptor(\.index)]))
    check(storedProfiles.map(\.id) == [IDs.personal, IDs.work], "stored profiles", file: file, line: line)
    let visits = try context.fetch(FetchDescriptor<HistoryEntity>())
    check(visits.count == IDs.historyRows, "history rows \(visits.count)", file: file, line: line)
    check(visits.contains { $0.id == IDs.walOnlyVisit && $0.profileId == IDs.work }, "WAL-only row lost", file: file, line: line)
    check(visits.filter { $0.profileId == IDs.personal }.count == 1, "history profile boundary", file: file, line: line)

    let indexed = await HistoryIndex(fileURL: inspection.appendingPathComponent("History/history-index.sqlite"), halfLife: 864_000)
        .search("Indexed", profile: IDs.work)
    check(indexed?.first?.url == "https://work.invalid/indexed", "history index \(String(describing: indexed))", file: file, line: line)
    let text = await HistoryTextIndex(fileURL: inspection.appendingPathComponent("History/page-text.sqlite")).search("marmalade", limit: 5)
    check(text.first?.url == "https://work.invalid/indexed", "page text \(text)", file: file, line: line)

    check(BoostStore.read(from: inspection.appendingPathComponent("Boosts.json"), legacy: nil).map(\.id) == [IDs.boost], "boosts", file: file, line: line)
    let records = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: inspection.appendingPathComponent("Downloads.json")))
    check(records.map(\.profileID) == [IDs.work] && records.first?.size == 9, "download records", file: file, line: line)

    let aiData = try Data(contentsOf: app.appendingPathComponent("ai_config.json"))
    let ai = try JSONDecoder().decode(AIConfiguration.self, from: aiData)
    check(ai.activeProviderId == "openai" && ai.mcpServers.map(\.id) == ["mcp"] && ai.translationProviderId == "openai", "AI config", file: file, line: line)
    let aiMode = try fm.attributesOfItem(atPath: app.appendingPathComponent("ai_config.json").path)[.posixPermissions] as? NSNumber
    check(aiMode?.intValue == 0o600, "AI config mode \(String(describing: aiMode))", file: file, line: line)

    let stored = destinationPreferences()
    check(stored["settings.searchEngine"] as? String == IDs.engine.uuidString, "search engine preference", file: file, line: line)
    check(Set(stored.keys).isSubset(of: ChromiumDataConversion.allowedPreferences), "unlisted preference: \(stored.keys.sorted())", file: file, line: line)
    for key in stored.keys { check(!"\(stored[key]!)".contains(secretMark), "secret preference \(key)", file: file, line: line) }
    let defaults = UserDefaults(suiteName: destinationDomain)!
    let inspectionBoosts = BoostStore(fileURL: inspection.appendingPathComponent("Boosts.json"))
    let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults, boostStore: inspectionBoosts)
    check(settings.searchEngineId == IDs.engine.uuidString, "service search engine", file: file, line: line)
    check(settings.customSearchEngines.map(\.id) == [IDs.engine], "service custom engines", file: file, line: line)
    check(settings.tabLayout == .topOfWindow, "service tab layout", file: file, line: line)
    check(!settings.askBeforeQuit && settings.archiveTabsAfterHours == 24, "service scalars", file: file, line: line)
    defaults.removeObject(forKey: "settings.removeTrackingFromLinks")
    withExtendedLifetime(persistence) {}
}

private final class NoTokens: KagiTokenStore, @unchecked Sendable {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@MainActor private final class StartupBridge: ChromiumStartupBridge {
    var ready: (@MainActor () -> Void)?
    var opened = 0
    func registerReady(_ callback: @escaping @MainActor () -> Void) { ready = callback }
    func openProfile(_ id: UUID?, completion: @escaping @MainActor (Int32?) -> Void) { opened += 1 }
    func attachShell(to window: Int32, completion: @escaping @MainActor (Int32?) -> Void) {}
    func completeStartup(_ window: Int32) {}
}

// MARK: - Scenarios

private let scenarioStores = ["appData", "tabs", "historyIndex", "pageText", "boosts", "downloads", "aiConfig", "settings"]

/// Child mode: converts until the named checkpoint, then dies the way a crash does.
private func runChild(base: URL, crashAt: String) async -> Never {
    let sandbox = ChildSandbox(base: base)
    _ = await run {
        try ChromiumDataConversion(environment: sandbox.environment { name in
            if name == crashAt { kill(getpid(), SIGKILL) }
        }).convert()
    }
    print("child finished without reaching \(crashAt)")
    exit(3)
}

private struct ChildSandbox {
    let base: URL
    func environment(checkpoint: @escaping (String) throws -> Void) -> ChromiumDataConversion.Environment {
        let preferenceFile = base.appendingPathComponent("Preferences/ee.qdo.nook.plist")
        return .init(root: base.appendingPathComponent("NookChromium", isDirectory: true),
                     legacySupport: base.appendingPathComponent("Application Support", isDirectory: true),
                     preferencesDomain: destinationDomain, isLegacyAppRunning: { false }, availableSpace: { .max },
                     legacyPreferences: {
                         (try? PropertyListSerialization.propertyList(from: Data(contentsOf: preferenceFile), format: nil)) as? [String: Any]
                     }, checkpoint: checkpoint)
    }
}

@MainActor
private func killAndResume(fixture: URL, checkpoint: String) async throws {
    let sandbox = try Sandbox(from: fixture, name: "kill")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--child", sandbox.base.path, checkpoint]
    try child.run()
    child.waitUntilExit()
    check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,
          "child did not die at \(checkpoint): status \(child.terminationStatus)")
    sandbox.assertSourceIntact()
    if checkpoint == "marker" {
        check(fm.fileExists(atPath: sandbox.staging.path), "staging already gone at \(checkpoint)")
        check(!sandbox.conversion().shouldOffer(), "offered after the marker was written")
        try await assertConverted(sandbox)
        sandbox.assertSourceIntact()
        return
    }
    check(!fm.fileExists(atPath: sandbox.marker.path), "marker before completion at \(checkpoint)")
    check(sandbox.conversion().shouldOffer(), "interrupted conversion not offered again at \(checkpoint)")

    // Whatever already reached its final place must not be touched by the resumed run.
    var kept: [URL: Int] = [:]
    for top in (try? fm.contentsOfDirectory(at: sandbox.app, includingPropertiesForKeys: nil)) ?? [] {
        if let id = inode(top) { kept[top] = id }
    }
    let destinations = ["appData": "default.store", "tabs": "Tabs", "historyIndex": "History/history-index.sqlite",
                        "pageText": "History/page-text.sqlite", "boosts": "Boosts.json", "downloads": "Downloads.json", "aiConfig": "ai_config.json"]
    let validatedStore = checkpoint.hasSuffix(".validated") ? checkpoint.split(separator: ".").first.map(String.init) : nil
    let validatedPath = validatedStore.flatMap { destinations[$0] }
    let validatedInode = validatedPath.flatMap { inode(sandbox.staging.appendingPathComponent("staged").appendingPathComponent($0)) }
    if validatedPath != nil { check(validatedInode != nil, "validated store not staged at \(checkpoint)") }

    var seen: [String] = []
    let error = await failure { try sandbox.conversion(checkpoint: { seen.append($0) }).convert() }
    check(error == nil, "resume after \(checkpoint) failed: \(String(describing: error))")
    for (url, id) in kept {
        check(inode(url) == id, "committed \(url.lastPathComponent) rewritten after \(checkpoint)")
    }
    if let validatedStore {
        check(!seen.contains("\(validatedStore).copying"), "validated \(validatedStore) recopied after \(checkpoint)")
    }
    if let validatedPath {
        check(inode(sandbox.app.appendingPathComponent(validatedPath)) == validatedInode, "validated store replaced after \(checkpoint)")
    }
    try await assertConverted(sandbox)
    sandbox.assertSourceIntact()
    check(!sandbox.conversion().shouldOffer(), "offered after resume from \(checkpoint)")
}

@MainActor
private func scenarios(fixture: URL) async throws {
    let only = ProcessInfo.processInfo.environment["CONVERSION_SCENARIO"]
    func selected(_ name: String) -> Bool {
        guard only == nil || only == name else { return false }
        print("scenario: \(name)")
        return true
    }

    if selected("converted") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        let conversion = sandbox.conversion()
        check(conversion.shouldOffer(), "source present but not offered")
        check(digest(sandbox.staging).isEmpty, "offering changed the destination")
        let error = await failure { try conversion.convert() }
        check(error == nil, "conversion failed: \(String(describing: error))")
        try await assertConverted(sandbox)
        sandbox.assertSourceIntact()

        let before = digest(sandbox.root)
        let inodes = tree(sandbox.app).map { inode(sandbox.app.appendingPathComponent($0)) }
        let preferences = destinationPreferences().count
        check(!sandbox.conversion().shouldOffer(), "second launch offered again")
        check(digest(sandbox.root) == before, "second launch rewrote data")
        check(tree(sandbox.app).map { inode(sandbox.app.appendingPathComponent($0)) } == inodes, "second launch replaced files")
        check(destinationPreferences().count == preferences, "second launch changed preferences")
        sandbox.assertSourceIntact()
    }

    if selected("read-only source") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        let support = sandbox.base.appendingPathComponent("Application Support")
        let chmod = { (mode: String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["-R", mode, support.path]
            try process.run()
            process.waitUntilExit()
        }
        try chmod("a-w")
        let error = await failure { try sandbox.conversion().convert() }
        try chmod("u+w")
        check(error == nil, "read-only source failed: \(String(describing: error))")
        try await assertConverted(sandbox)
    }

    if selected("start fresh") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        check(sandbox.conversion().shouldOffer(), "source present but not offered")
        let error = await failure { try sandbox.conversion().startFresh() }
        check(error == nil, "start fresh failed: \(String(describing: error))")
        check(fm.fileExists(atPath: sandbox.marker.path), "start fresh wrote no marker")
        check(tree(sandbox.app).isEmpty, "start fresh wrote app data")
        check(destinationPreferences().isEmpty, "start fresh wrote preferences")
        check(!sandbox.conversion().shouldOffer(), "offered after start fresh")
        try Data("user".utf8).write(to: sandbox.app.appendingPathComponent("Boosts.json"))
        check(!sandbox.conversion().shouldOffer(), "offered after start fresh and use")
        check(fm.contents(atPath: sandbox.app.appendingPathComponent("Boosts.json").path) == Data("user".utf8), "relaunch changed new data")
        sandbox.assertSourceIntact()
    }

    if selected("start fresh after partial conversion") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        let thrown = await failure { try sandbox.conversion(checkpoint: { checkpoint in
            if checkpoint == "boosts.committed" { throw POSIXError(.ENOSPC) }
        }).convert() }
        check(thrown == .diskFull, "expected disk full, got \(String(describing: thrown))")
        check(!tree(sandbox.app).isEmpty, "commit phase did not start")
        let error = await failure { try sandbox.conversion().startFresh() }
        check(error == nil, "start fresh failed: \(String(describing: error))")
        check(tree(sandbox.app).isEmpty, "partial conversion left in destination: \(tree(sandbox.app))")
        check(destinationPreferences().isEmpty, "partial preferences left in destination")
        check(!fm.fileExists(atPath: sandbox.staging.path), "staging left behind")
        check(!sandbox.conversion().shouldOffer(), "offered after start fresh")
        sandbox.assertSourceIntact()
    }

    func refused(_ label: String, _ expected: (ChromiumDataConversion.Failure) -> Bool, prepare: (Sandbox) throws -> Void = { _ in },
                 restore: (Sandbox) throws -> Void = { _ in }, running: Bool = false, available: Int64 = .max) async throws {
        let sandbox = try Sandbox(from: fixture, name: "refused")
        try prepare(sandbox)
        let beforeDestination = digest(sandbox.root)
        let beforePreferences = destinationPreferences().count
        let thrown = await failure { try sandbox.conversion(running: { running }, available: available).convert() }
        guard let thrown, expected(thrown) else {
            check(false, "\(label): expected refusal, got \(String(describing: thrown))")
            return
        }
        check(!thrown.message.isEmpty && !thrown.message.contains(sandbox.base.path), "\(label): message \(thrown.message)")
        check(digest(sandbox.root) == beforeDestination, "\(label): destination changed")
        check(destinationPreferences().count == beforePreferences, "\(label): preferences changed")
        check(!fm.fileExists(atPath: sandbox.marker.path), "\(label): marker written")
        try restore(sandbox)
        sandbox.assertSourceIntact()
    }
    if selected("refusals") {
    try await refused("concurrent writer", { $0 == .legacyAppRunning }, running: true)
    try await refused("no space", { if case .insufficientSpace = $0 { return true }; return false }, available: 1)
    let unreadableFile = "Application Support/ee.qdo.nook/Tabs/structure.json"
    try await refused("unreadable file", { if case .sourceUnreadable = $0 { return true }; return false },
        prepare: { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: $0.base.appendingPathComponent(unreadableFile).path) },
        restore: { try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: $0.base.appendingPathComponent(unreadableFile).path) })
    let unreadableStore = "Application Support/ee.qdo.nook/default.store"
    try await refused("unreadable store", { if case .sourceUnreadable = $0 { return true }; return false },
        prepare: { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: $0.base.appendingPathComponent(unreadableStore).path) },
        restore: { try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: $0.base.appendingPathComponent(unreadableStore).path) })
    let unreadableParent = "Application Support/ee.qdo.nook/History"
    try await refused("unreadable history directory", { if case .sourceUnreadable = $0 { return true }; return false },
        prepare: { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: $0.base.appendingPathComponent(unreadableParent).path) },
        restore: { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: $0.base.appendingPathComponent(unreadableParent).path) })
    }

    if selected("symlinked source") {
    for link in ["Application Support/ee.qdo.nook/default.store", "Application Support/ee.qdo.nook/Tabs", "Application Support/ee.qdo.nook/Boosts.json"] {
        let sandbox = try Sandbox(from: fixture, name: "symlink")
        let source = sandbox.base.appendingPathComponent(link)
        let elsewhere = sandbox.base.appendingPathComponent("Elsewhere-\(source.lastPathComponent)")
        try fm.moveItem(at: source, to: elsewhere)
        try fm.createSymbolicLink(at: source, withDestinationURL: elsewhere)
        let before = digest(elsewhere)
        let beforeMode = try fm.attributesOfItem(atPath: elsewhere.path)[.posixPermissions] as? NSNumber
        let thrown = await failure { try sandbox.conversion().convert() }
        guard case .sourceUnreadable = thrown else { check(false, "\(link): symlink followed: \(String(describing: thrown))"); return }
        check(tree(sandbox.app).isEmpty, "\(link): symlink wrote data")
        check(digest(elsewhere) == before, "\(link): link target changed")
        let afterMode = try fm.attributesOfItem(atPath: elsewhere.path)[.posixPermissions] as? NSNumber
        check(afterMode == beforeMode, "\(link): link target mode changed")
    }
    }

    if selected("unreadable source root") {
        let unreadableRoot = "Application Support/ee.qdo.nook"
        let sandbox = try Sandbox(from: fixture, name: "refused-root")
        let path = sandbox.base.appendingPathComponent(unreadableRoot).path
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        check(sandbox.conversion().shouldOffer(), "unreadable source root not offered")
        let thrown = await failure { try sandbox.conversion().convert() }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        guard case .sourceUnreadable = thrown else { check(false, "unreadable root: \(String(describing: thrown))"); return }
        check(tree(sandbox.app).isEmpty, "unreadable root wrote data")
        sandbox.assertSourceIntact()
    }

    if selected("occupied destination") {
    try await refused("destination file", { $0 == .destinationOccupied },
        prepare: { try Data("user".utf8).write(to: $0.app.appendingPathComponent("Boosts.json")) })
    try await refused("destination preferences", { $0 == .destinationOccupied },
        prepare: { _ in
            let defaults = UserDefaults(suiteName: destinationDomain)!
            defaults.set("user", forKey: "settings.searchEngine")
            defaults.synchronize()
        })
    }

    if selected("start fresh keeps foreign data") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        let foreign = sandbox.app.appendingPathComponent("Boosts.json")
        try Data("user".utf8).write(to: foreign)
        let defaults = UserDefaults(suiteName: destinationDomain)!
        defaults.set("user", forKey: "settings.searchEngine")
        defaults.synchronize()
        let refused = await failure { try sandbox.conversion().convert() }
        check(refused == .destinationOccupied, "foreign data accepted: \(String(describing: refused))")
        let error = await failure { try sandbox.conversion().startFresh() }
        check(error == nil, "start fresh: \(String(describing: error))")
        check(fm.contents(atPath: foreign.path) == Data("user".utf8), "start fresh removed foreign file")
        check(destinationPreferences()["settings.searchEngine"] as? String == "user", "start fresh removed foreign preferences")
        check(!sandbox.conversion().shouldOffer(), "offered after start fresh")
        sandbox.assertSourceIntact()
    }

    if selected("kill during start fresh") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        _ = await failure { try sandbox.conversion(checkpoint: { current in
            if current == "boosts.committed" { throw POSIXError(.ENOSPC) }
        }).convert() }
        check(!tree(sandbox.app).isEmpty, "commit phase did not start")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--child-fresh", sandbox.base.path]
        try child.run()
        child.waitUntilExit()
        check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "child did not die: \(child.terminationStatus)")
        check(fm.fileExists(atPath: sandbox.marker.path), "no marker before cleanup")
        check(!sandbox.conversion().shouldOffer(), "offered after an interrupted start fresh")
        check(tree(sandbox.app).isEmpty, "interrupted start fresh left data: \(tree(sandbox.app))")
        check(destinationPreferences().isEmpty, "interrupted start fresh left preferences")
        check(!fm.fileExists(atPath: sandbox.staging.path), "staging left behind")
        sandbox.assertSourceIntact()
    }

    if selected("partial source") {
        let base = fixture.deletingLastPathComponent().appendingPathComponent("partial-fixture")
        try? fm.removeItem(at: base)
        try fm.copyItem(at: fixture, to: base)
        let data = Fixture.sourceData(base)
        for name in ["History", "Boosts.json", "Downloads.json"] { try fm.removeItem(at: data.appendingPathComponent(name)) }
        try fm.removeItem(at: Fixture.sourceConfig(base).appendingPathComponent("ai_config.json"))
        try fm.removeItem(at: base.appendingPathComponent("Preferences/ee.qdo.nook.plist"))
        let sandbox = try Sandbox(from: base, name: "partial")
        let error = await failure { try sandbox.conversion().convert() }
        check(error == nil, "partial source: \(String(describing: error))")
        let contents = Set(try fm.contentsOfDirectory(atPath: sandbox.app.path))
        check(contents == ["default.store", "Tabs"], "partial contents \(contents.sorted())")
        check(destinationPreferences().isEmpty, "partial source wrote preferences")
        check(!sandbox.conversion().shouldOffer(), "offered after partial conversion")
        sandbox.assertSourceIntact()
        try? fm.removeItem(at: base)
    }

    if selected("free space boundary") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        let required = try sandbox.conversion().requiredSpace()
        let thrown = await failure { try sandbox.conversion(available: required - 1).convert() }
        guard case .insufficientSpace = thrown else { check(false, "just below required: \(String(describing: thrown))"); return }
        let error = await failure { try sandbox.conversion(available: required).convert() }
        check(error == nil, "exactly required space refused: \(String(describing: error))")
        try await assertConverted(sandbox)
    }

    if selected("disk exhaustion") {
    for checkpoint in ["appData.copying", "tabs.validated", "boosts.committing"] {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        let thrown = await failure { try sandbox.conversion(checkpoint: { current in
            if current == checkpoint { throw POSIXError(.ENOSPC) }
        }).convert() }
        check(thrown == .diskFull, "\(checkpoint): expected disk full, got \(String(describing: thrown))")
        sandbox.assertSourceIntact()
        check(!fm.fileExists(atPath: sandbox.marker.path), "\(checkpoint): marker written")
        check(sandbox.conversion().shouldOffer(), "\(checkpoint): not offered after failure")
        let error = await failure { try sandbox.conversion().convert() }
        check(error == nil, "\(checkpoint): retry failed: \(String(describing: error))")
        try await assertConverted(sandbox)
        sandbox.assertSourceIntact()
    }
    }

    if selected("corrupt stores") {
    let corrupt = [
        ("Application Support/ee.qdo.nook/Tabs/structure.json", ["Application Support/ee.qdo.nook/Tabs/Backups"]),
        ("Application Support/ee.qdo.nook/default.store", ["Application Support/ee.qdo.nook/default.store-wal", "Application Support/ee.qdo.nook/default.store-shm"]),
        ("Application Support/ee.qdo.nook/History/page-text.sqlite", []),
        ("Application Support/ee.qdo.nook/Boosts.json", []),
        ("Application Support/ee.qdo.nook/Downloads.json", []),
        ("Application Support/Nook/ai_config.json", []),
    ]
    for (file, removed) in corrupt {
        let base = fixture.deletingLastPathComponent().appendingPathComponent("corrupt-fixture")
        try? fm.removeItem(at: base)
        try fm.copyItem(at: fixture, to: base)
        try Data("not a valid store, not at all".utf8).write(to: base.appendingPathComponent(file))
        for path in removed { try fm.removeItem(at: base.appendingPathComponent(path)) }
        let sandbox = try Sandbox(from: base, name: "corrupt")
        let thrown = await failure { try sandbox.conversion().convert() }
        guard case .validationFailed = thrown else { check(false, "\(file): expected validation failure, got \(String(describing: thrown))"); return }
        check(tree(sandbox.app).isEmpty, "\(file): corrupt store committed: \(tree(sandbox.app))")
        check(destinationPreferences().isEmpty, "\(file): preferences committed")
        check(!fm.fileExists(atPath: sandbox.marker.path), "\(file): marker written")
        sandbox.assertSourceIntact()
        try? fm.removeItem(at: base)
    }
    }

    if selected("store with another schema") {
        let base = fixture.deletingLastPathComponent().appendingPathComponent("foreign-schema-fixture")
        try? fm.removeItem(at: base)
        try fm.copyItem(at: fixture, to: base)
        let data = Fixture.sourceData(base)
        for suffix in ["", "-wal", "-shm"] { try fm.removeItem(atPath: data.appendingPathComponent("default.store").path + suffix) }
        var database: OpaquePointer?
        check(sqlite3_open(data.appendingPathComponent("default.store").path, &database) == SQLITE_OK, "fixture database")
        check(sqlite3_exec(database, "CREATE TABLE ZHISTORYENTITY(x); INSERT INTO ZHISTORYENTITY VALUES (1);", nil, nil, nil) == SQLITE_OK, "fixture table")
        sqlite3_close(database)
        let sandbox = try Sandbox(from: base, name: "foreign-schema")
        let thrown = await failure { try sandbox.conversion().convert() }
        guard case .validationFailed = thrown else { check(false, "unrelated store accepted: \(String(describing: thrown))"); return }
        check(tree(sandbox.app).isEmpty, "unrelated store committed")
        sandbox.assertSourceIntact()
        try? fm.removeItem(at: base)
    }

    if selected("source changes") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        let boosts = Fixture.sourceData(sandbox.base).appendingPathComponent("Boosts.json")
        let newer = [Boost(id: IDs.boost, name: "Newer", host: "newer.invalid")]
        let thrown = await failure { try sandbox.conversion(checkpoint: { current in
            if current == "pageText.validated" {
                let later = Date(timeIntervalSinceNow: 5)
                BoostStore.write(newer, to: boosts)
                try fm.setAttributes([.modificationDate: later], ofItemAtPath: boosts.path)
            }
        }).convert() }
        check(thrown == .sourceChanged, "expected source changed, got \(String(describing: thrown))")
        check(tree(sandbox.app).isEmpty, "changed source committed")
        check(destinationPreferences().isEmpty, "changed source wrote preferences")
        let error = await failure { try sandbox.conversion().convert() }
        check(error == nil, "retry after change failed: \(String(describing: error))")
        check(BoostStore.read(from: sandbox.app.appendingPathComponent("Boosts.json"), legacy: nil).first?.host == "newer.invalid", "retry used stale data")
    }
    if selected("writer starts mid-run") {
        let sandbox = try Sandbox(from: fixture, name: "writer-started")
        var started = false
        let thrown = await failure { try sandbox.conversion(running: { started }, checkpoint: { current in
            if current == "settings.validated" { started = true }
        }).convert() }
        check(thrown == .legacyAppRunning, "writer started mid-run: \(String(describing: thrown))")
        check(tree(sandbox.app).isEmpty, "writer started mid-run but data committed")
        sandbox.assertSourceIntact()
    }
    if selected("source changes after commit started") {
        let sandbox = try Sandbox(from: fixture, name: "changed-after-commit")
        let thrown = await failure { try sandbox.conversion(checkpoint: { current in
            if current == "tabs.committed" { throw POSIXError(.ENOSPC) }
        }).convert() }
        check(thrown == .diskFull, "expected disk full, got \(String(describing: thrown))")
        let tabsInode = inode(sandbox.app.appendingPathComponent("Tabs"))
        let later = Date(timeIntervalSinceNow: 5)
        let boosts = Fixture.sourceData(sandbox.base).appendingPathComponent("Boosts.json")
        BoostStore.write([Boost(id: IDs.boost, name: "Newer", host: "newer.invalid")], to: boosts)
        try fm.setAttributes([.modificationDate: later], ofItemAtPath: boosts.path)
        let error = await failure { try sandbox.conversion().convert() }
        check(error == nil, "resume after commit started: \(String(describing: error))")
        check(inode(sandbox.app.appendingPathComponent("Tabs")) == tabsInode, "committed tabs rewritten")
        check(BoostStore.read(from: sandbox.app.appendingPathComponent("Boosts.json"), legacy: nil).first?.host == "synthetic.invalid", "snapshot mixed after commit started")
    }

    if selected("foreign data during resume") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        _ = await failure { try sandbox.conversion(checkpoint: { current in
            if current == "tabs.committed" { throw POSIXError(.ENOSPC) }
        }).convert() }
        let foreign = sandbox.app.appendingPathComponent("Foreign.json")
        try Data("user".utf8).write(to: foreign)
        let thrown = await failure { try sandbox.conversion().convert() }
        check(thrown == .destinationOccupied, "foreign file accepted: \(String(describing: thrown))")
        let error = await failure { try sandbox.conversion().startFresh() }
        check(error == nil, "start fresh: \(String(describing: error))")
        check(fm.contents(atPath: foreign.path) == Data("user".utf8), "start fresh removed foreign data")
        check(!fm.fileExists(atPath: sandbox.app.appendingPathComponent("Tabs").path), "start fresh kept converted tabs")
    }
    if selected("same-named foreign data during resume") {
        let sandbox = try Sandbox(from: fixture, name: "foreign-same-name")
        _ = await failure { try sandbox.conversion(checkpoint: { current in
            if current == "tabs.committed" { throw POSIXError(.ENOSPC) }
        }).convert() }
        let foreign = sandbox.app.appendingPathComponent("Boosts.json")
        try Data("user".utf8).write(to: foreign)
        let thrown = await failure { try sandbox.conversion().convert() }
        check(thrown == .destinationOccupied, "same-named foreign file overwritten: \(String(describing: thrown))")
        check(fm.contents(atPath: foreign.path) == Data("user".utf8), "foreign file changed")
        let error = await failure { try sandbox.conversion().startFresh() }
        check(error == nil, "start fresh: \(String(describing: error))")
        check(fm.contents(atPath: foreign.path) == Data("user".utf8), "start fresh removed same-named foreign file")
    }

    if selected("flow") {
        let sandbox = try Sandbox(from: fixture, name: "scenario")
        var writer = true
        var finished = 0
        let flow = ChromiumDataConversionFlow(conversion: sandbox.conversion(running: { writer }), menuBar: .init(get: { nil }, set: { _ in })) { finished += 1 }
        check(flow.phase == .offer, "flow starts at the offer")
        flow.convert()
        check(flow.phase == .running, "flow not running")
        try await waitFor("flow to stop running") { flow.phase != .running }
        guard case .failed(let reason) = flow.phase else { check(false, "flow phase \(flow.phase)"); return }
        check(reason == ChromiumDataConversion.Failure.legacyAppRunning.message, "reason not shown: \(reason)")
        check(finished == 0, "failure opened the app")
        sandbox.assertSourceIntact()
        writer = false
        flow.convert()
        try await waitFor("flow to finish") { finished > 0 }
        check(finished == 1, "finished more than once")
        try await assertConverted(sandbox)
    }
    if selected("flow start fresh") {
        let sandbox = try Sandbox(from: fixture, name: "flow-fresh")
        var finished = 0
        let flow = ChromiumDataConversionFlow(conversion: sandbox.conversion(running: { true }), menuBar: .init(get: { nil }, set: { _ in })) { finished += 1 }
        flow.convert()
        try await waitFor("flow to stop running") { flow.phase != .running }
        flow.startFresh()
        try await waitFor("flow to finish") { finished > 0 }
        check(tree(sandbox.app).isEmpty, "flow start fresh wrote data")
        check(!sandbox.conversion().shouldOffer(), "flow start fresh offered again")
    }

    if selected("stock menu held during the notice") {
        func stockMenu() -> NSMenu {
            let file = NSMenu(title: "File")
            file.addItem(NSMenuItem(title: "New Window", action: #selector(NSApplication.orderFrontColorPanel(_:)), keyEquivalent: "n"))
            file.addItem(NSMenuItem(title: "New Tab", action: #selector(NSApplication.orderFrontColorPanel(_:)), keyEquivalent: "t"))
            let item = NSMenuItem()
            item.submenu = file
            let menu = NSMenu()
            menu.addItem(item)
            return menu
        }
        func commands(_ menu: NSMenu?) -> [String] {
            (menu?.items ?? []).flatMap { $0.submenu?.items ?? [$0] }.map(\.keyEquivalent)
        }
        for choice in ["convert", "startFresh"] {
            let sandbox = try Sandbox(from: fixture, name: "scenario")
            let stock = stockMenu()
            var current: NSMenu? = stock
            var writer = true
            var finished = 0
            var stockBackAtFinish = false
            let flow = ChromiumDataConversionFlow(conversion: sandbox.conversion(running: { writer }),
                                                  menuBar: .init(get: { current }, set: { current = $0 })) {
                stockBackAtFinish = current === stock
                finished += 1
            }
            check(current !== stock, "stock commands reachable during the notice")
            check(commands(current) == ["q"], "notice menu commands \(commands(current))")
            let quit = current?.items.first?.submenu?.items.first
            check(quit?.action == #selector(NSApplication.terminate(_:)) && quit?.target == nil, "notice menu cannot quit")
            flow.convert()
            try await waitFor("the refusal") { flow.phase != .running }
            check(current !== stock, "stock commands reachable after a refusal")
            writer = false
            if choice == "convert" { flow.convert() } else { flow.startFresh() }
            try await waitFor("flow to finish") { finished > 0 }
            check(stockBackAtFinish, "\(choice): stock menu not back before the app opens")
            check(current === stock && commands(current) == ["n", "t"], "\(choice): stock menu not restored")
            sandbox.assertSourceIntact()
        }
    }

    if selected("saved session ignores the first launch flag") {
        var sessions: [Bool: LoadedState] = [:]
        for flag in [true, false] {
            let base = fixture.deletingLastPathComponent().appendingPathComponent("flag-fixture")
            try? fm.removeItem(at: base)
            try fm.copyItem(at: fixture, to: base)
            let file = Fixture.sourceData(base).appendingPathComponent("Tabs/device.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            var state = json["state"] as! [String: Any]
            state["firstLaunchCompleted"] = flag
            json["state"] = state
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            let sandbox = try Sandbox(from: base, name: "flag")
            let error = await failure { try sandbox.conversion().convert() }
            check(error == nil, "flag \(flag): \(String(describing: error))")
            sessions[flag] = TabStore(directory: sandbox.app.appendingPathComponent("Tabs", isDirectory: true)).load()
            try? fm.removeItem(at: base)
        }
        check(sessions[true]?.outcome == .loaded && sessions[true]?.device == sessions[false]?.device, "the flag changed the loaded device state")
        check(sessions[true]?.tree.items == sessions[false]?.tree.items, "the flag changed the loaded tabs")
        check(sessions[false]?.device.windows.map(\.id) == [IDs.window], "saved windows \(String(describing: sessions[false]?.device.windows.count))")
    }

    if selected("notice") {
        let notice = ChromiumDataConversion.noticeBody.lowercased()
        for required in ["sign in", "cookies", "website storage", "extensions", "reinstall", "api keys", "profiles", "tabs", "history", "boosts", "downloads", "settings"] {
            check(notice.contains(required), "notice does not state \(required)")
        }
    }

    if selected("configuration") {
        let id = UUID().uuidString
        let dataRoot = fixture.deletingLastPathComponent().appendingPathComponent("config-root", isDirectory: true)
        let verification = try ChromiumStartupConfiguration(arguments: ["Nook", "--barc-app-data-dir=\(dataRoot.path)", "--barc-app-profile=\(id)"])
        check(verification.legacySupport == nil, "verification has a conversion source")
        check(ChromiumDataConversion(configuration: verification) == nil, "verification offers conversion")

        let support = fixture.deletingLastPathComponent().appendingPathComponent("config-support", isDirectory: true)
        let normal = try ChromiumStartupConfiguration(arguments: ["Nook"], applicationSupportDirectory: support)
        check(normal.legacySupport?.path == support.path, "normal launch source \(String(describing: normal.legacySupport))")
        check(normal.preferencesDomain == "ee.qdo.nook.chromium", "normal domain \(normal.preferencesDomain)")
        check(verification.preferencesDomain == "ee.qdo.nook.chromium-verification." + verification.rootDigest, "verification domain")

        for invalid in [
            ["Nook", "--barc-conversion-source=\(fixture.path)"],
            ["Nook", "--barc-app-data-dir=\(dataRoot.path)", "--barc-app-profile=\(id)", "--barc-conversion-source=/Users/synthetic"],
            ["Nook", "--barc-app-data-dir=\(dataRoot.path)", "--barc-app-profile=\(id)", "--barc-conversion-source=/private/tmp"],
            ["Nook", "--barc-app-data-dir=\(dataRoot.path)", "--barc-app-profile=\(id)", "--barc-conversion-source="],
        ] {
            let accepted = try? ChromiumStartupConfiguration(arguments: invalid, applicationSupportDirectory: support)
            check(accepted == nil, "accepted \(invalid)")
        }
    }

    if selected("explicit synthetic source") {
        let source = fixture.deletingLastPathComponent().appendingPathComponent("explicit-source", isDirectory: true)
        try? fm.removeItem(at: source)
        try fm.copyItem(at: fixture, to: source)
        let dataRoot = fixture.deletingLastPathComponent().appendingPathComponent("explicit-root", isDirectory: true)
        try? fm.removeItem(at: dataRoot)
        let configuration = try ChromiumStartupConfiguration(arguments: ["Nook", "--barc-app-data-dir=\(dataRoot.path)",
            "--barc-app-profile=\(IDs.work.uuidString)", "--barc-conversion-source=\(source.path)"])
        check(configuration.engineArguments(executable: "Nook").contains("--use-mock-keychain"), "mock keychain dropped")
        try configuration.prepare()
        let domain = configuration.preferencesDomain
        defer {
            let defaults = UserDefaults(suiteName: domain)!
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
        }
        let writerFile = source.appendingPathComponent("writer-running")
        try Data().write(to: writerFile)
        guard let conversion = ChromiumDataConversion(configuration: configuration) else { check(false, "fixture source not used"); return }
        check(conversion.shouldOffer(), "fixture source not offered")
        let refused = await failure { try conversion.convert() }
        check(refused == .legacyAppRunning, "fixture writer: \(String(describing: refused))")
        try fm.removeItem(at: writerFile)
        let error = await failure { try conversion.convert() }
        check(error == nil, "fixture conversion: \(String(describing: error))")
        let preferences = UserDefaults(suiteName: domain)!.persistentDomain(forName: domain) ?? [:]
        check(preferences["settings.searchEngine"] as? String == IDs.engine.uuidString, "fixture preferences")
        check(TabStore(directory: dataRoot.appendingPathComponent("App/Tabs")).load().outcome == .loaded, "fixture tabs")
        check(!conversion.shouldOffer(), "fixture offered again")
    }

    if selected("startup gate") {
        let bridge = StartupBridge()
        var proceed: (@MainActor () -> Void)?
        let startup = ChromiumStartup(bridge: bridge, profile: nil, prepareData: { proceed = $0 }, failure: { _ in })
        startup.register()
        bridge.ready?()
        check(bridge.opened == 0, "profile opened before the data decision")
        check(proceed != nil, "data decision not requested at runtime ready")
        proceed?()
        check(bridge.opened == 1, "profile not opened after the data decision")

        let ended = StartupBridge()
        var endedProceed: (@MainActor () -> Void)?
        let endedStartup = ChromiumStartup(bridge: ended, profile: nil, prepareData: { endedProceed = $0 }, failure: { _ in })
        endedStartup.register()
        ended.ready?()
        _ = endedStartup.runtimeReturned(0)
        endedProceed?()
        check(ended.opened == 0, "profile opened after the runtime returned")
    }

    if selected("kill at each stage") {
    var checkpoints: [String] = []
    for store in scenarioStores {
        checkpoints += ["\(store).copying", "\(store).validated"]
    }
    checkpoints.append("staged")
    for store in scenarioStores {
        checkpoints += ["\(store).committing", "\(store).committed"]
    }
    checkpoints += ["marker"]
    for checkpoint in checkpoints {
        print("  kill at \(checkpoint)")
        try await killAndResume(fixture: fixture, checkpoint: checkpoint)
    }
    }
}

// MARK: - Entry

@main
enum Main {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--child" {
            await runChild(base: URL(fileURLWithPath: arguments[2], isDirectory: true), crashAt: arguments[3])
        }
        if arguments.count == 3, arguments[1] == "--child-fresh" {
            let sandbox = ChildSandbox(base: URL(fileURLWithPath: arguments[2], isDirectory: true))
            _ = await run {
                try ChromiumDataConversion(environment: sandbox.environment { name in
                    if name == "fresh.marker" { kill(getpid(), SIGKILL) }
                }).startFresh()
            }
            print("child finished without reaching fresh.marker")
            exit(3)
        }
        if arguments.count == 3, arguments[1] == "--make-fixture" {
            let base = URL(fileURLWithPath: arguments[2], isDirectory: true)
            guard base.path.hasPrefix("/private/tmp/"), !fm.fileExists(atPath: base.path) else {
                print("--make-fixture needs a new directory under /private/tmp/")
                exit(2)
            }
            try await Fixture.build(at: base)
            print("fixture: \(base.path)")
            return
        }
        guard arguments.count == 2 else {
            print("usage: chromium-data-conversion-check <new directory under /private/tmp>")
            exit(2)
        }
        let work = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard work.path.hasPrefix("/private/tmp/") else {
            print("work directory must be under /private/tmp/")
            exit(2)
        }
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let fixture = work.appendingPathComponent("fixture", isDirectory: true)
        try await Fixture.build(at: fixture)
        try await scenarios(fixture: fixture)
        clearDestinationPreferences()
        try? fm.removeItem(at: work)
        print("PASS")
    }
}
