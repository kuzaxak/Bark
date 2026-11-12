// Licensed under GPL-3.0. See LICENSE.
import BarcChromium
import Darwin
import Foundation
import Observation
import NookSettings
import NookTweaks

/// One fixed settings publication; document selection/lifetime stays native.
@MainActor final class ChromiumPageTweaks {
    private let bridge: BarcBridge
    private let settings: NookSettingsService
    private var accepted: NativePageTweaks?
    private var stopped = false
    private var observation: UInt64 = 0
    private(set) var lastError: Error?
    private(set) var isReady = false

    init(bridge: BarcBridge, settings: NookSettingsService) {
        self.bridge = bridge; self.settings = settings
    }
    /// The existing initial-page admission waits for the persisted Boost file,
    /// then proves this exact startup still owns the result before publication.
    func prepare(while current: @MainActor () -> Bool) async -> Bool {
        await settings.waitForBoosts()
        guard !stopped, current() else { return false }
        let ready = synchronize()
        return ready && !stopped && current()
    }
    @discardableResult func synchronize() -> Bool {
        guard !stopped else { return false }
        observation += 1
        let generation = observation
        let wanted = withObservationTracking {
            Result { try NativePageTweaks(settings: settings) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.observation == generation else { return }
                _ = self.synchronize()
            }
        }
        do {
            let snapshot = try wanted.get()
            if snapshot == accepted { lastError = nil; return true }
            let data = try snapshot.encoded()
            guard data.withUnsafeBytes({ bridge.page_tweaks_publish($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }) == 1 else {
                throw Failure.refused
            }
            guard !stopped, observation == generation,
                  (try? NativePageTweaks(settings: settings)) == snapshot else { return false }
            accepted = snapshot; lastError = nil; isReady = true; return true
        } catch {
            guard !stopped, observation == generation else { return false }
            // A failed removal must never leave old permission alive, or
            // revoke a newer publication admitted during this native callout.
            accepted = nil
            if lastError == nil { fputs("Page customizations are unavailable; saved settings were preserved and scripts revoked.\n", stderr) }
            lastError = error
            let revoked = bridge.page_tweaks_publish(nil, 0) == 1
            if !stopped, observation == generation { isReady = revoked }
            return revoked && !stopped && observation == generation
        }
    }
    func stop() { stopped = true; isReady = false; observation += 1 }
    enum Failure: Error { case refused }
}
