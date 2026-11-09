// Licensed under GPL-3.0. See LICENSE.
import Darwin
import Foundation
import NookWeb

struct ChromiumLiveFetch {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UInt64, Int32, Int32,
                                         UnsafePointer<UInt8>?, Int) -> Void
    typealias Get = @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Callback?, UnsafeMutableRawPointer?) -> UInt64
    typealias Cancel = @convention(c) (UInt64) -> Void
    let get: Get
    let cancel: Cancel

    init(get: @escaping Get, cancel: @escaping Cancel) { self.get = get; self.cancel = cancel }
    init(library: UnsafeMutableRawPointer) throws {
        guard let get = dlsym(library, "barc_profile_live_get") else {
            throw ChromiumNavigationError.missingSymbol("barc_profile_live_get")
        }
        guard let cancel = dlsym(library, "barc_profile_live_cancel") else {
            throw ChromiumNavigationError.missingSymbol("barc_profile_live_cancel")
        }
        self.get = unsafeBitCast(get, to: Get.self)
        self.cancel = unsafeBitCast(cancel, to: Cancel.self)
    }

    @MainActor private final class Pending {
        let cancel: Cancel
        var token: UInt64 = 0
        var continuation: CheckedContinuation<ProfileLiveResponse, Error>?
        var done = false
        init(cancel: @escaping Cancel) { self.cancel = cancel }
        func cancelRequest() { if !done, token != 0 { cancel(token) } }
        func reply(_ result: Result<ProfileLiveResponse, Error>) {
            guard !done else { return }
            done = true
            let continuation = continuation; self.continuation = nil
            continuation?.resume(with: result)
        }
    }

    @MainActor func fetch(profileID: UUID, source: ProfileLiveSource) async throws -> ProfileLiveResponse {
        let route: Int32, argument: String
        switch source {
        case .githubPulls: route = 0; argument = ""
        case .githubIssues: route = 1; argument = ""
        case .githubNotifications: route = 2; argument = ""
        case .asanaWorkspaces: route = 3; argument = ""
        case .asanaTasks(let workspace): route = 4; argument = workspace
        case .gmail(let account):
            guard account >= 0 else { throw ProfileLiveFailure.unavailable }
            route = 5; argument = String(account)
        }
        guard argument.utf8.count <= 64, !argument.contains("\0") else { throw ProfileLiveFailure.unavailable }
        let pending = Pending(cancel: cancel)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response: ProfileLiveResponse = try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                let context = Unmanaged.passRetained(pending).toOpaque()
                let token = profileID.uuidString.lowercased().withCString { uuid in
                    argument.withCString { argument in
                        get(uuid, route, argument, { context, token, result, status, body, length in
                            guard let context else { return }
                            MainActor.assumeIsolated {
                                // Accepted requests always settle, including cancellation/shutdown.
                                let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
                                guard length >= 0, length <= 4 * 1024 * 1024, body != nil || length == 0 else {
                                    pending.reply(.failure(ProfileLiveFailure.failed)); return
                                }
                                switch result {
                                case 0 where status > 0:
                                    let bytes = body.map { Data(bytes: $0, count: length) } ?? Data()
                                    pending.reply(.success(ProfileLiveResponse(data: bytes, status: Int(status))))
                                case 1: pending.reply(.failure(ProfileLiveFailure.cancelled))
                                default: pending.reply(.failure(ProfileLiveFailure.failed))
                                }
                            }
                        }, context)
                    }
                }
                if token == 0 {
                    Unmanaged<Pending>.fromOpaque(context).release()
                    pending.reply(.failure(ProfileLiveFailure.unavailable))
                } else if !pending.done { pending.token = token }
            }
            try Task.checkCancellation()
            return response
        } onCancel: {
            Task { @MainActor in pending.cancelRequest() }
        }
    }
}
