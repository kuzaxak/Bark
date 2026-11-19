// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Agent.swift
//  Nook
//
import Foundation
import NookWeb
import Observation

@MainActor private var nativeAgentIdle: AgentIdleClose?

extension BrowserManager {
    /// Close idle Agent space tabs 30 minutes and 30 seconds after the last tool call.
    func installNativeAgentIdleClose() {
        guard nativeAgentIdle == nil else { return }
        let idle = AgentIdleClose(delay: .seconds(30 * 60 + 30),
                                  calls: { [weak self] in self?.tabs.agentCallsInFlight ?? 0 },
                                  close: { [weak self] in self?.closeIdleAgentTabs() })
        nativeAgentIdle = idle
        watchAgentCalls(idle)
    }

    private func watchAgentCalls(_ idle: AgentIdleClose) {
        withObservationTracking { _ = tabs.agentCallsInFlight } onChange: { [weak self] in
            Task { @MainActor in
                idle.callsChanged()
                self?.watchAgentCalls(idle)
            }
        }
    }

    /// Closes the Agent space's regular tabs, unless a window is showing the space or a call runs.
    func closeIdleAgentTabs() {
        guard let agent = tabs.agentSpaceID, tabs.agentCallsInFlight == 0,
              !tabs.regularWindows.contains(where: { $0.spaceID == agent }) else { return }
        for item in tabs.children(of: .tabs(spaceID: agent)) { tabs.remove(item.id) }
    }
}
