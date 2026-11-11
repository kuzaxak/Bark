// Licensed under GPL-3.0. See LICENSE.
import Foundation
import SwiftData
import Testing
@testable import NookWeb

@MainActor
struct HistoryPickPrivacyTests {
    @Test func aPrivateWindowsCommandBarRecordsNoPick() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryPickPrivacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexURL = directory.appendingPathComponent("HistoryIndex.sqlite")
        let container = try ModelContainer(for: HistoryEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let profile = UUID()
        let history = HistoryManager(context: container.mainContext, profileId: profile, indexURL: indexURL)
        let url = URL(string: "https://picked.test/page")!

        history.recordPick(prefix: "secret", url: url, fromPrivateWindow: true)
        _ = await history.getHistory()
        let reader = HistoryIndex(fileURL: indexURL, halfLife: 86_400)
        #expect(await reader.picks(profile: profile).isEmpty, "what a private window typed is not saved")

        history.recordPick(prefix: "pick", url: url, fromPrivateWindow: false)
        _ = await history.getHistory()
        #expect(await reader.picks(profile: profile).map(\.prefix) == ["pick"], "a regular window's pick is saved")
    }
}
