// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookSettings

@MainActor
struct BoostStoreInjectionTests {
    @Test func injectedStoreLoadsAndSavesWithoutTouchingAnotherStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoostStoreInjectionTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("App/Boosts.json")
        let otherURL = root.appendingPathComponent("OtherApp/Boosts.json")
        let first = Boost(host: "one.example", css: "body { color: red; }")
        let other = Boost(host: "two.example", css: "body { color: blue; }")
        BoostStore.write([first], to: firstURL)
        BoostStore.write([other], to: otherURL)
        let untouched = try Data(contentsOf: otherURL)
        let suite = "BoostStoreInjectionTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = CountingKagiTokenStore()
        let settings = NookSettingsService(kagiTokenStore: tokens,
            userDefaults: defaults, boostStore: BoostStore(fileURL: firstURL))
        #expect(!settings.boostsLoaded)
        #expect(settings.boosts.isEmpty)
        await settings.waitForBoosts()
        #expect(settings.boosts == [first])
        var edited = first
        edited.css = "body { color: green; }"
        settings.boosts = [edited]
        settings.flushBoosts()
        #expect(BoostStore.read(from: firstURL, legacy: nil) == [edited])
        #expect(try Data(contentsOf: otherURL) == untouched)
        let restored = NookSettingsService(kagiTokenStore: tokens,
            userDefaults: defaults, boostStore: BoostStore(fileURL: firstURL))
        await restored.waitForBoosts()
        #expect(restored.boosts == [edited])
        #expect(tokens.loads == 0)
    }
}
