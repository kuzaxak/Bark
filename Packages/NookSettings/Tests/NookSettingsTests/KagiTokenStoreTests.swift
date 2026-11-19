// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import Security
@testable import NookSettings

final class CountingKagiTokenStore: KagiTokenStore, @unchecked Sendable {
    var stored: String?
    private(set) var loads = 0

    init(stored: String? = nil) { self.stored = stored }

    func load() -> String? {
        loads += 1
        return stored
    }

    func save(_ token: String?) { stored = token }
}

@MainActor
struct KagiTokenStoreTests {
    @Test func nativeNamespaceNeverSelectsLegacyKeychainItem() {
        let native = KagiSession.baseQuery()
        let isolated = KagiSession.baseQuery(service: "synthetic.kagi")
        #expect(native[kSecAttrService as String] as? String == "NookChromium Kagi Session Link")
        #expect(isolated[kSecAttrService as String] as? String == "synthetic.kagi")
        #expect(native[kSecAttrAccount as String] as? String == isolated[kSecAttrAccount as String] as? String)
        // Pure query construction: no Security/Keychain operation is executed.
    }

    @Test func creatingSettingsReadsNoToken() {
        let store = CountingKagiTokenStore(stored: "abc")
        let suite = "NookKagiTokenTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NookSettingsService(kagiTokenStore: store, userDefaults: defaults)
        #expect(store.loads == 0)
    }

    @Test func plaintextAICleanupOnlyAffectsExplicitlyOwnedSuite() {
        let ownedName = "BarkSettingsOwnedAI-\(UUID())"
        let unrelatedName = "BarkSettingsUnrelatedAI-\(UUID())"
        let owned = UserDefaults(suiteName: ownedName)!
        let unrelated = UserDefaults(suiteName: unrelatedName)!
        defer {
            owned.removePersistentDomain(forName: ownedName)
            unrelated.removePersistentDomain(forName: unrelatedName)
        }
        let legacy = ["settings.geminiApiKey": "fake-gemini", "settings.openRouterApiKey": "fake-openrouter"]
        for (key, value) in legacy {
            owned.set(value, forKey: key)
            unrelated.set(value, forKey: key)
        }
        owned.set("provider", forKey: "settings.aiProvider")

        _ = NookSettingsService(kagiTokenStore: CountingKagiTokenStore(), userDefaults: unrelated)
        NookSettingsService.removeObsoletePlaintextAIKeys(from: owned)

        for (key, value) in legacy {
            #expect(owned.object(forKey: key) == nil)
            #expect(unrelated.string(forKey: key) == value)
        }
        #expect(owned.string(forKey: "settings.aiProvider") == "provider")
    }

    @Test func firstUseReadsOnceAndKeepsTheToken() {
        let store = CountingKagiTokenStore(stored: "abc")
        let suite = "NookKagiTokenTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NookSettingsService(kagiTokenStore: store, userDefaults: defaults)
        #expect(settings.kagiSessionToken == "abc")
        #expect(settings.kagiSessionToken == "abc")
        #expect(store.loads == 1)
    }

    @Test func kagiSearchTemplateReadsTheTokenOnlyForKagi() {
        let store = CountingKagiTokenStore(stored: "abc")
        let suite = "NookKagiTokenTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NookSettingsService(kagiTokenStore: store, userDefaults: defaults)
        #expect(settings.searchTemplate(for: SearchProvider.google.rawValue) == SearchProvider.google.queryTemplate)
        #expect(store.loads == 0)
        #expect(settings.searchTemplate(for: SearchProvider.kagi.rawValue) == KagiSession.searchTemplate(token: "abc"))
        #expect(store.loads == 1)
    }

    @Test func savingReplacesTheTokenWithoutReading() {
        let store = CountingKagiTokenStore(stored: "old")
        let suite = "NookKagiTokenTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NookSettingsService(kagiTokenStore: store, userDefaults: defaults)
        settings.setKagiSession("new")
        #expect(settings.kagiSessionToken == "new")
        #expect(store.stored == "new")
        settings.setKagiSession(nil)
        #expect(settings.kagiSessionToken == nil)
        #expect(store.stored == nil)
        #expect(store.loads == 0)
    }
}
