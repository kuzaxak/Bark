// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore
import SQLite3
import SwiftData
import Testing
@testable import NookWeb

/// History writes run behind the main actor, one after another in the order they were asked for.
@MainActor
struct HistoryWriteTests {
    private func manager() throws -> (HistoryManager, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryWrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer(for: HistoryEntity.self, configurations: ModelConfiguration(url: directory.appendingPathComponent("History.store")))
        return (HistoryManager(context: container.mainContext, indexURL: directory.appendingPathComponent("HistoryIndex.sqlite")), directory)
    }

    private func visits(_ count: Int, host: String) -> [HistoryVisit] {
        (0..<count).map { HistoryVisit(url: URL(string: "https://\(host)/page/\($0)")!, title: "Page \($0)", timestamp: Date(), tabId: nil, profileId: nil) }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var isRaised: Bool { lock.withLock { raised } }
    }

    @Test func legacyHistoryAndItsExistingIndexAreScopedToTheFirstSpacesProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryOwner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: HistoryEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let space = UUID(), other = UUID()
        var tree = TabTree.firstLaunch(spaceID: space, homeURL: URL(string: "about:blank")!)
        try tree.setProfile(space, to: nil, name: "Different profile")
        let owner = try #require(tree.orderedSpaces.first.flatMap { tree.dataStoreID(for: $0.id) })
        #expect(owner != space)
        let indexURL = root.appendingPathComponent("Index.sqlite")
        let legacy = HistoryManager(context: container.mainContext, indexURL: indexURL)
        let url = URL(string: "https://unassigned.test/synthetic")!
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        await legacy.importVisitsAndWait([
            HistoryVisit(url: url, title: "Legacy unassigned", timestamp: now, tabId: nil, profileId: nil),
            HistoryVisit(url: url, title: "Explicit owner", timestamp: yesterday, tabId: nil, profileId: owner),
            HistoryVisit(url: url, title: "Other owner", timestamp: yesterday, tabId: nil, profileId: other),
            HistoryVisit(url: URL(string: "https://ambiguous.test")!, title: "Ambiguous",
                         timestamp: now, tabId: nil, profileId: space),
        ], claimUnscopedRows: false)
        let explicit = try #require(await legacy.getHistory(profile: owner).entries.first { $0.title == "Explicit owner" })
        legacy.recordPick(prefix: "un", url: url, fromPrivateWindow: false)
        legacy.recordPick(prefix: "un", url: url, fromPrivateWindow: false, profile: owner)
        legacy.recordPick(prefix: "un", url: url, fromPrivateWindow: false, profile: other)
        _ = await legacy.getHistory()

        // Simulate a write that reports success without moving the eligible row.
        var rawDB: OpaquePointer?
        try #require(sqlite3_open(indexURL.path, &rawDB) == SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        try #require(sqlite3_exec(rawDB, """
            CREATE TRIGGER reject_history_claim BEFORE UPDATE ON visits
            WHEN old.profile <> '' BEGIN SELECT RAISE(IGNORE); END
            """, nil, nil, nil) == SQLITE_OK)
        let interrupted = HistoryManager(context: container.mainContext, profileId: other, indexURL: indexURL,
                                         profileOwnership: .isolated(migrateUnassignedTo: owner))
        #expect(await interrupted.indexRows(matching: "unassigned", profile: owner)?.map(\.visitCount) == [1])
        #expect(await interrupted.indexRows(matching: "unassigned", profile: other)?.map(\.visitCount) == [1])
        try #require(sqlite3_exec(rawDB, "DROP TRIGGER reject_history_claim", nil, nil, nil) == SQLITE_OK)

        let history = HistoryManager(context: container.mainContext, profileId: owner, indexURL: indexURL,
                                     profileOwnership: .isolated(migrateUnassignedTo: owner))
        let ownerRows = await history.getHistory(profile: owner).entries
        #expect(ownerRows.map(\.title) == ["Legacy unassigned"])
        #expect(ownerRows.map(\.id) == [explicit.id])
        #expect(ownerRows.map(\.visitCount) == [2])
        #expect(ownerRows.map(\.lastVisited) == [now])
        #expect(await history.getHistory(profile: other).entries.map(\.title) == ["Other owner"])
        let indexed = try #require(await history.indexRows(matching: "unassigned", profile: owner)?.first)
        #expect(indexed.visitCount == 2)
        #expect(abs(indexed.lastVisited.timeIntervalSince(now)) < 0.001)
        #expect(await history.indexRows(matching: "unassigned", profile: other)?.map(\.visitCount) == [1])
        let reader = HistoryIndex(fileURL: indexURL, halfLife: 7 * 86_400)
        #expect(await reader.picks(profile: owner).map(\.n) == [2])
        #expect(await reader.picks(profile: other).map(\.n) == [1])
        history.switchProfile(nil)
        history.addVisit(url: URL(string: "https://ownerless.test")!, title: "Ownerless", tabId: nil)
        #expect(await history.getHistory().entries.isEmpty)
        #expect(await history.indexRows(matching: "unassigned")?.isEmpty == true)
        let restarted = HistoryManager(context: container.mainContext, profileId: owner, indexURL: indexURL,
                                       profileOwnership: .isolated(migrateUnassignedTo: owner))
        #expect(await restarted.indexRows(matching: "unassigned", profile: owner)?.map(\.visitCount) == [2])
        #expect(await restarted.indexRows(matching: "ownerless", profile: owner)?.isEmpty == true)

        history.forget(url)
        history.deleteHistoryEntry(explicit.id)
        history.switchProfile(other)
        history.deleteHistoryEntry(explicit.id)
        #expect(await history.getHistory(profile: owner).entries.map(\.id) == [explicit.id])
        #expect(await history.searchIndex(query: "unassigned", limit: 10, profile: other, isOpen: { _ in false })?.count == 1)
        history.forget(url)
        #expect(await history.getHistory(profile: owner).entries.map(\.id) == [explicit.id])
        #expect(await history.getHistory(profile: other).entries.isEmpty)
        #expect(await history.searchIndex(query: "unassigned", limit: 10, profile: owner, isOpen: { _ in false })?.count == 1)
        #expect(await history.searchIndex(query: "unassigned", limit: 10, profile: other, isOpen: { _ in false })?.isEmpty == true)
        #expect(await history.getHistory(profile: space).entries.map(\.title) == ["Ambiguous"])
    }

    @Test func pageTextForTheSameURLFollowsItsCapturingProfileAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PageTextOwners-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: HistoryEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let personal = UUID(), work = UUID(), unrelated = UUID()
        let page = URL(string: "https://fixture.invalid/shared")!
        let historical = Date().addingTimeInterval(-3 * 86_400)
        let history = HistoryManager(context: container.mainContext, profileId: personal,
            pageTextURL: root.appendingPathComponent("PageText.sqlite"))
        history.addVisit(url: page, title: "Work history", timestamp: historical, tabId: nil, profileId: work)
        history.addVisit(url: page, title: "Personal history", tabId: nil, profileId: personal)
        history.recordPageText(url: page, profile: work, title: "Work page", body: "worktoken")
        history.recordPageText(url: page, profile: personal, title: "Personal page", body: "personaltoken")
        history.recordPageText(url: page, profile: unrelated, title: "Unknown owner", body: "unrelatedtoken")

        #expect(await history.searchPageText(query: "personaltoken", limit: 8).map(\.title) == ["Personal history"])
        #expect(await history.searchPageText(query: "worktoken", limit: 8).isEmpty)
        #expect(await history.searchPageText(query: "worktoken", limit: 8, profile: work).map(\.title) == ["Work history"])
        #expect(await history.searchPageText(query: "personaltoken", limit: 8, profile: work).isEmpty)
        #expect(await history.searchPageText(query: "unrelatedtoken", limit: 8, profile: unrelated).isEmpty)

        history.clearHistory(olderThan: 1, profileId: work)
        #expect(await history.searchPageText(query: "worktoken", limit: 8, profile: work).isEmpty)
        #expect(await history.searchPageText(query: "personaltoken", limit: 8).count == 1)
        history.addVisit(url: page, title: "Work returned", tabId: nil, profileId: work)
        #expect(await history.searchPageText(query: "worktoken", limit: 8, profile: work).isEmpty)
        history.recordPageText(url: page, profile: work, title: "Work returned", body: "worktoken")
        let workRows = await history.searchPageText(query: "worktoken", limit: 8, profile: work)
        history.deleteHistoryEntry(try #require(workRows.first).id)
        #expect(await history.searchPageText(query: "worktoken", limit: 8, profile: work).isEmpty)
        #expect(await history.searchPageText(query: "personaltoken", limit: 8).count == 1)

        history.addVisit(url: page, title: "Another Work visit", tabId: nil, profileId: work)
        history.recordPageText(url: page, profile: work, title: "Work page", body: "worktoken")
        history.forget(page)
        #expect(await history.searchPageText(query: "personaltoken", limit: 8).isEmpty)
        #expect(await history.searchPageText(query: "worktoken", limit: 8, profile: work).count == 1)
        history.deleteHistory(forProfile: work)
        #expect(await history.searchPageText(query: "worktoken", limit: 8, profile: work).isEmpty)
    }

    @Test func aWriteLandsWhileTheMainActorIsBusy() async throws {
        let (history, directory) = try manager()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await history.getHistory()
        let reader = HistoryIndex(fileURL: directory.appendingPathComponent("HistoryIndex.sqlite"), halfLife: 86_400)
        let landed = Flag()
        let poll = Task.detached {
            while !Task.isCancelled {
                if await reader.search("lastpage", profile: nil)?.isEmpty == false { return landed.raise() }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let last = HistoryVisit(url: URL(string: "https://busy.test/last")!, title: "Lastpage", timestamp: Date(), tabId: nil, profileId: nil)
        history.importVisits(visits(1_000, host: "busy.test") + [last])
        let deadline = Date().addingTimeInterval(20)
        while !landed.isRaised, Date() < deadline { usleep(10_000) }
        poll.cancel()
        #expect(landed.isRaised, "a history write needs the main actor: nothing landed while it was busy")
    }

    @Test func writesLandInTheOrderTheyWereAskedFor() async throws {
        let (history, directory) = try manager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let last = HistoryVisit(url: URL(string: "https://first.test/last")!, title: "Lastpage", timestamp: Date(), tabId: nil, profileId: nil)
        history.importVisits(visits(2_000, host: "first.test") + [last])
        history.importVisits(visits(1, host: "second.test"))
        let found = await history.searchIndex(query: "lastpage", limit: 10) { _ in false }
        #expect(found?.map(\.url) == [last.url], "a read after the second write sees all of the first: \(String(describing: found))")
    }
}
