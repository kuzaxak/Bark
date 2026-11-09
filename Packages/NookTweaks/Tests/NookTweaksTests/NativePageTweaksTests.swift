import Foundation
import Testing
import NookSettings
@testable import NookTweaks
private struct NoTokens: KagiTokenStore { func load() -> String? { nil }; func save(_ token: String?) {} }
@Suite @MainActor struct NativePageTweaksTests {
    @Test func fixedSnapshotKeepsOptInOrderAndBlockerIndependence() async throws {
        let name = "native-tweaks-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: dir) }
        let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: dir.appendingPathComponent("Boosts.json")))
        await settings.waitForBoosts()
        settings.facebookHideReels = true; settings.facebookHideSuggested = true
        settings.redditSortHot = true; settings.youTubeHideShorts = true
        var first = Boost(host: "example.test", script: "await Promise.resolve();return 1;", scriptEnabled: true)
        var off = first; off.id = UUID(); off.scriptEnabled = false
        var disabled = first; disabled.id = UUID(); disabled.isEnabled = false
        var second = first; second.id = UUID(); second.includeSubdomains = false; second.script = "throw Error('later scripts still run');"
        settings.boosts = [first, off, disabled, second]
        settings.adBlockerEnabled = false
        let snapshot = try NativePageTweaks(settings: settings)
        #expect(snapshot.scripts.map(\.source) == [first.script, second.script])
        #expect(snapshot.scripts.map(\.includeSubdomains) == [true, false])
        #expect(snapshot.facebookReels && snapshot.facebookSuggested && snapshot.redditHot)
        #expect(!snapshot.youtube.css.isEmpty)
        settings.adBlockerEnabled = true
        #expect(try NativePageTweaks(settings: settings) == snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        #expect(json["version"] as? Int == 1 && json.keys.count == 8)
        settings.mediaDownloadSites = [" EXAMPLE.test ", "bad/path", ""]
        #expect(try NativePageTweaks(settings: settings).mediaDownloadSites == ["example.test"])
        settings.sponsorBlockEnabled = true
        settings.sponsorBlockCategoryOptions = ["sponsor": "auto", "intro": "manual", "outro": "disabled", "unknown": "auto"]
        #expect(try NativePageTweaks(settings: settings).sponsorBlock == ["sponsor": "auto", "intro": "manual"])
        settings.sponsorBlockEnabled = false
        #expect(try NativePageTweaks(settings: settings).sponsorBlock.isEmpty)
        first.scriptEnabled = false; settings.boosts = [first]
        #expect(try NativePageTweaks(settings: settings).scripts.isEmpty)
    }
    @Test func invalidSavedSourceIsExplicitlyRefused() async throws {
        let name = "native-tweaks-invalid-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: dir) }
        let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: dir.appendingPathComponent("Boosts.json")))
        await settings.waitForBoosts()
        let boost = Boost(host: "example.test", script: String(repeating: "x", count: Boost.maxScriptBytes + 1), scriptEnabled: true)
        settings.boosts = [boost]
        do { _ = try NativePageTweaks(settings: settings); Issue.record("Oversized saved script accepted") }
        catch NativePageTweaks.Failure.invalidSavedScript {}
        #expect(settings.boosts == [boost])
    }
}
