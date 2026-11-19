// Licensed under GPL-3.0. See LICENSE.
import Foundation
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
