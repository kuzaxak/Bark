// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import WebKit
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
@testable import NookWeb

@MainActor
struct ProfileEngineTests {
    #if os(macOS)
    @Test func chromiumMetadataHasNoWebKitStorageOrCookieConnection() async {
        let id = UUID()
        let profile = Profile(id: id, name: "Work", icon: "person", engine: .chromium)
        #expect(profile.engine == .chromium)
        #expect(profile.webKitDataStore == nil)
        profile.name = "Renamed"
        profile.icon = "folder"
        #expect(profile.id == id && profile.name == "Renamed")
        #expect(profile.webKitDataStore == nil)
        #expect(await profile.validateDataStore() == false)
        let privateProfile = Profile.createEphemeral(engine: .chromium)
        #expect(privateProfile.isEphemeral && privateProfile.engine == .chromium)
        #expect(privateProfile.webKitDataStore == nil)
        #expect(privateProfile.id != id)
    }

    @Test func nativeFactoriesReuseStoreUUIDAndKeepNativeMetadataAfterRestart() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "person",
            accentHex: "#123456", after: nil))
        let shared = try #require(tabs.createSpace(name: "Shared", icon: "folder",
            accentHex: "#123456", after: work, sharingLoginsWith: work))
        let personal = try #require(tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: shared))
        let profile = try #require(tabs.profile(forSpace: work))
        #expect(profile === tabs.profile(forSpace: shared))
        #expect(profile !== tabs.profile(forSpace: personal))
        #expect(profile.id == tabs.tree.dataStoreID(for: work))
        #expect(profile.webKitDataStore == nil)
        tabs.updateSpace(work, name: "Renamed", icon: nil, accentHex: nil)
        #expect(tabs.profile(forSpace: work) === profile)
        #expect(profile.name == "Renamed" && profile.webKitDataStore == nil)
        let id = profile.id
        tabs.deleteSpace(work, keepingLeftProfile: true)
        tabs.deleteSpace(shared, keepingLeftProfile: true)
        tabs.saveNow()
        let reloaded = fixture.makeTabs(engine: .chromium)
        let kept = try #require(reloaded.profile(forStore: id))
        #expect(kept.id == id && kept.engine == .chromium)
        #expect(kept.webKitDataStore == nil)
        #expect(kept === reloaded.profile(forStore: id))
    }

    @Test func unsupportedNativeDestructionAndReassignmentPreserveMetadata() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let space = try #require(tabs.createSpace(name: "Work", icon: "person",
            accentHex: "#123456", after: nil))
        let profile = try #require(tabs.profile(forSpace: space))
        let originalStore = tabs.tree.dataStoreID(for: space)
        tabs.setProfile(space, to: UUID())
        #expect(tabs.tree.dataStoreID(for: space) == originalStore)
        tabs.deleteSpace(space)
        #expect(tabs.tree.space(space) != nil)
        #expect(tabs.profile(forSpace: space) === profile)
        tabs.deleteSpace(space, keepingLeftProfile: true)
        #expect(tabs.tree.space(space) == nil)
        #expect(tabs.device.keptProfiles?.contains { $0.id == profile.id } == true)
        tabs.deleteKeptProfile(profile.id)
        #expect(tabs.device.keptProfiles?.contains { $0.id == profile.id } == true)
        #expect(tabs.profile(forStore: profile.id) === profile)
    }

    @Test func nativePageConstructionAndFaviconRequestsDoNotEnterWebKit() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let url = URL(string: "https://native-favicon.invalid/page")!
        let page = PageSession(itemID: UUID(), url: url, title: "Native",
                               isPrivate: false, controller: tabs)
        #expect(page.faviconFetchAttempts == 0 && !page.faviconFetchInFlight)
        page.loadWebViewIfNeeded()
        #expect(page.webView == nil && page.isUnloaded)
        page.ensureFaviconLoaded()
        await page.fetchAndSetFavicon(for: url)
        #expect(page.faviconFetchAttempts == 0 && !page.faviconFetchInFlight)
        #expect(!page.hasFavicon)
        let profile = Profile(name: "Native", engine: .chromium)
        #expect(await tabs.clearData(of: profile) == false)
        #expect(profile.webKitDataStore == nil)
        page.unload()
    }
    #endif

    @Test func defaultPrivateWebKitStorageStillOwnsAndClearsItsCookies() async throws {
        let profile = Profile.createEphemeral()
        let store = try #require(profile.webKitDataStore)
        #expect(profile.engine == .webKit && profile.isEphemeral)
        #expect(!store.isPersistent && profile.dataStore === store)
        let cookie = try #require(HTTPCookie(properties: [
            .name: "owned-test", .value: "one", .domain: "profile.invalid", .path: "/"]))
        await store.httpCookieStore.setCookie(cookie)
        await profile.refreshDataStoreStats()
        #expect(profile.cachedCookieCount == 1)
        await profile.clearAllData()
        #expect(profile.cachedCookieCount == 0)
    }
}

@MainActor
private final class ProfileFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    init() throws {
        suite = "NookProfileEngineTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func makeTabs(engine: Profile.Engine) -> TabsController {
        let settings = NookSettingsService(kagiTokenStore: NoTokenStore(), userDefaults: defaults)
        return TabsController(settings: settings, windowRegistry: WindowRegistry(),
            blocker: ContentBlockerManager(settings: settings),
            sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings),
            profileEngine: engine, directory: directory.appendingPathComponent("Tabs"))
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct NoTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}
