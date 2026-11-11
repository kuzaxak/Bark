// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookSettings
import NookAdblockFFI
import Testing
import WebKit
@testable import NookBlocker

@MainActor
struct NativeBlockerModelTests {
    private func drainSettings() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test func persistedNativePolicySeedsFirstCompilationAndExport() async throws {
        let optional = try #require(FilterListManager.optionalLists.first)
        let whitelist = ["ADS.TEST", "allowed.test", "ads.test"]
        let f = try NativeBlockerFixture(persistedWhitelist: whitelist, persistedOptionalLists: [optional.filename])
        defer { f.cleanup() }
        #expect(f.settings.adBlockerWhitelist == whitelist)
        #expect(f.settings.enabledOptionalFilterLists == [optional.filename])
        #expect(f.manager.networkAllowedDomains == ["ads.test", "allowed.test"])
        #expect(f.manager.filterListManager.enabledOptionalFilterListFilenames == [optional.filename])
        #expect(f.manager.networkRules == nil)
        f.manager.setEnabled(f.settings.adBlockerEnabled)
        await f.manager.activationTask?.value
        #expect(f.manager.lastBuildSucceeded && f.manager.networkBlockingRequested)
        let first = try #require(f.manager.networkRules)
        let restored = try #require(first.bytes.withUnsafeBytes {
            nook_adblock_engine_deserialize($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        })
        defer { nook_adblock_engine_free(restored) }
        #expect("https://optional.test/ad.png".withCString { url in
            "https://site.test/".withCString { source in
                "image".withCString { nook_adblock_engine_matches(restored, url, source, $0) }
            }
        })
        #expect(!f.manager.shouldApplyBlocking(to: NativeBlockerPage("https://sub.ads.test/")))
        #expect(f.manager.shouldApplyBlocking(to: NativeBlockerPage("https://other.test/")))
        // Seeding reads persisted choices; it must not rewrite/canonicalize them.
        #expect(f.settings.adBlockerWhitelist == whitelist)
        #expect(f.settings.enabledOptionalFilterLists == [optional.filename])
    }

    @Test func aPrivatePageSavesNoSiteChoice() throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        let page = NativeBlockerPage("https://ads.test/"), regular = NativeBlockerPage("https://ads.test/")
        page.isPrivate = true
        f.host.pages = [page, regular]
        f.manager.attach(host: f.host)
        #expect(!f.manager.allowDomain("ads.test", from: page), "a private window's page is refused")
        #expect(!f.manager.isDomainAllowed("ads.test") && f.settings.adBlockerWhitelist.isEmpty)
        #expect(page.reloads == 0 && regular.reloads == 0, "nothing reloads for a refused choice")
        #expect(f.manager.allowDomain("ads.test", from: regular))
        #expect(f.manager.isDomainAllowed("ads.test") && f.settings.adBlockerWhitelist == ["ads.test"])
        #expect(f.manager.allowDomain("ads.test", allowed: false, from: nil), "Settings has no page")
        #expect(f.settings.adBlockerWhitelist.isEmpty)
    }

    @Test func nativeBuildUsesSamePolicyWithoutTouchingWebKit() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        let first = NativeBlockerPage("https://ads.test/"), second = NativeBlockerPage("https://ads.test/")
        f.host.pages = [first, second]
        f.manager.attach(host: f.host)
        f.manager.setEnabled(true)
        await f.manager.activationTask?.value
        #expect(f.manager.isEnabled && f.manager.lastBuildSucceeded)
        #expect(f.manager.networkRules != nil)
        #expect(f.manager.advancedRulesEngine.engine.matches(url: "https://ads.test/ad.js", sourceURL: "https://site.test/", type: "script"))
        #expect(f.manager.shouldApplyBlocking(to: first))
        f.manager.allowDomain("ADS.TEST", from: nil)
        #expect(!f.manager.shouldApplyBlocking(to: first) && !f.manager.shouldApplyBlocking(to: second))
        #expect(first.reloads == 1 && second.reloads == 1)
        f.manager.allowDomain("ads.test", allowed: false, from: nil)
        f.manager.disableTemporarily(for: first, duration: 60)
        #expect(!f.manager.shouldApplyBlocking(to: first) && f.manager.shouldApplyBlocking(to: second))
        second.isOAuthFlow = true
        #expect(!f.manager.shouldApplyBlocking(to: second))
        second.isOAuthFlow = false
        f.manager.continueToBlockedPage(second.blockingURL!, in: second)
        #expect(!f.manager.shouldApplyBlocking(to: second))
        second.blockingURL = URL(string: "https://other.test/")!
        #expect(f.manager.shouldApplyBlocking(to: second))
        second.blockingURL = URL(string: "https://ads.test/")!
        #expect(f.manager.shouldApplyBlocking(to: second))
        #expect(await f.manager.setUserCosmeticRules(["ads.test##.advert"]) == false)
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("Cache/engine.dat").path))
    }

    @Test func exportedExceptionsPreservePendingTargetAndExactTab() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        let first = NativeBlockerPage("https://old.test/"), second = NativeBlockerPage("https://old.test/")
        f.host.pages = [first, second]
        f.manager.attach(host: f.host)
        f.manager.setEnabled(true)
        #expect(f.manager.networkBlockingRequested)
        await f.manager.activationTask?.value
        let target = URL(string: "https://blocked.test/path")!
        #expect(f.manager.continueToBlockedPage(target, in: first))
        #expect(first.blockingURL?.host == "old.test")
        #expect(first.policies.last?.continuedHost == "blocked.test")
        #expect(second.policies.isEmpty)
        #expect(f.manager.networkPolicy(for: second).continuedHost == nil)
        first.blockingURL = target
        #expect(!f.manager.shouldApplyBlocking(to: first))
        first.blockingURL = URL(string: "https://destination.test/")!
        #expect(f.manager.shouldApplyBlocking(to: first))
        #expect(f.manager.networkPolicy(for: first).continuedHost == nil)
        f.manager.disableTemporarily(for: first, duration: 60)
        let deadline = try #require(f.manager.networkPolicy(for: first).disabledUntil)
        first.isOAuthFlow = true
        #expect(f.manager.networkPolicy(for: first).disabledUntil == deadline)
        #expect(f.manager.networkPolicy(for: first).isOAuthFlow)
        #expect(f.manager.networkPolicy(for: second).disabledUntil == nil)
        f.manager.allowDomain("ALLOWED.TEST", from: nil)
        #expect(f.manager.networkAllowedDomains == ["allowed.test"])
        // Read current user intent before the deferred settings observer runs.
        f.settings.adBlockerEnabled = false
        #expect(!f.manager.networkBlockingRequested)
    }

    @Test func nativeExceptionsReachExactPageBeforeReloadAndRefusalDoesNotReload() throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        let page = NativeBlockerPage("https://old.test/")
        f.manager.disableTemporarily(for: page, duration: 60)
        #expect(page.reloads == 1 && page.policies.count == 1)
        #expect(page.policyAtReload?.disabledUntil != nil)
        page.isOAuthFlow = true
        f.manager.refreshNetworkPolicy(for: page)
        #expect(page.policies.last?.isOAuthFlow == true && page.reloads == 1)
        let target = URL(string: "https://blocked.test/path")!
        #expect(f.manager.continueToBlockedPage(target, in: page))
        #expect(page.policies.last?.continuedHost == "blocked.test")
        page.blockingURL = target
        let policies = page.policies.count
        f.manager.refreshNetworkPolicy(for: page, navigationStarted: true)
        #expect(page.policies.last?.continuedHost == "blocked.test" && page.policies.count == policies)
        page.blockingURL = URL(string: "https://destination.test/")!
        f.manager.refreshNetworkPolicy(for: page, navigationStarted: true)
        #expect(page.policies.last?.continuedHost == nil)
        page.acceptPolicy = false
        f.manager.disableTemporarily(for: page, duration: 60)
        #expect(page.reloads == 1)
        #expect(!f.manager.continueToBlockedPage(target, in: page))
    }

    @Test func disableWhileActivationPendingCannotPublishOrReenable() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        f.manager.setEnabled(true)
        let old = try #require(f.manager.activationTask)
        f.settings.adBlockerEnabled = false
        await old.value
        await drainSettings()
        #expect(!f.manager.isEnabled && !f.manager.isCompiling && f.manager.networkRules == nil)
        f.settings.adBlockerEnabled = true
        await drainSettings()
        await f.manager.activationTask?.value
        #expect(f.manager.isEnabled && f.manager.networkRules != nil)
    }

    @Test func changedOptionalSourcesSupersedePendingActivationAndStayIsolated() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        let other = try NativeBlockerFixture(); defer { other.cleanup() }
        f.manager.setEnabled(true)
        let old = try #require(f.manager.activationTask)
        let optional = try #require(FilterListManager.optionalLists.first)
        f.settings.enabledOptionalFilterLists = [optional.filename]
        await old.value
        await drainSettings()
        await f.manager.activationTask?.value
        #expect(f.manager.isEnabled && f.manager.lastBuildSucceeded)
        #expect(f.manager.advancedRulesEngine.engine.matches(url: "https://optional.test/ad.png", sourceURL: "https://site.test/", type: "image"))
        #expect(other.manager.networkRules == nil && !other.manager.isEnabled)
        f.settings.adBlockerWhitelist = ["site.test"]
        await drainSettings()
        #expect(f.manager.isDomainAllowed("child.site.test") && !f.manager.isDomainAllowed("notsite.test"))
        #expect(!other.manager.isDomainAllowed("site.test"))
    }

    @Test func sameTurnEnableAndSourceEditBuildsOnlyLatestPolicy() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        f.settings.adBlockerEnabled = false
        await drainSettings()
        f.settings.adBlockerEnabled = true
        f.settings.enabledOptionalFilterLists = [try #require(FilterListManager.optionalLists.first).filename]
        await drainSettings()
        await f.manager.activationTask?.value
        await drainSettings()
        await f.manager.activationTask?.value
        #expect(f.manager.isEnabled && !f.manager.isCompiling)
        #expect(f.manager.networkRules?.generation == 1)
        #expect(f.manager.advancedRulesEngine.engine.matches(url: "https://optional.test/ad.png", sourceURL: "https://site.test/", type: "image"))
    }

    @Test func supersededSettingsDoNotPublishProducerFailureBeforeObservation() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        let observer = NotificationCenter.default.addObserver(forName: .adBlockerStateChanged,
            object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard note.object as? ContentBlockerManager === f.manager else { return }
                if f.manager.networkSourceSucceeded == false { f.sawSupersededFailure = true }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        f.manager.setEnabled(true)
        let older = try #require(f.manager.activationTask)
        let token = f.manager.networkSourceGeneration
        // The older producer is queued before this settings observation Task.
        f.settings.enabledOptionalFilterLists = [try #require(FilterListManager.optionalLists.first).filename]
        await older.value
        await drainSettings()
        await f.manager.activationTask?.value
        #expect(!f.sawSupersededFailure)
        #expect(f.manager.networkSourceGeneration > token && f.manager.networkSourceSucceeded == true)
        #expect(f.manager.advancedRulesEngine.engine.matches(url: "https://optional.test/ad.png", sourceURL: "https://site.test/", type: "image"))
    }

    @Test func settingsRefusalClearsOnlyItsOwnCompilingState() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        f.settings.adBlockerEnabled = false
        await drainSettings()
        // A mismatched public request must not leave a permanently busy adapter.
        f.manager.setEnabled(true)
        await f.manager.activationTask?.value
        #expect(!f.manager.isEnabled && !f.manager.isCompiling && f.manager.networkRules == nil)
        f.settings.adBlockerEnabled = true
        await drainSettings()
        await f.manager.activationTask?.value
        #expect(f.manager.isEnabled && f.manager.networkRules != nil)
    }

    @Test func requestedEnablementPublishesBeforeRulesAndLaterDisableWins() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        let observer = NotificationCenter.default.addObserver(forName: .adBlockerStateChanged,
            object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard note.object as? ContentBlockerManager === f.manager else { return }
                f.observedEnabled.append(f.manager.networkBlockingRequested)
                guard f.manager.networkBlockingRequested else { return }
                f.sawInitialRequestedPolicy = f.manager.isCompiling && f.manager.networkRules == nil &&
                    f.manager.networkSourceGeneration != 0 && f.manager.networkSourceSucceeded == nil
                f.initialActivation = f.manager.activationTask
                f.settings.adBlockerEnabled = false
                f.manager.setEnabled(false)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        f.manager.setEnabled(true)
        #expect(f.sawInitialRequestedPolicy)
        let old = try #require(f.initialActivation)
        await old.value
        await drainSettings()
        #expect(f.observedEnabled == [true, false])
        #expect(!f.manager.networkBlockingRequested && !f.manager.isEnabled && !f.manager.isCompiling)
        #expect(f.manager.networkRules == nil)
    }

    @Test func noOpRefreshKeepsAcceptedSourceAndCancelledProducerSettlesFailure() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        f.manager.setEnabled(true)
        await f.manager.activationTask?.value
        let accepted = f.manager.networkSourceGeneration
        let rules = try #require(f.manager.networkRules)
        #expect(f.manager.networkSourceSucceeded == true)
        f.manager.startNativeBuild(refresh: false)
        #expect(f.manager.isCompiling && f.manager.networkSourceGeneration == accepted && f.manager.networkSourceSucceeded == true)
        await f.manager.activationTask?.value
        #expect(await f.manager.updateFilterLists() == false)
        #expect(f.manager.networkSourceGeneration == accepted)
        #expect(f.manager.networkSourceSucceeded == true)
        #expect(f.manager.networkRules?.generation == rules.generation)
        #expect(f.manager.networkRules?.bytes == rules.bytes)
        // An enabled rebuild may fail while retaining older accepted bytes.
        // A fresh unchanged-download check must recover, not retain failure.
        f.manager.startNativeBuild()
        let failed = try #require(f.manager.activationTask)
        failed.cancel()
        await failed.value
        let failedToken = f.manager.networkSourceGeneration
        #expect(f.manager.isEnabled && f.manager.networkSourceSucceeded == false)
        #expect(f.manager.networkRules?.bytes == rules.bytes)
        _ = await f.manager.updateFilterLists()
        #expect(f.manager.networkSourceGeneration > failedToken)
        #expect(f.manager.networkSourceSucceeded == true && f.manager.networkRules != nil)
        f.manager.setEnabled(false)
        f.manager.setEnabled(true)
        #expect(f.manager.networkSourceGeneration > accepted)
        let producer = try #require(f.manager.activationTask)
        producer.cancel()
        await producer.value
        #expect(f.manager.networkSourceSucceeded == false)
        #expect(!f.manager.isCompiling)
        let other = try NativeBlockerFixture(); defer { other.cleanup() }
        other.manager.setEnabled(true)
        #expect(other.manager.networkSourceGeneration > f.manager.networkSourceGeneration)
        await other.manager.activationTask?.value
    }

    @Test func acceptedNotificationMaySynchronouslyDisableWithoutRescheduling() async throws {
        let f = try NativeBlockerFixture(); defer { f.cleanup() }
        let observer = NotificationCenter.default.addObserver(forName: .adBlockerStateChanged,
            object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard note.object as? ContentBlockerManager === f.manager else { return }
                guard !f.manager.isCompiling else { return } // Initial request has its own regression above.
                f.observedEnabled.append(f.manager.isEnabled)
                guard f.manager.isEnabled else { return }
                f.settings.adBlockerEnabled = false
                f.manager.setEnabled(false)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        f.manager.setEnabled(true)
        let task = try #require(f.manager.activationTask)
        await task.value
        await drainSettings()
        #expect(!f.manager.isEnabled && !f.manager.isCompiling && f.manager.networkRules == nil)
        #expect(f.observedEnabled == [true, false])
    }
}

@MainActor
private final class NativeBlockerFixture {
    let suite = "NativeBlockerModelTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let settings: NookSettingsService
    let manager: ContentBlockerManager
    let host = NativeBlockerHost()
    var observedEnabled: [Bool] = []
    var sawInitialRequestedPolicy = false
    var sawSupersededFailure = false
    var initialActivation: Task<Void, Never>?
    init(persistedWhitelist: [String] = [], persistedOptionalLists: [String] = []) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".etags"), withIntermediateDirectories: true)
        for (index, list) in FilterListManager.defaultLists.enumerated() {
            try (index == 0 ? "||ads.test^$script" : "! synthetic empty list").write(
                to: directory.appendingPathComponent(list.filename), atomically: true, encoding: .utf8)
        }
        for list in FilterListManager.defaultLists + FilterListManager.optionalLists {
            if FilterListManager.optionalLists.first?.filename == list.filename {
                try "||optional.test^$image".write(to: directory.appendingPathComponent(list.filename), atomically: true, encoding: .utf8)
            }
            // Existing update checks see fresh synthetic caches, so tests never fetch.
            try String(Date().timeIntervalSince1970).write(to: directory.appendingPathComponent(".etags/\(list.filename).checked"), atomically: true, encoding: .utf8)
        }
        let persisted = NookSettingsService(kagiTokenStore: NativeBlockerTokenStore(), userDefaults: defaults,
            boostStore: .init(fileURL: directory.appendingPathComponent("Boosts.json")))
        persisted.adBlockerEnabled = true
        persisted.adBlockerWhitelist = persistedWhitelist
        persisted.enabledOptionalFilterLists = persistedOptionalLists
        settings = NookSettingsService(kagiTokenStore: NativeBlockerTokenStore(), userDefaults: defaults,
            boostStore: .init(fileURL: directory.appendingPathComponent("Boosts.json")))
        manager = ContentBlockerManager(settings: settings, storageDirectory: directory, nativeNetworkBlocking: true)
    }
    func cleanup() {
        manager.setEnabled(false)
        settings.flushBoosts()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct NativeBlockerTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@MainActor
private final class NativeBlockerPage: BlockablePage {
    let itemID = UUID()
    var isOAuthFlow = false
    var isPrivate = false
    var blockingURL: URL?
    var reloads = 0
    var policies: [ContentBlockerManager.NetworkPagePolicy] = []
    var policyAtReload: ContentBlockerManager.NetworkPagePolicy?
    var acceptPolicy = true
    init(_ url: String) { blockingURL = URL(string: url)! }
    var webView: WKWebView? { fatalError("Native policy must not query WebKit") }
    func applyNetworkBlockingPolicy(_ policy: ContentBlockerManager.NetworkPagePolicy) -> Bool {
        policies.append(policy); return acceptPolicy
    }
    func reloadForBlocking() -> Bool {
        policyAtReload = policies.last; reloads += 1; return true
    }
}

@MainActor
private final class NativeBlockerHost: ContentBlockerHost {
    var pages: [NativeBlockerPage] = []
    var blockablePages: [any BlockablePage] { pages }
    func blockablePage(for webView: WKWebView) -> (any BlockablePage)? { fatalError("Unexpected WK lookup") }
    var sharedUserContentController: WKUserContentController { fatalError("Unexpected WK controller") }
    func onNewUserContentController(_ handler: @escaping @MainActor (WKUserContentController) -> Void) {
        fatalError("Unexpected WK hook")
    }
}
