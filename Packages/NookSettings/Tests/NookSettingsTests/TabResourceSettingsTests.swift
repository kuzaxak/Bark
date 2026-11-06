// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookSettings

@MainActor
struct TabResourceSettingsTests {
    @Test func defaultsPersistAndChangesNotifyTheRunningPolicy() throws {
        let suite = "TabResourceSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokenStore = CountingKagiTokenStore()
        let settings = NookSettingsService(kagiTokenStore: tokenStore, userDefaults: defaults)
        #expect(settings.idleTabUnloadingEnabled)
        // The app's existing observer uses the mode payload to reapply its live policy.
        let modes = ModeNotifications()
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagementModeChanged, object: nil, queue: nil
        ) { notification in
            if let mode = notification.userInfo?["mode"] as? String {
                MainActor.assumeIsolated { modes.values.append(mode) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.startupLoadMode = .nothing
        settings.idleTabUnloadingEnabled = false
        #expect(modes.values.count == 1)
        #expect(modes.values == [settings.tabManagementMode.rawValue])
        let restored = NookSettingsService(kagiTokenStore: tokenStore, userDefaults: defaults)
        #expect(!restored.idleTabUnloadingEnabled)
        #expect(restored.startupLoadMode == .nothing)
        settings.startupLoadMode = .favoritesAndSpace
        settings.idleTabUnloadingEnabled = true
        let enabled = NookSettingsService(kagiTokenStore: tokenStore, userDefaults: defaults)
        #expect(enabled.idleTabUnloadingEnabled)
        #expect(enabled.startupLoadMode == .favoritesAndSpace)
        #expect(modes.values == Array(repeating: settings.tabManagementMode.rawValue, count: 2))
        #expect(tokenStore.loads == 0)
    }
}

@MainActor
private final class ModeNotifications { var values: [String] = [] }
