import BarcChromium
import Foundation
import NookTabsCore
import NookWeb

/// One model-owned deletion at a time; Chromium owns profiles, closure and wipe.
@MainActor
final class ChromiumProfileDeletion {
    private let bridge: BarcBridge
    private var intent: PendingProfileDeletion?
    private var completion: (@MainActor (ProfileDeletionOutcome) -> Void)?
    private var stopped = false

    init(bridge: BarcBridge) { self.bridge = bridge }

    private static let callback: barc_profile_delete_callback = { result, pointer in
        MainActor.assumeIsolated {
            guard let pointer else { return }
            Unmanaged<ChromiumProfileDeletion>.fromOpaque(pointer).takeUnretainedValue().received(result)
        }
    }

    func request(_ intent: PendingProfileDeletion, reconcileOnly: Bool, canDelete: () -> Bool,
                 completion: @escaping @MainActor (ProfileDeletionOutcome) -> Void) {
        guard !stopped, self.completion == nil, canDelete() else { completion(.pending); return }
        if let change = intent.change, change.kind != .deleteProfile { completion(.pending); return }
        let call = intent.change == nil ? bridge.profile_delete_kept : bridge.profile_prepare_reassignment
        self.completion = completion; self.intent = intent
        intent.target.uuidString.lowercased().withCString { target in
            intent.survivor.uuidString.lowercased().withCString { survivor in
                call(target, survivor, reconcileOnly ? 1 : 0, Self.callback,
                     Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    private func received(_ result: barc_profile_delete_result) {
        let callback = completion, requested = intent
        completion = nil; intent = nil
        guard let callback, let requested else { return }
        switch result {
        case BARC_PROFILE_DELETED: callback(.deleted)
        case BARC_PROFILE_DELETE_CANCELLED:
            callback(.cancelled(acknowledge: { [weak self] in
                guard let self, !self.stopped else { return false }
                return requested.target.uuidString.lowercased().withCString { target in
                    requested.survivor.uuidString.lowercased().withCString { survivor in
                        self.bridge.profile_delete_cancel_ack(target, survivor) == 1
                    }
                }
            }))
        case BARC_PROFILE_CLOSE_ADMITTED where requested.change?.kind == .deleteProfile:
            var continued = false
            callback(.closeAdmitted(continueCleanup: { [weak self] completion in
                guard !continued else { completion(.pending); return }
                continued = true
                guard let self, !self.stopped, self.completion == nil else {
                    completion(.pending); return
                }
                self.completion = completion; self.intent = requested
                requested.target.uuidString.lowercased().withCString { target in
                    requested.survivor.uuidString.lowercased().withCString { survivor in
                        self.bridge.profile_continue_deletion(target, survivor, Self.callback,
                                         Unmanaged.passUnretained(self).toOpaque())
                    }
                }
            }))
        default: callback(.pending)
        }
    }

    /// Called after ChromeMain returns; native callback storage can no longer run.
    func runtimeReturned() {
        stopped = true
        let callback = completion
        completion = nil
        intent = nil
        callback?(.pending)
    }
}
