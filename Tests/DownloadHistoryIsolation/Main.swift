import Foundation

@main
struct DownloadHistoryIsolationTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloaded = root.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: downloaded)
        let first = root.appendingPathComponent("first/Downloads.json")
        let second = root.appendingPathComponent("second/Downloads.json")
        let profile = UUID()
        let snapshot = DownloadSnapshot(
            originalURL: URL(string: "https://example.invalid/fixture?secret=discard")!,
            path: downloaded.path, date: Date(timeIntervalSince1970: 10), size: 7,
            profileID: profile, isCompleted: true, isPrivate: false)
        DownloadHistoryStore.save([snapshot], to: first)
        let records: [DownloadRecord] = await withCheckedContinuation { continuation in
            DownloadHistoryStore.load(from: first) { continuation.resume(returning: $0) }
        }
        precondition(records.count == 1 && records[0].profileID == profile)
        precondition(records[0].originalURL.query == nil)
        let other: [DownloadRecord] = await withCheckedContinuation { continuation in
            DownloadHistoryStore.load(from: second) { continuation.resume(returning: $0) }
        }
        precondition(other.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: second.path))
        let original = try Data(contentsOf: first)
        DownloadHistoryStore.save([], to: second)
        let cleared: [DownloadRecord] = await withCheckedContinuation { continuation in
            DownloadHistoryStore.load(from: second) { continuation.resume(returning: $0) }
        }
        let preserved = try Data(contentsOf: first)
        precondition(cleared.isEmpty && preserved == original)
        print("Download history isolation: separate files, preserved profile, query stripping PASS")
    }
}
