// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// An AppKit invitation can arrive during engine startup. Deliver after the
/// first product window and outside the native delegate callback.
@MainActor final class ChromiumCloudShareInbox<Invitation> {
    private var pending: [Invitation] = []
    private var accept: ((Invitation) -> Void)?
    private var delivery: Task<Void, Never>?
    private var stopped = false

    func receive(_ invitation: Invitation) {
        guard !stopped, pending.count < 16 else { return }
        pending.append(invitation)
        drain()
    }

    func ready(_ accept: @escaping (Invitation) -> Void) {
        guard !stopped else { return }
        self.accept = accept
        drain()
    }

    func stop() {
        stopped = true
        pending.removeAll()
        accept = nil
        delivery?.cancel()
    }

    private func drain() {
        guard delivery == nil, accept != nil, !pending.isEmpty else { return }
        delivery = Task { @MainActor in
            defer { delivery = nil }
            while !Task.isCancelled, !pending.isEmpty, let accept {
                accept(pending.removeFirst())
            }
        }
    }
}
