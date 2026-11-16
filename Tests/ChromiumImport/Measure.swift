// Licensed under GPL-3.0. See LICENSE.
// check.py --measure N: times imports of 5,000 bookmarks and of N visits into an on-disk history, and cancels one midway.
import Foundation
import NookWeb

/// The longest the main actor went without running a 5 ms tick.
@MainActor
final class MainProbe {
    private(set) var longestStall: Duration = .zero
    private var task: Task<Void, Never>?

    func start() {
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let before = clock.now
                try? await Task.sleep(for: .milliseconds(5))
                guard let self else { return }
                longestStall = max(longestStall, clock.now - before - .milliseconds(5))
            }
        }
    }

    func stop() { task?.cancel() }
}

extension Check {
    static func size(of directory: URL) -> Int {
        (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
    }

    static func timed(_ root: URL, _ label: String, reading: Bool = false) async throws -> (BrowserImportSummary, Host) {
        let host = try Host(onDisk: true)
        let probe = MainProbe()
        probe.start()
        let reader = Task { @MainActor in
            while reading, !Task.isCancelled {
                _ = await host.history.autofillHost(prefix: "bigfix", minVisits: 1)
                _ = await host.history.searchHistory(query: "page", offset: 0, limit: 20)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { reader.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        let summary = await host.importer(source(root)).run(.chrome)
        let total = clock.now - start
        probe.stop()
        let tabs = size(of: host.directory.appendingPathComponent("Tabs"))
        print("measure \(label): \(summary.tabs) bookmarks, \(summary.visits) visits in \(total); longest main-actor stall \(probe.longestStall); "
              + "history store and indexes \((size(of: host.directory) - tabs) / 1_048_576) MB")
        return (summary, host)
    }

    static func measure(_ big: URL, visits: Int) async throws {
        let bookmarks = URL(fileURLWithPath: arguments[4], isDirectory: true), history = URL(fileURLWithPath: arguments[5], isDirectory: true)
        let (marks, _) = try await timed(bookmarks, "bookmarks only")
        precondition(marks.tabs == 5_000, "every bookmark came in: \(marks.tabs)")
        let (visited, _) = try await timed(history, "history only")
        precondition(visited.visits == visits, "every visit came in: \(visited.visits)")
        let (read, _) = try await timed(history, "history while the palette reads it", reading: true)
        precondition(read.visits == visits, "every visit came in: \(read.visits)")

        let second = try Host(onDisk: true)
        let partial = BrowserImportProgress()
        let task = Task { await second.importer(source(big), progress: partial).run(.chrome) }
        while partial.visitsRead < visits / 5 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let cancelled = await task.value
        precondition(cancelled.cancelled && cancelled.visits >= visits / 5 && cancelled.visits < visits, "a cancel midway stops the history: \(cancelled.visits)")
        precondition(((try? FileManager.default.contentsOfDirectory(atPath: big.appendingPathComponent("App/ImportCopies").path)) ?? []).isEmpty, "and leaves no copy")
        let again = await second.importer(source(big)).run(.chrome)
        precondition(again.visits == visits && !again.cancelled, "importing again brings it all: \(again.visits)")
        print("measure: cancelled at \(cancelled.visits) of \(visits) visits, then imported again: \(again.visits)")
    }
}
