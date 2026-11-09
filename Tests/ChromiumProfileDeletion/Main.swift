import Foundation
import NookTabsCore
import NookWeb

@MainActor
private enum Native {
    static var target: String?
    static var survivor: String?
    static var callback: ProfileDeleteCallback?
    static var context: UnsafeMutableRawPointer?
    static var calls = 0
    static var continuationCalls = 0
    static var continuation: ChromiumProfileDeletion.Continue {
        { target, survivor, callback, context in MainActor.assumeIsolated {
            precondition(String(cString: target!) == Native.target)
            precondition(String(cString: survivor!) == Native.survivor)
            Native.continuationCalls += 1
            Native.callback = callback; Native.context = context
        } }
    }
    static var api: ChromiumProfileDeletion.Delete {
        { target, survivor, reconcileOnly, callback, context in MainActor.assumeIsolated {
            Native.calls += 1
            Native.target = String(cString: target!)
            Native.survivor = String(cString: survivor!)
            Native.callback = callback; Native.context = context
        } }
    }
    static func finish(_ result: Int32) {
        let callback = self.callback, context = self.context
        self.callback = nil; self.context = nil
        callback?(result, context)
    }
}

@main
struct Checks {
    @MainActor static func main() {
        let target = UUID(), survivor = UUID()
        let intent = PendingProfileDeletion(target: target, survivor: survivor)
        let owner = ChromiumProfileDeletion(delete: Native.api, acknowledge: { target, survivor in
            MainActor.assumeIsolated {
                precondition(String(cString: target!) == Native.target)
                precondition(String(cString: survivor!) == Native.survivor)
                return 1
            }
        })
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
        Native.finish(1)
        owner.request(intent, reconcileOnly: false, canDelete: { true }) { if case .deleted = $0 { outcomes.append("deleted") } }
        Native.finish(0)
        owner.request(intent, reconcileOnly: false, canDelete: { true }) { if case .pending = $0 { outcomes.append("stopped") } }
        owner.runtimeReturned()
        Native.finish(0) // cannot publish successful cleanup after runtime return
        owner.request(intent, reconcileOnly: false, canDelete: { true }) { if case .pending = $0 { outcomes.append("offline") } }
        precondition(Native.calls == 3)
        precondition(outcomes == ["refused", "busy", "cancelled", "deleted", "stopped", "offline"])
        let active = ChromiumProfileDeletion(delete: Native.api, acknowledge: { _, _ in 1 },
            prepare: Native.api, continueDeletion: Native.continuation)
        let change = PendingProfileChange(kind: .deleteProfile, spaceIDs: [UUID()],
            source: KeptProfile(id: target, name: "Work"), newDestination: nil, windowIDs: [])
        let activeIntent = PendingProfileDeletion(target: target, survivor: survivor, change: change)
        var continuation: (@MainActor (@escaping @MainActor(ProfileDeletionOutcome) -> Void) -> Void)?
        active.request(activeIntent, reconcileOnly: false, canDelete: { true }) { result in
            guard case .closeAdmitted(let next) = result else { preconditionFailure("expected close admission") }
            continuation = next
        }
        Native.finish(3)
        precondition(Native.continuationCalls == 0) // model owns durable commit before continuing
        var cleaned = false
        continuation? { if case .deleted = $0 { cleaned = true } }
        precondition(Native.continuationCalls == 1 && !cleaned)
        Native.finish(0)
        precondition(cleaned)
        continuation? { if case .pending = $0 {} else { preconditionFailure("repeated continuation") } }
        precondition(Native.continuationCalls == 1)
        active.runtimeReturned()
        print("PASS: exact identity, refusal, one operation, outcomes and runtime shutdown")
    }
}
