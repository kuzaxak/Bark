// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookSettings

@MainActor
struct SidebarPositionTests {
    @Test func aShellThatKeepsTheSidebarLeftReadsLeftAndKeepsTheStoredRight() throws {
        let suite = "SidebarPositionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("right", forKey: "settings.sidebarPosition")

        let bark = NookSettingsService(kagiTokenStore: CountingKagiTokenStore(), userDefaults: defaults, keepsSidebarLeft: true)
        #expect(bark.sidebarPosition == .left)
        #expect(defaults.string(forKey: "settings.sidebarPosition") == "right")

        let webKit = NookSettingsService(kagiTokenStore: CountingKagiTokenStore(), userDefaults: defaults)
        #expect(webKit.sidebarPosition == .right)
        webKit.sidebarPosition = .left
        #expect(defaults.string(forKey: "settings.sidebarPosition") == "left")
    }
}
