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
        let original = try JSONSerialization.data(withJSONObject: [[
            "originalURL": "https://user:password@example.test/file?token=sample#section",
            "path": downloaded.path, "date": 0, "profileID": profile.uuidString,
        ]])
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: first)
        let records: [DownloadRecord] = await withCheckedContinuation { continuation in
            DownloadHistoryStore.load(from: first) { continuation.resume(returning: $0) }
        }
        precondition(records.count == 1 && records[0].profileID == profile)
        precondition(records[0].originalURL.absoluteString == "https://example.test/file")
        let other: [DownloadRecord] = await withCheckedContinuation { continuation in
            DownloadHistoryStore.load(from: second) { continuation.resume(returning: $0) }
        }
        precondition(other.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: second.path))
        let preserved = try Data(contentsOf: first)
        precondition(preserved == original)
        print("Download history isolation: separate files, preserved profile, query stripping PASS")
    }
}
