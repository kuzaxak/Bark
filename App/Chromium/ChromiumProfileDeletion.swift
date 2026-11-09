import Darwin
import Foundation
import NookTabsCore
import NookWeb

typealias ProfileDeleteCallback = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void

/// One model-owned deletion at a time; Chromium owns profiles, closure and wipe.
@MainActor
final class ChromiumProfileDeletion {
    typealias Delete = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, ProfileDeleteCallback?, UnsafeMutableRawPointer?) -> Void
    typealias Acknowledge = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias Continue = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, ProfileDeleteCallback?, UnsafeMutableRawPointer?) -> Void
    private let delete: Delete
    private let prepare: Delete?
    private let continueDeletion: Continue?
    private let acknowledge: Acknowledge
    private var intent: PendingProfileDeletion?
    private var completion: (@MainActor (ProfileDeletionOutcome) -> Void)?
    private var stopped = false

    init(library: UnsafeMutableRawPointer) throws {
        guard let symbol = dlsym(library, "barc_profile_delete_kept") else {
            throw ChromiumNavigationError.missingSymbol("barc_profile_delete_kept")
        }
        delete = unsafeBitCast(symbol, to: Delete.self)
        guard let ack = dlsym(library, "barc_profile_delete_cancel_ack") else {
            throw ChromiumNavigationError.missingSymbol("barc_profile_delete_cancel_ack")
        }
        acknowledge = unsafeBitCast(ack, to: Acknowledge.self)
        guard let preparation = dlsym(library, "barc_profile_prepare_reassignment"),
              let continuation = dlsym(library, "barc_profile_continue_deletion") else {
            throw ChromiumNavigationError.missingSymbol("barc_profile_prepare_reassignment/continue_deletion")
        }
        prepare = unsafeBitCast(preparation, to: Delete.self)
        continueDeletion = unsafeBitCast(continuation, to: Continue.self)
    }

    init(delete: @escaping Delete, acknowledge: @escaping Acknowledge,
         prepare: Delete? = nil, continueDeletion: Continue? = nil) {
        self.delete = delete; self.acknowledge = acknowledge
        self.prepare = prepare; self.continueDeletion = continueDeletion
    }

    private static let callback: ProfileDeleteCallback = { result, pointer in
        MainActor.assumeIsolated {
            guard let pointer else { return }
            Unmanaged<ChromiumProfileDeletion>.fromOpaque(pointer).takeUnretainedValue().received(result)
        }
    }

    func request(_ intent: PendingProfileDeletion, reconcileOnly: Bool, canDelete: () -> Bool,
                 completion: @escaping @MainActor (ProfileDeletionOutcome) -> Void) {
        guard !stopped, self.completion == nil, canDelete() else { completion(.pending); return }
        let call: Delete
        if let change = intent.change {
            guard change.kind == .deleteProfile, let prepare else { completion(.pending); return }
            call = prepare
        } else { call = delete }
        self.completion = completion; self.intent = intent
        intent.target.uuidString.lowercased().withCString { target in
            intent.survivor.uuidString.lowercased().withCString { survivor in
                call(target, survivor, reconcileOnly ? 1 : 0, Self.callback,
                     Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    private func received(_ result: Int32) {
        let callback = completion, requested = intent
        completion = nil; intent = nil
        guard let callback, let requested else { return }
        switch result {
        case 0: callback(.deleted)
        case 1:
            callback(.cancelled(acknowledge: { [weak self] in
                guard let self, !self.stopped else { return false }
                return requested.target.uuidString.lowercased().withCString { target in
                    requested.survivor.uuidString.lowercased().withCString { survivor in
                        self.acknowledge(target, survivor) == 1
                    }
                }
            }))
        case 3 where requested.change?.kind == .deleteProfile:
            var continued = false
            callback(.closeAdmitted(continueCleanup: { [weak self] completion in
                guard !continued else { completion(.pending); return }
                continued = true
                guard let self, !self.stopped, self.completion == nil, let continueDeletion = self.continueDeletion else {
                    completion(.pending); return
                }
                self.completion = completion; self.intent = requested
                requested.target.uuidString.lowercased().withCString { target in
                    requested.survivor.uuidString.lowercased().withCString { survivor in
                        continueDeletion(target, survivor, Self.callback,
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
