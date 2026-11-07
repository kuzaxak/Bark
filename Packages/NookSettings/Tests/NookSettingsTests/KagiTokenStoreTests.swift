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
        let native = KagiSession.baseQuery(service: "NookChromium Kagi Session Link")
        let legacy = KagiSession.baseQuery()
        #expect(native[kSecAttrService as String] as? String == "NookChromium Kagi Session Link")
        #expect(legacy[kSecAttrService as String] as? String == "Nook Kagi Session Link")
        #expect(native[kSecAttrAccount as String] as? String == legacy[kSecAttrAccount as String] as? String)
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
