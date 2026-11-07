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

    @Test func profileControlsRouteEveryDestinationToRequestedInactiveProfileWithoutTreeEdits() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "person", accentHex: "#123456", after: nil))
        let personal = try #require(tabs.createSpace(name: "Personal", icon: "house", accentHex: "#123456", after: work))
        let profileID = try #require(tabs.tree.dataStoreID(for: work))
        let window = BrowserWindowState()
        tabs.windowRegistry.register(window)
        tabs.windowRegistry.setActive(window)
        window.spaceID = personal
        let original = tabs.tree
        var observed: [ProfilePageDestination] = []
        var successes = 0
        tabs.onOpenProfilePage = { profile, destination, canPresent, completion in
            #expect(profile.id == profileID && profile.name == "Work")
            #expect(canPresent())
            observed.append(destination)
            completion(.success(()))
        }
        for destination in ProfilePageDestination.allCases {
            tabs.openProfilePage(profileID: profileID, destination: destination) {
                if case .success = $0 { successes += 1 }
            }
        }
        #expect(observed == [.settings, .extensions, .privacy, .siteSettings, .clearData])
        #expect(successes == 5 && tabs.tree == original)
        #expect(window.spaceID == personal && window.selectedItemID == nil)
    }

    @Test func keptProfileControlsNeedNoWindowOrSpaceAssignment() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "person", accentHex: "#123456", after: nil))
        let profileID = try #require(tabs.tree.dataStoreID(for: work))
        tabs.deleteSpace(work, keepingLeftProfile: true)
        let original = tabs.tree
        let kept = tabs.device.keptProfiles
        var invoked = false
        tabs.onOpenProfilePage = { profile, destination, canPresent, completion in
            #expect(profile.id == profileID && profile.spaceIDs.isEmpty)
            #expect(destination == .extensions && canPresent())
            invoked = true
            completion(.success(()))
        }
        tabs.openProfilePage(profileID: profileID, destination: .extensions) { result in
            if case .failure = result { Issue.record("Kept profile routing unexpectedly failed") }
        }
        #expect(invoked && tabs.windowRegistry.windows.isEmpty)
        #expect(tabs.tree == original && tabs.device.keptProfiles == kept)
    }

    @Test func staleProfileAdmissionFailsOnceWithoutFallback() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "person", accentHex: "#123456", after: nil))
        let profileID = try #require(tabs.tree.dataStoreID(for: work))
        var canPresent: (@MainActor () -> Bool)?
        var finish: (@MainActor (Result<Void, ProfilePageOpenError>) -> Void)?
        tabs.onOpenProfilePage = { profile, _, valid, completion in
            #expect(profile.id == profileID)
            canPresent = valid
            finish = completion
        }
        var errors: [ProfilePageOpenError] = []
        tabs.openProfilePage(profileID: profileID, destination: .clearData) {
            if case .failure(let error) = $0 { errors.append(error) }
        }
        #expect(canPresent?() == true)
        // A received tree edit can remove the target while native presentation is queued.
        _ = tabs.perform(.main, "incoming profile removal") { try $0.deleteSpace(work).change }
        #expect(canPresent?() == false)
        finish?(.success(()))
        finish?(.success(()))
        #expect(errors == [.profileUnavailable])
        tabs.onOpenProfilePage = { _, _, _, _ in Issue.record("Deleted profile reached presenter") }
        tabs.openProfilePage(profileID: profileID, destination: .settings) {
            if case .failure(let error) = $0 { errors.append(error) }
        }
        #expect(errors == [.profileUnavailable, .profileUnavailable])
    }

    @Test func absentProfilePresenterReportsUnavailableWithoutOpeningOrMutating() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let profile = try #require(tabs.profiles.first)
        let original = tabs.tree
        var error: ProfilePageOpenError?
        tabs.openProfilePage(profileID: profile.id, destination: .siteSettings) {
            if case .failure(let failure) = $0 { error = failure }
        }
        #expect(error == .presentationUnavailable && tabs.tree == original)
        #expect(tabs.sessions.isEmpty && tabs.windowRegistry.windows.isEmpty)
    }

    @Test func nativeLiveSourcesReportUnavailableWithoutStartingLegacyFetches() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let space = try #require(tabs.tree.orderedSpaces.first?.id)
        let profile = try #require(tabs.profile(forSpace: space))
        let sources: [LiveSource] = [.githubPulls, .githubIssues, .githubNotifications, .asanaTasks]
        var folders: [UUID] = []
        for source in sources {
            let folder = try #require(tabs.createLiveFolder(source, in: space))
            folders.append(folder)
            tabs.refreshLiveFolder(folder, force: true)
            #expect(tabs.liveStatus[folder] == .unavailable)
        }
        let item = try #require(tabs.children(of: .tabs(spaceID: space)).first?.id)
        tabs.pageCommitted(itemID: item, url: URL(string: "https://github.com/synthetic/repo/pull/1")!)
        tabs.refreshLiveFolders(inSpace: space)
        #expect(await tabs.pullRequests(inSpace: space) == [])
        #expect(await tabs.gmailInbox(inSpace: space, account: 0) == .unavailable)
        await Task.yield()
        #expect(profile.webKitDataStore == nil)
        #expect(tabs.liveRefreshing.isEmpty && tabs.liveRefreshed.isEmpty)
        #expect(folders.allSatisfy { tabs.liveStatus[$0] == .unavailable })
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
