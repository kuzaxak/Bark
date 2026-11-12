// Licensed under GPL-3.0. See LICENSE.
import BarcChromium
import Foundation
import NookWeb

struct ChromiumLiveFetch {
    let bridge: BarcBridge

    @MainActor private final class Pending {
        let bridge: BarcBridge
        var token: UInt64 = 0
        var continuation: CheckedContinuation<ProfileLiveResponse, Error>?
        var done = false
        init(bridge: BarcBridge) { self.bridge = bridge }
        func cancelRequest() { if !done, token != 0 { bridge.profile_live_cancel(token) } }
        func reply(_ result: Result<ProfileLiveResponse, Error>) {
            guard !done else { return }
            done = true
            let continuation = continuation; self.continuation = nil
            continuation?.resume(with: result)
        }
    }

    @MainActor func fetch(profileID: UUID, source: ProfileLiveSource) async throws -> ProfileLiveResponse {
        let route: barc_live_source, argument: String
        switch source {
        case .githubPulls: route = BARC_LIVE_GITHUB_PULLS; argument = ""
        case .githubIssues: route = BARC_LIVE_GITHUB_ISSUES; argument = ""
        case .githubNotifications: route = BARC_LIVE_GITHUB_NOTIFICATIONS; argument = ""
        case .asanaWorkspaces: route = BARC_LIVE_ASANA_WORKSPACES; argument = ""
        case .asanaTasks(let workspace): route = BARC_LIVE_ASANA_TASKS; argument = workspace
        case .gmail(let account):
            guard account >= 0 else { throw ProfileLiveFailure.unavailable }
            route = BARC_LIVE_GMAIL; argument = String(account)
        }
        guard argument.utf8.count <= 64, !argument.contains("\0") else { throw ProfileLiveFailure.unavailable }
        let pending = Pending(bridge: bridge)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response: ProfileLiveResponse = try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                let context = Unmanaged.passRetained(pending).toOpaque()
                let token = profileID.uuidString.lowercased().withCString { uuid in
                    argument.withCString { argument in
                        bridge.profile_live_get(uuid, Int32(route.rawValue), argument, { context, token, result, status, body, length in
                            guard let context else { return }
                            MainActor.assumeIsolated {
                                // Accepted requests always settle, including cancellation/shutdown.
                                let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
                                guard length >= 0, length <= 4 * 1024 * 1024, body != nil || length == 0 else {
                                    pending.reply(.failure(ProfileLiveFailure.failed)); return
                                }
                                switch result {
                                case BARC_LIVE_OK where status > 0:
                                    let bytes = body.map { Data(bytes: $0, count: length) } ?? Data()
                                    pending.reply(.success(ProfileLiveResponse(data: bytes, status: Int(status))))
                                case BARC_LIVE_CANCELLED: pending.reply(.failure(ProfileLiveFailure.cancelled))
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
