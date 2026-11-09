// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookWeb
// Only the shared app loader error type is stubbed; adapter and NookWeb are real.
enum ChromiumNavigationError: Error { case missingSymbol(String) }
@MainActor private enum Native {
    struct Call { let token: UInt64; let profile: String; let route: Int32; let argument: String
        let callback: ChromiumLiveFetch.Callback?; let context: UnsafeMutableRawPointer?; var done = false }
    static var calls: [Call] = [], cancelled: [UInt64] = []
    static var refuse = false, synchronous = false
    static var api: ChromiumLiveFetch {
        ChromiumLiveFetch(get: { profile, source, argument, callback, context in MainActor.assumeIsolated {
            if Native.refuse { return 0 }
            let token = UInt64(Native.calls.count + 1)
            Native.calls.append(Call(token: token, profile: String(cString: profile!), route: source,
                argument: String(cString: argument!), callback: callback, context: context))
            if Native.synchronous { Native.reply(Native.calls.count - 1, result: 0, status: 302, bytes: []) }
            return token
        } }, cancel: { token in MainActor.assumeIsolated {
            guard let index = Native.calls.firstIndex(where: { $0.token == token && !$0.done }) else { return }
            Native.cancelled.append(token); Native.reply(index, result: 1, status: 0, bytes: [])
        } })
    }
    static func reply(_ index: Int, result: Int32, status: Int32, bytes: [UInt8]) {
        precondition(!calls[index].done); calls[index].done = true
        let call = calls[index]
        bytes.withUnsafeBufferPointer { call.callback?(call.context, call.token, result, status, $0.baseAddress, $0.count) }
    }
}
@main struct Main {
    @MainActor static func main() async throws {
        let api = Native.api, profile = UUID()
        let read = Task { try await api.fetch(profileID: profile, source: .gmail(account: 2)) }
        while Native.calls.isEmpty { await Task.yield() }
        precondition(Native.calls[0].profile == profile.uuidString.lowercased() && Native.calls[0].route == 5 && Native.calls[0].argument == "2")
        Native.reply(0, result: 0, status: 200, bytes: [65, 0, 66])
        let response = try await read.value
        precondition(response.status == 200 && response.data == Data([65, 0, 66]))
        let pending = Task { try await api.fetch(profileID: profile, source: .githubPulls) }
        while Native.calls.count < 2 { await Task.yield() }
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("cancelled") } catch {}
        precondition(Native.cancelled == [2])
        Native.refuse = true
        do { _ = try await api.fetch(profileID: profile, source: .githubIssues); preconditionFailure("refused") }
        catch ProfileLiveFailure.unavailable {}
        precondition(Native.calls.count == 2)
        Native.refuse = false; Native.synchronous = true
        let redirect = try await api.fetch(profileID: profile, source: .asanaTasks(workspace: "123"))
        precondition(redirect.status == 302 && redirect.data.isEmpty)
        precondition(Native.calls.last!.route == 4 && Native.calls.last!.argument == "123")
        Native.synchronous = false
        let httpError = Task { try await api.fetch(profileID: profile, source: .githubNotifications) }
        while Native.calls.count < 4 { await Task.yield() }
        Native.reply(3, result: 0, status: 404, bytes: [])
        let notFound = try await httpError.value
        precondition(notFound.status == 404)
        let failure = Task { try await api.fetch(profileID: profile, source: .githubIssues) }
        while Native.calls.count < 5 { await Task.yield() }
        Native.reply(4, result: 4, status: 200, bytes: [])
        do { _ = try await failure.value; preconditionFailure("too large is not HTTP success") } catch ProfileLiveFailure.failed {}
        do { _ = try await api.fetch(profileID: profile, source: .gmail(account: -1)); preconditionFailure("negative account") }
        catch ProfileLiveFailure.unavailable {}
        precondition(Native.calls.count == 5 && Native.calls.allSatisfy(\.done))
        print("Native live fetch adapter: exact UUID/fixed route, bytes/NUL/status, synchronous completion, refusal and cancellation passed")
    }
}
