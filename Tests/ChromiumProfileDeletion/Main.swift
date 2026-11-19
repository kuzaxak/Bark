#if BARK_CATALOG_FRAMEWORK
@testable import NookNativeShell
#endif
import BarcChromium
import Foundation
import NookBlocker
import NookSettings
import NookTweaks
import NookTabsCore
import NookWeb

@MainActor
private enum Native {
    static var target: String?
    static var survivor: String?
    static var callback: barc_profile_delete_callback?
    static var context: UnsafeMutableRawPointer?
    static var calls = 0
    static var continuationCalls = 0
    static var beforeCleanup: (() -> Void)?
    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.profile_delete_kept = { target, survivor, reconcileOnly, callback, context in MainActor.assumeIsolated {
            Native.calls += 1
            Native.target = String(cString: target!)
            Native.survivor = String(cString: survivor!)
            Native.callback = callback; Native.context = context
        } }
        bridge.profile_delete_cancel_ack = { target, survivor in MainActor.assumeIsolated {
            precondition(String(cString: target!) == Native.target)
            precondition(String(cString: survivor!) == Native.survivor)
            return 1
        } }
        return bridge
    }
    static var activeBridge: BarcBridge {
        var bridge = Native.bridge
        bridge.profile_delete_cancel_ack = { _, _ in 1 }
        bridge.profile_prepare_reassignment = bridge.profile_delete_kept
        bridge.profile_continue_deletion = { target, survivor, callback, context in MainActor.assumeIsolated {
            precondition(String(cString: target!) == Native.target)
            precondition(String(cString: survivor!) == Native.survivor)
            Native.continuationCalls += 1
            Native.beforeCleanup?()
            Native.callback = callback; Native.context = context
        } }
        return bridge
    }
    static func finish(_ result: barc_profile_delete_result) {
        let callback = self.callback, context = self.context
        self.callback = nil; self.context = nil
        callback?(result, context)
    }
}

@main
struct Checks {
    @MainActor static func main() throws {
        let target = UUID(), survivor = UUID()
        let intent = PendingProfileDeletion(target: target, survivor: survivor)
        let owner = ChromiumProfileDeletion(bridge: Native.bridge)
        var outcomes: [String] = []
        owner.request(intent, reconcileOnly: false, canDelete: { false }) { if case .pending = $0 { outcomes.append("refused") } }
        precondition(Native.calls == 0)
        owner.request(intent, reconcileOnly: false, canDelete: { true }) { result in
            if case .cancelled(let acknowledge) = result { precondition(acknowledge()); outcomes.append("cancelled") }
        }
        precondition(Native.target == target.uuidString.lowercased())
        precondition(Native.survivor == survivor.uuidString.lowercased())
        owner.request(intent, reconcileOnly: false, canDelete: { true }) { if case .pending = $0 { outcomes.append("busy") } }
        precondition(Native.calls == 1)
        Native.finish(BARC_PROFILE_DELETE_CANCELLED)
        owner.request(intent, reconcileOnly: false, canDelete: { true }) { if case .deleted = $0 { outcomes.append("deleted") } }
        Native.finish(BARC_PROFILE_DELETED)
        owner.request(intent, reconcileOnly: false, canDelete: { true }) { if case .pending = $0 { outcomes.append("stopped") } }
        owner.runtimeReturned()
        Native.finish(BARC_PROFILE_DELETED) // cannot publish successful cleanup after runtime return
        owner.request(intent, reconcileOnly: false, canDelete: { true }) { if case .pending = $0 { outcomes.append("offline") } }
        precondition(Native.calls == 3)
        precondition(outcomes == ["refused", "busy", "cancelled", "deleted", "stopped", "offline"])
        let active = ChromiumProfileDeletion(bridge: Native.activeBridge)
        let change = PendingProfileChange(kind: .deleteProfile, spaceIDs: [UUID()],
            source: KeptProfile(id: target, name: "Work"), newDestination: nil, windowIDs: [])
        let activeIntent = PendingProfileDeletion(target: target, survivor: survivor, change: change)
        var continuation: (@MainActor (@escaping @MainActor(ProfileDeletionOutcome) -> Void) -> Void)?
        active.request(activeIntent, reconcileOnly: false, canDelete: { true }) { result in
            guard case .closeAdmitted(let next) = result else { preconditionFailure("expected close admission") }
            continuation = next
        }
        Native.finish(BARC_PROFILE_CLOSE_ADMITTED)
        precondition(Native.continuationCalls == 0) // model owns durable commit before continuing
        var cleaned = false
        continuation? { if case .deleted = $0 { cleaned = true } }
        precondition(Native.continuationCalls == 1 && !cleaned)
        Native.finish(BARC_PROFILE_DELETED)
        precondition(cleaned)
        continuation? { if case .pending = $0 {} else { preconditionFailure("repeated continuation") } }
        precondition(Native.continuationCalls == 1)
        active.runtimeReturned()
        try modelDeletion(failingCommit: false)
        try modelDeletion(failingCommit: true)
        print("PASS: exact asynchronous ownership, durable assignment, failed commit, and runtime shutdown")
    }

    @MainActor private static func modelDeletion(failingCommit: Bool) throws {
        let suite = "Bark-ProfileDeletion-\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            Native.beforeCleanup = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let settings = NookSettingsService(kagiTokenStore: NoTokenStore(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: root.appendingPathComponent("Boosts.json")))
        let directory = root.appendingPathComponent("Tabs")
        let tabs = TabsController(settings: settings, windowRegistry: WindowRegistry(),
            blocker: ContentBlockerManager(settings: settings, storageDirectory: root.appendingPathComponent("Blocker")),
            siteRouting: SiteRoutingManager(settings: settings), directory: directory)
        let sourceSpace = tabs.createSpace(name: "Work", icon: "", accentHex: "#123456", after: nil)!
        let destinationSpace = tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: sourceSpace)!
        let target = tabs.tree.dataStoreID(for: sourceSpace)!
        let survivor = tabs.tree.dataStoreID(for: destinationSpace)!
        precondition(target != survivor)
        let owner = ChromiumProfileDeletion(bridge: Native.activeBridge)
        tabs.onDeleteProfile = { intent, reconcileOnly, canDelete, completion in
            owner.request(intent, reconcileOnly: reconcileOnly, canDelete: canDelete, completion: completion)
        }
        var outcome: Result<Void, ProfileDeletionError>?
        let calls = Native.calls, continuations = Native.continuationCalls
        tabs.deleteProfile(target, surviving: survivor) { outcome = $0 }
        precondition(Native.calls == calls + 1 && outcome == nil)
        precondition(Native.target == target.uuidString.lowercased() && Native.survivor == survivor.uuidString.lowercased())
        precondition(tabs.tree.dataStoreID(for: sourceSpace) == target)
        precondition(TabStore(directory: directory).load().device.pendingProfileDeletion?.change?.phase == .prepared)

        if failingCommit {
            let saved = root.appendingPathComponent("SavedTabs")
            try FileManager.default.moveItem(at: directory, to: saved)
            try Data("intentional persistence failure".utf8).write(to: directory)
            Native.finish(BARC_PROFILE_CLOSE_ADMITTED)
            guard case .failure(.persistenceFailed)? = outcome else { preconditionFailure("expected a failed durable assignment") }
            precondition(Native.continuationCalls == continuations && Native.callback == nil)
            precondition(tabs.tree.dataStoreID(for: sourceSpace) == target)
            precondition(TabStore(directory: saved).load().device.pendingProfileDeletion?.change?.phase == .prepared)
        } else {
            Native.beforeCleanup = {
                let persisted = TabStore(directory: directory).load()
                precondition(persisted.tree.dataStoreID(for: sourceSpace) == survivor)
                precondition(persisted.device.pendingProfileDeletion?.change?.phase == .assignmentCommitted)
                precondition(persisted.device.keptProfiles?.contains { $0.id == target } == true)
            }
            Native.finish(BARC_PROFILE_CLOSE_ADMITTED)
            precondition(Native.continuationCalls == continuations + 1 && outcome == nil)
            Native.finish(BARC_PROFILE_DELETED)
            guard case .success? = outcome else { preconditionFailure("expected deletion to complete") }
            let persisted = TabStore(directory: directory).load()
            precondition(persisted.tree.dataStoreID(for: sourceSpace) == survivor)
            precondition(persisted.device.pendingProfileDeletion == nil)
            precondition(persisted.device.keptProfiles?.contains { $0.id == target } != true)
        }
        owner.runtimeReturned()
    }
}

private struct NoTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}
