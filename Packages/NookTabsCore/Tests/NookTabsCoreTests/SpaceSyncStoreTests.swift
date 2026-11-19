// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

struct SpaceSyncStoreTests {
    @Test func consentAndCursorStayInFreshBarkStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = root.appendingPathComponent("Sync")
        let oldContainer = sync.appendingPathComponent("iCloud.ee.qdo.nook")
        try FileManager.default.createDirectory(at: oldContainer, withIntermediateDirectories: true)

        var legacy = SpaceSyncState()
        legacy.account = "legacy-nook-account"
        legacy.engine = Data("legacy-cursor".utf8)
        let legacyBytes = try JSONEncoder().encode(legacy)
        let legacyFile = sync.appendingPathComponent("spaces.json")
        try legacyBytes.write(to: legacyFile)
        let oldSnapshot = SpaceSyncStore.Snapshot(enabled: true, state: legacy)
        let oldSnapshotFile = oldContainer.appendingPathComponent("spaces.json")
        let oldSnapshotBytes = try JSONEncoder().encode(oldSnapshot)
        try oldSnapshotBytes.write(to: oldSnapshotFile)

        let tabs = root.appendingPathComponent("Tabs")
        #expect(try SpaceSyncStore(tabsDirectory: tabs).read() == nil)

        var bark = SpaceSyncState()
        bark.account = "bark-account"
        bark.engine = Data("bark-cursor".utf8)
        let space = UUID()
        bark.setLevel(.pinned, for: space)
        let store = SpaceSyncStore(tabsDirectory: tabs)
        try store.write(bark, enabled: true)
        let optedIn = try #require(try SpaceSyncStore(tabsDirectory: tabs).read())
        #expect(optedIn.enabled)
        #expect(optedIn.state == bark)
        try store.write(bark, enabled: false)
        let optedOut = try #require(try SpaceSyncStore(tabsDirectory: tabs).read())
        #expect(!optedOut.enabled)
        #expect(optedOut.state == bark)
        #expect(try Data(contentsOf: legacyFile) == legacyBytes)
        #expect(try Data(contentsOf: oldSnapshotFile) == oldSnapshotBytes)
    }

    @Test func corruptBarkStateIsNotSilentlyTreatedAsFresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sync/iCloud.ee.qdo.bark/spaces.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{\"enabled\":true,\"state\":".utf8)
        try corrupt.write(to: file)
        let store = SpaceSyncStore(tabsDirectory: root.appendingPathComponent("Tabs"))
        #expect(throws: DecodingError.self) { try store.read() }
        #expect(try Data(contentsOf: file) == corrupt)
    }
}
