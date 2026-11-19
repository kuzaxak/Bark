// Licensed under GPL-3.0. See LICENSE.
//
//  AgentIdleClose.swift
//  Nook
//
//  Closes the Agent space's tabs once no DevMCP tool call has run for a while.
//

import Foundation

@MainActor final class AgentIdleClose {
    private let delay: Duration
    private let calls: @MainActor () -> Int
    private let close: @MainActor () -> Void
    private var timer: Task<Void, Never>?

    init(delay: Duration, calls: @escaping @MainActor () -> Int, close: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.calls = calls
        self.close = close
    }

    /// After the number of tool calls running changes: the delay starts again once none runs.
    func callsChanged() {
        timer?.cancel()
        timer = nil
        guard calls() == 0 else { return }
        timer = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.calls() == 0 else { return }
            self.close()
        }
    }
}
