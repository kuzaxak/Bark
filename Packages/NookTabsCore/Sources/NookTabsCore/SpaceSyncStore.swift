// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// This Mac's consent, selections and CloudKit cursor belong to the same dataset.
public struct SpaceSyncStore {
    public struct Snapshot: Codable {
        public var enabled: Bool
        public var state: SpaceSyncState
    }

    private let file: URL

    public init(tabsDirectory: URL) {
        file = tabsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Sync", isDirectory: true)
            .appendingPathComponent(SpaceSyncAvailability.containerID, isDirectory: true)
            .appendingPathComponent("spaces.json")
    }

    public func read() throws -> Snapshot? {
        do {
            return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func write(_ state: SpaceSyncState, enabled: Bool) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Snapshot(enabled: enabled, state: state)).write(to: file, options: .atomic)
    }
}
