#if BARK_CATALOG_FRAMEWORK
@testable import NookNativeShell
#endif
import AppKit
import BarcChromium
import Foundation
import Observation
import NookWeb

@MainActor private enum Native {
    static var callback: BarcDownloadCallback?
    static var context: UnsafeMutableRawPointer?
    static var actions: [(UInt64, String, Int32)] = []
    static var safe: [UInt64: [String: String]] = [:]
    static var accepts = true
    static var token: UInt64 = 0
    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.downloads_observe = { callback, context in MainActor.assumeIsolated {
            Native.token += 1; Native.callback = callback; Native.context = context; return Native.token
        } }
        bridge.downloads_unobserve = { _ in MainActor.assumeIsolated { Native.callback = nil; Native.context = nil } }
        bridge.download_action = { _, source, guid, action in MainActor.assumeIsolated {
            Native.actions.append((source, String(cString: guid!), action)); return Native.accepts ? 1 : 0
        } }
        bridge.download_copy_safe_target = { _, source, guid, buffer, capacity in MainActor.assumeIsolated {
            guard let path = Native.safe[source]?[String(cString: guid!)] else { return 0 }
            let bytes = path.utf8CString
            if let buffer, capacity >= bytes.count {
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            }
            return bytes.count
        } }
        return bridge
    }
    static func emit(profile: UUID, source: UInt64, guid: String, state: Int32 = 0,
                     flags: UInt32 = 0, target: String = "", event: Int32 = 0) {
        profile.uuidString.withCString { profile in guid.withCString { guid in
            "https://fixture.invalid/download".withCString { url in target.withCString { target in
                "fixture.txt".withCString { filename in
                    var row = BarcDownloadSnapshot(size: MemoryLayout<BarcDownloadSnapshot>.size,
                        manager: source, profile_uuid: profile, guid: guid,
                        url: url, target_path: target, filename: filename, state: state, error: 0,
                        flags: flags, received_bytes: 3, total_bytes: 9, started_unix: 1)
                    withUnsafePointer(to: &row) { callback?(context, token, event, $0) }
                }
            } }
        } }
    }
}

@main private enum Checks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDownloads-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = root.appendingPathComponent("A.txt"), fileB = root.appendingPathComponent("B.txt")
        try Data("A".utf8).write(to: fileA); try Data("B".utf8).write(to: fileB)
        let manager = DownloadManager()
        precondition(manager.allDownloads.isEmpty)
        let bridge = ChromiumDownloads(bridge: Native.bridge)
        precondition(bridge.start(manager: manager))
        let work = UUID(), personal = UUID(), guid = "same-guid"
        Native.emit(profile: work, source: 11, guid: guid)
        let progressRow = manager.allDownloads.first!
        var membershipChanged = false
        withObservationTracking { _ = manager.allDownloads } onChange: {
            MainActor.assumeIsolated { membershipChanged = true }
        }
        Native.emit(profile: work, source: 11, guid: guid)
        precondition(!membershipChanged && manager.allDownloads.first === progressRow,
                     "Progress republished collection membership or replaced the row")
        Native.emit(profile: personal, source: 22, guid: guid)
        Native.emit(profile: work, source: 33, guid: guid, flags: 1)
        precondition(manager.allDownloads.count == 3)
        let regular = manager.allDownloads.first { $0.origin.profileID == work && !$0.origin.isPrivate }!
        let privateRow = manager.allDownloads.first { $0.origin.isPrivate }!
        let personalRow = manager.allDownloads.first { $0.origin.profileID == personal }!
        precondition(Set(manager.allDownloads.map(\.id)).count == 3)
        let regularWindow = BrowserWindowState(), privateA = BrowserWindowState(), privateB = BrowserWindowState()
        privateA.isIncognito = true; privateA.ephemeralProfile = .createEphemeral(id: work)
        let otherPrivate = UUID()
        privateB.isIncognito = true; privateB.ephemeralProfile = .createEphemeral(id: otherPrivate)
        Native.emit(profile: otherPrivate, source: 34, guid: guid, flags: 1)
        precondition(manager.visibleDownloads(in: regularWindow).count == 2 &&
            manager.visibleDownloads(in: regularWindow).allSatisfy { !$0.origin.isPrivate })
        precondition(manager.visibleDownloads(in: privateA).map(\.id) == [privateRow.id])
        precondition(manager.visibleDownloads(in: privateB).allSatisfy { $0.origin.profileID == otherPrivate } &&
            manager.visibleDownloads(in: privateB).count == 1)
        precondition(manager.recentDownloads(in: privateA).map(\.id) == [privateRow.id])
        let unknown = BrowserWindowState(); unknown.isIncognito = true
        precondition(manager.visibleDownloads(in: unknown).isEmpty)
        Native.emit(profile: otherPrivate, source: 34, guid: "", flags: 1, event: 2)
        Native.accepts = false; manager.cancelDownload(regular.id)
        precondition(regular.state == .downloading && manager.allDownloads.count == 3)
        Native.accepts = true; manager.removeDownload(regular.id)
        precondition(Native.actions.last?.0 == 11 && Native.actions.last?.2 == 0)
        precondition(regular.state == .downloading && manager.allDownloads.count == 3)
        Native.emit(profile: work, source: 11, guid: guid, state: 2)
        precondition(regular.state == .cancelled)
        precondition(Native.actions.last?.0 == 11 && Native.actions.last?.2 == 1)
        precondition(manager.allDownloads.contains { $0 === regular })
        Native.emit(profile: work, source: 11, guid: guid, state: 2, event: 1)
        precondition(manager.allDownloads.count == 2 && manager.allDownloads.contains { $0 === personalRow })
        Native.safe[33] = [guid: fileA.path]
        Native.emit(profile: work, source: 33, guid: guid, state: 1, flags: 1 | 4, target: fileA.path)
        manager.preview(privateRow, in: privateA)
        precondition(manager.previewTarget(for: privateRow, in: privateA) == fileA)
        precondition(manager.previewTarget(for: privateRow, in: regularWindow) == nil)
        manager.dismissPreview(in: regularWindow)
        precondition(manager.previewing === privateRow)
        Native.emit(profile: work, source: 33, guid: "", flags: 1, event: 2)
        precondition(manager.previewing == nil)
        precondition(manager.allDownloads.count == 1 && !manager.allDownloads.contains { $0 === privateRow })

        Native.safe[22] = [guid: fileA.path]
        Native.emit(profile: personal, source: 22, guid: guid, state: 1, flags: 4, target: fileA.path)
        precondition(personalRow.validatedCompletedFile() == fileA)
        Native.safe[22]?[guid] = fileB.path
        precondition(personalRow.completedFile == fileA && personalRow.validatedCompletedFile() == fileB,
                     "A cached filename was approved instead of the actual engine target")
        try FileManager.default.removeItem(at: fileA)
        precondition(personalRow.completedFile == nil && personalRow.validatedCompletedFile() == fileB)
        manager.preview(personalRow, in: regularWindow)
        precondition(manager.previewFileURL == fileB)
        precondition(manager.previewTarget(for: personalRow, in: regularWindow) == fileB)
        precondition(manager.previewTarget(for: personalRow, in: BrowserWindowState()) == nil)
        // A fresh action must recheck the engine even before the next observation arrives.
        Native.safe[22] = [:]
        precondition(manager.previewTarget(for: personalRow, in: regularWindow) == nil)
        precondition(personalRow.validatedCompletedFile() == nil)
        Native.emit(profile: personal, source: 22, guid: guid, state: 1, flags: 2, target: fileB.path)
        precondition(personalRow.completedFile == nil && manager.previewing == nil)
        Native.emit(profile: personal, source: 22, guid: guid, state: 3, flags: 4, target: fileB.path)
        precondition(personalRow.completedFile == nil)
        Native.emit(profile: personal, source: 22, guid: "", event: 2)
        precondition(manager.allDownloads.isEmpty)

        var starts: [Download] = []
        let startObserver = NotificationCenter.default.addObserver(forName: .downloadDidStart, object: nil, queue: nil) { note in
            MainActor.assumeIsolated { starts.append(note.object as! Download) }
        }
        let clicked = NSWindow(), point = NSPoint(x: 120, y: 340)
        var asked = 0
        manager.nativeLaunch = { _ in asked += 1; return (clicked, point) }
        let saved = root.appendingPathComponent("started.txt").path
        Native.emit(profile: work, source: 55, guid: "asks-where")
        precondition(starts.isEmpty, "a download still choosing where to save flew")
        Native.emit(profile: work, source: 55, guid: "asks-where", target: saved)
        precondition(starts.count == 1 && asked == 1 && starts[0].sourceWindow === clicked && starts[0].launchPoint == point,
                     "a download flies once it has a destination, from where it was clicked: \(starts.count) \(asked)")
        Native.emit(profile: work, source: 55, guid: "asks-where", target: saved)
        Native.emit(profile: work, source: 55, guid: "asks-where", state: 1, flags: 4, target: saved)
        precondition(starts.count == 1, "progress and completion do not fly again")
        Native.emit(profile: work, source: 56, guid: "declined")
        Native.emit(profile: work, source: 56, guid: "declined", state: 2)
        Native.emit(profile: work, source: 57, guid: "history", state: 1, flags: 4, target: saved)
        precondition(starts.count == 1, "a download cancelled in the save panel, or finished before, does not fly")
        Native.emit(profile: work, source: 58, guid: "direct", target: saved)
        precondition(starts.count == 2 && starts[1].nativeIdentity?.guid == "direct", "a download that starts with its destination flies")
        Native.emit(profile: work, source: 58, guid: "direct", state: 3, target: saved)
        Native.emit(profile: work, source: 58, guid: "direct", target: saved)
        precondition(starts.count == 2, "resuming an interrupted download does not fly")
        manager.nativeLaunch = { _ in nil }
        Native.emit(profile: work, source: 59, guid: "elsewhere", target: saved)
        precondition(starts.count == 3 && starts[2].sourceWindow == nil && starts[2].launchPoint == nil,
                     "a download no window in front started has nowhere to fly from")
        NotificationCenter.default.removeObserver(startObserver)
        for source: UInt64 in 55...59 { Native.emit(profile: work, source: source, guid: "", event: 2) }
        precondition(manager.allDownloads.isEmpty)

        // Unsubscribe from a publication callback. No zombie row may appear
        // after the stop emptied this stream, and late callbacks are ignored.
        var stopped = false
        withObservationTracking { _ = manager.activeDownloads } onChange: {
            MainActor.assumeIsolated {
                guard !stopped else { return }; stopped = true; bridge.stop()
            }
        }
        let callback = Native.callback, context = Native.context, token = Native.token
        Native.emit(profile: work, source: 44, guid: "stopped")
        precondition(stopped && manager.allDownloads.isEmpty && Native.callback == nil)
        Native.callback = callback; Native.context = context
        Native.emit(profile: work, source: 44, guid: "late")
        Native.callback = nil; Native.context = nil
        precondition(Native.token == token && manager.allDownloads.isEmpty)
        print("Native downloads: scoped identity, confirmed actions, current safe target and shutdown PASS")
    }
}
