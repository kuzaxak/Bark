// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Observation

/// AppKit can deliver an invitation before the first window, sync opt-in, or
/// account lookup. Keep it in memory until Settings and the account are ready.
@MainActor final class ChromiumCloudShareInbox<Invitation> {
    enum Readiness { case ready, waiting, needsSettings }

    private var pending: [Invitation] = []
    private var readiness: (() -> Readiness)?
    private var showSettings: (() -> Void)?
    private var accept: ((Invitation) async -> Bool)?
    private var delivery: Task<Void, Never>?
    private var waiting = false
    private var showedSettings = false
    private var stopped = false

    func receive(_ invitation: Invitation) {
        guard !stopped, pending.count < 16 else { return }
        pending.append(invitation)
        drain()
    }

    func ready(when readiness: @escaping () -> Readiness, showSettings: @escaping () -> Void,
               accept: @escaping (Invitation) async -> Bool) {
        guard !stopped else { return }
        self.readiness = readiness
        self.showSettings = showSettings
        self.accept = accept
        drain()
    }

    func stop() {
        stopped = true
        pending.removeAll()
        readiness = nil
        showSettings = nil
        accept = nil
        delivery?.cancel()
    }

    private func drain() {
        guard !stopped, !waiting, delivery == nil, readiness != nil, !pending.isEmpty else { return }
        delivery = Task { @MainActor in
            defer {
                delivery = nil
                drain()
            }
            while !Task.isCancelled, !pending.isEmpty, let readiness, let accept {
                if readiness() == .ready {
                    showedSettings = false
                    let consumed = await accept(pending[0])
                    if consumed && !stopped { pending.removeFirst() }
                    continue
                }
                waiting = true
                let state = withObservationTracking { readiness() } onChange: { [weak self] in
                    Task { @MainActor in
                        self?.waiting = false
                        self?.drain()
                    }
                }
                if state == .needsSettings && !showedSettings {
                    showedSettings = true
                    showSettings?()
                }
                return
            }
        }
    }
}
