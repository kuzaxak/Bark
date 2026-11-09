import Foundation
import NookSettings
import NookTabsCore
import SwiftData

private let fm = FileManager.default

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() {
        print("FAIL Main.swift:\(line): \(message)")
        exit(1)
    }
}

private final class NoTokens: KagiTokenStore, @unchecked Sendable {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

private enum Failure: Error { case disk }

@MainActor
private struct Stores {
    let tabs: TabStore
    let tabFile: URL
    let settings: NookSettingsService
    let boostFile: URL
    let container: ModelContainer
    let context: ModelContext
    let storeFile: URL

    init(root: URL, domain: String) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        tabs = TabStore(directory: root.appendingPathComponent("Tabs", isDirectory: true))
        tabFile = root.appendingPathComponent("Tabs/structure.json")
        boostFile = root.appendingPathComponent("Boosts.json")
        settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: UserDefaults(suiteName: domain)!,
                                       boostStore: BoostStore(fileURL: boostFile))
        storeFile = root.appendingPathComponent("default.store")
        container = try ModelContainer(for: HistoryEntity.self, configurations: ModelConfiguration(url: storeFile, cloudKitDatabase: .none))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// Edits made a moment before the quit: all three are still queued or unsaved.
    func edit(name: String) {
        var tree = TabTree()
        tree.createSpace(id: UUID(), name: name, icon: "house", accentHex: "#111111", after: nil, now: Date())
        tabs.save(tree, DeviceState())
        settings.boosts = (0..<4000).map { Boost(name: name + "\($0)", host: "synthetic\($0).invalid") }
        context.insert(HistoryEntity(url: "https://synthetic.invalid/" + name, title: name))
    }

    func tabsHold(_ name: String) -> Bool {
        fm.contents(atPath: tabFile.path).map { String(decoding: $0, as: UTF8.self).contains(name) } ?? false
    }

    func boostsOnDisk() -> Int { BoostStore.read(from: boostFile, legacy: nil).count }

    func historyOnDisk() throws -> Int {
        let reopened = try ModelContainer(for: HistoryEntity.self, configurations: ModelConfiguration(url: storeFile, cloudKitDatabase: .none))
        return try ModelContext(reopened).fetchCount(FetchDescriptor<HistoryEntity>())
    }

    func quitSave(failContext: Bool = false, report: @escaping (Error) -> Void = { _ in }) -> ChromiumQuitSave {
        ChromiumQuitSave(flushTabs: { [tabs] in tabs.flush() }, flushBoosts: { [settings] in settings.flushBoosts() },
                         saveContext: { [context] in
                             if failContext { throw Failure.disk }
                             try context.save()
                         }, report: report)
    }
}

@main
enum Main {
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let domain = CommandLine.arguments[2]
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }

        var stores = try Stores(root: base.appendingPathComponent("accepted"), domain: domain)
        await stores.settings.waitForBoosts()
        stores.edit(name: "LastMoment")
        check(!stores.tabsHold("LastMoment"), "fixture: tabs already on disk before the quit")
        var quit = stores.quitSave()
        quit.save()
        check(stores.tabsHold("LastMoment"), "an accepted quit lost the last tab edit")
        check(stores.boostsOnDisk() == 4000, "an accepted quit lost the last Boost edit: \(stores.boostsOnDisk())")
        let saved = try stores.historyOnDisk()
        check(saved == 1, "an accepted quit lost unsaved history: \(saved)")

        stores = try Stores(root: base.appendingPathComponent("failure"), domain: domain)
        await stores.settings.waitForBoosts()
        stores.edit(name: "Failing")
        var reported: [Error] = []
        quit = stores.quitSave(failContext: true) { reported.append($0) }
        quit.save()
        check(reported.count == 1 && reported.first is Failure, "a failed context save was not reported: \(reported)")
        check(stores.tabsHold("Failing"), "a failed context save lost the tab flush")
        check(stores.boostsOnDisk() == 4000, "a failed context save lost the Boost flush")

        var runs = 0
        quit = ChromiumQuitSave(flushTabs: { runs += 1 }, flushBoosts: {}, saveContext: {})
        quit.save()
        quit.save()
        check(runs == 1, "the runtime's return repeated an accepted save: \(runs)")
        quit.cancelled()
        quit.save()
        check(runs == 2, "a quit accepted again after a veto did not save: \(runs)")
        print("PASS")
    }
}
