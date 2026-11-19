// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
@testable import NookWeb

/// A tab opened from a link in the background loads at once, as in Arc; a tab made in the
/// background any other way waits until it is selected.
@MainActor
struct BackgroundLinkTabTests {
    let link = URL(string: "https://link.invalid/article")!

    @Test func linkOpenedInBackgroundLoadsAndKeepsSelection() throws {
        let host = try Host(); defer { host.cleanup() }
        let opener = try #require(host.window.selectedItemID)
        let child = try #require(host.tabs.open(url: link, in: host.window, placement: .background, from: opener))

        #expect(host.window.selectedItemID == opener)
        let page = try #require(host.tabs.session(for: child))
        #expect(!page.isUnloaded)
        #expect((page.navigation as? NativeTestPage)?.loaded == [link])
        #expect(host.backgroundLoads == [child])
    }

    @Test func linkOpenedInBackgroundInPrivateWindowLoads() throws {
        let host = try Host(isPrivate: true); defer { host.cleanup() }
        let spaceID = try #require(host.window.spaceID)
        let opener = try #require(host.tabs.open(url: URL(string: "https://opener.invalid")!, in: host.window,
                                                 placement: .newTab, parent: .tabs(spaceID: spaceID)))
        let child = try #require(host.tabs.open(url: link, in: host.window, placement: .background, from: opener))

        #expect(host.window.selectedItemID == opener)
        let page = try #require(host.tabs.session(for: child))
        #expect(page.isPrivate)
        let profile = try #require(host.window.ephemeralProfile)
        #expect(profile.isEphemeral && page.navigation?.profileID == profile.id)
        #expect(host.tabs.tree.item(child) == nil)
        #expect((page.navigation as? NativeTestPage)?.loaded == [link])
    }

    @Test func backgroundTabWithoutOpenerWaitsForSelection() throws {
        let host = try Host(); defer { host.cleanup() }
        let spaceID = try #require(host.window.spaceID)
        let creationCount = host.native.creates.count

        let imported = try #require(host.tabs.open(url: link, in: host.window, placement: .background,
                                                   parent: .tabs(spaceID: spaceID)))

        #expect(host.tabs.session(for: imported)?.isUnloaded ?? true)
        #expect(host.backgroundLoads.isEmpty && host.native.creates.count == creationCount)
        host.tabs.select(imported, in: host.window)
        #expect(host.window.selectedItemID == imported)
        #expect((host.tabs.session(for: imported)?.navigation as? NativeTestPage)?.loaded == [link])
    }
}

/// A native tab model, using disposable settings and deterministic engine callbacks.
@MainActor
final class Host {
    let tabs: TabsController
    let window = BrowserWindowState()
    let registry = WindowRegistry()
    let native = ControlledNativeHost()
    private let directory: URL
    private let defaults: UserDefaults
    private let suite = "NookWebTests-\(UUID().uuidString)"
    private(set) var backgroundLoads: [UUID] = []

    init(isPrivate: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = NookSettingsService(kagiTokenStore: HostNoTokenStore(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: directory.appendingPathComponent("Boosts.json")))
        tabs = TabsController(
            settings: settings, windowRegistry: registry,
            blocker: ContentBlockerManager(settings: settings, storageDirectory: directory.appendingPathComponent("Blocker")),
            siteRouting: SiteRoutingManager(settings: settings), directory: directory)
        tabs.onPageLoadedInBackground = { [weak self] in self?.backgroundLoads.append($0.itemID) }
        if isPrivate {
            window.isIncognito = true
            window.ephemeralProfile = Profile.createEphemeral()
        }
        registry.register(window)
        registry.setActive(window)
        tabs.attach(window: window)
        native.synchronous = true
        tabs.nativePageHost = native
    }

    func cleanup() {
        tabs.saveNow()
        tabs.settings.flushBoosts()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The items of the tree this window shows.
    func items() -> Set<UUID> {
        Set((window.privateTree ?? tabs.tree).items.keys)
    }
}

private struct HostNoTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}
