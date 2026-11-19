// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Observation
import SwiftData
import Testing
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
@testable import NookWeb

private final class SuggestionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var pending: [SuggestionProtocol] = []
    nonisolated(unsafe) private static var next: (@Sendable (URLRequest) -> Void)?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = []; pending = []; next = nil } }
    static func expectRequest(_ callback: @escaping @Sendable (URLRequest) -> Void) { lock.withLock { next = callback } }
    static func finish() {
        let protocols = lock.withLock { let all = pending; pending = []; return all }
        for proto in protocols {
            let response = HTTPURLResponse(url: proto.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Set-Cookie": "synthetic=ignored; Path=/"])!
            proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
            proto.client?.urlProtocol(proto, didLoad: Data("[\"synthetic\",[\"synthetic remote result\"]]".utf8))
            proto.client?.urlProtocolDidFinishLoading(proto)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let callback = Self.lock.withLock {
            Self.recorded.append(request); Self.pending.append(self)
            let callback = Self.next; Self.next = nil; return callback
        }
        callback?(request)
    }
    override func stopLoading() { Self.lock.withLock { Self.pending.removeAll { $0 === self } } }
}

@MainActor
private final class SuggestionFixture {
    private let directory: URL
    private let suite: String
    let defaults: UserDefaults
    let tabs: TabsController
    let window: BrowserWindowState
    let workPage: PageSession
    let personalPage: PageSession
    let workProfile: UUID
    let personalProfile: UUID
    let workSpace: UUID
    let manager: SearchManager
    let session: URLSession
    var lookups: [UUID] = []
    var onLookup: ((UUID, @escaping @MainActor (Result<ProfileSearchState, Error>) -> Void) -> Void)?
    init() throws {
        SuggestionProtocol.reset()
        suite = "NookSuggestionTargetTests-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = NookSettingsService(kagiTokenStore: SuggestionNoTokens(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: directory.appendingPathComponent("Boosts.json")))
        let registry = WindowRegistry()
        tabs = TabsController(settings: settings, windowRegistry: registry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: directory.appendingPathComponent("Tabs"))
        workSpace = try #require(tabs.tree.orderedSpaces.first?.id)
        let personalSpace = try #require(tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: workSpace))
        workProfile = try #require(tabs.tree.dataStoreID(for: workSpace))
        personalProfile = try #require(tabs.tree.dataStoreID(for: personalSpace))
        #expect(workProfile != personalProfile)
        let workWindow = BrowserWindowState(); workWindow.spaceID = workSpace; registry.register(workWindow)
        window = BrowserWindowState(); window.spaceID = personalSpace; registry.register(window); registry.setActive(window)
        let workID = try #require(tabs.open(url: URL(string: "https://work.invalid/")!, in: workWindow, placement: .background))
        let personalID = try #require(tabs.open(url: URL(string: "https://personal.invalid/")!, in: window, placement: .background))
        workPage = try #require(tabs.ensureSession(for: workID)); personalPage = try #require(tabs.ensureSession(for: personalID))
        // Mixed split/Peek attribution: front page is Work, window space Personal.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.protocolClasses = [SuggestionProtocol.self]
        session = URLSession(configuration: configuration)
        manager = SearchManager(suggestionSession: session)
        manager.setTabs(tabs, window: window)
        tabs.onProfileSearch = { [weak self] profile, _, _, _, _, done in
            guard let self else { return done(.failure(ProfileSearchError.unavailable)) }
            self.lookups.append(profile)
            if let onLookup = self.onLookup { onLookup(profile, done) }
            else { done(.success(self.state(profile))) }
        }
    }
    func state(_ profile: UUID) -> ProfileSearchState {
        let provider = profile == workProfile ? "google" : "kagi"
        return ProfileSearchState(version: provider, selected: provider, name: provider,
            controlled: false, managed: false, providers: [], suggestions: provider, kagiSession: true)
    }
    func nextRequest(_ action: () -> Void) async -> URLRequest {
        await withCheckedContinuation { continuation in
            SuggestionProtocol.expectRequest { continuation.resume(returning: $0) }
            action()
        }
    }
    func settle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            @MainActor func observe() {
                var loading = false
                withObservationTracking { loading = manager.isLoading } onChange: {
                    Task { @MainActor in observe() }
                }
                if !loading, !finished { finished = true; continuation.resume() }
            }
            observe()
        }
    }
    func close() {
        manager.clearWebSuggestionTarget(); tabs.onProfileSearch = nil; onLookup = nil
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
private struct SuggestionNoTokens: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@Suite(.serialized)
@MainActor
struct WebSuggestionTargetTests {
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func paletteHistoryUsesTheEditingProfileAcrossWindows(indexed: Bool) async throws {
        let f = try SuggestionFixture()
        defer { f.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexURL = directory.appendingPathComponent("HistoryIndex.sqlite")
        let container = try ModelContainer(for: HistoryEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let history = HistoryManager(context: container.mainContext, profileId: f.workProfile, indexURL: indexed ? indexURL : nil)
        f.manager.setHistoryManager(history)
        let url = URL(string: "https://inbox.invalid/history")!
        await history.importVisitsAndWait([
            HistoryVisit(url: url, title: "Inbox Work", timestamp: Date(), tabId: nil, profileId: f.workProfile),
            HistoryVisit(url: url, title: "Inbox Personal", timestamp: Date(), tabId: nil, profileId: f.personalProfile)
        ])

        func result(query: String) async -> [String] {
            f.manager.clearSuggestions()
            f.manager.searchSuggestions(for: query, scope: .history, includeWebSuggestions: false)
            return await withCheckedContinuation { continuation in
                @MainActor func readResults() {
                    let rows = f.manager.suggestions.map(\.text)
                    guard rows.isEmpty else { continuation.resume(returning: rows); return }
                    withObservationTracking {
                        _ = f.manager.suggestions
                    } onChange: {
                        Task { @MainActor in readResults() }
                    }
                }
                readResults()
            }
        }
        #expect(await result(query: "inbox") == ["Inbox Personal"])
        #expect(await result(query: "") == ["Inbox Personal"])
        history.switchProfile(f.personalProfile)
        var stillEditing = true
        f.manager.setWebSuggestionTarget(for: f.workPage) { stillEditing }
        #expect(await result(query: "inbox") == ["Inbox Work"])
        #expect(f.manager.recordPick(prefix: "inbox", url: url))
        _ = await history.getHistory()
        if indexed {
            let reader = HistoryIndex(fileURL: indexURL, halfLife: 86_400)
            #expect(await reader.picks(profile: f.workProfile).map(\.prefix) == ["inbox"])
            #expect(await reader.picks(profile: f.personalProfile).isEmpty)
        }
        stillEditing = false
        #expect(!f.manager.forgetHistory(url))
        #expect(!f.manager.recordPick(prefix: "stale", url: url))
        f.manager.searchSuggestions(for: "inbox", scope: .history)
        #expect(f.manager.suggestions.isEmpty)

        f.manager.clearWebSuggestionTarget()
        history.switchProfile(f.workProfile)
        #expect(await result(query: "inbox") == ["Inbox Personal"])
        #expect(f.manager.forgetHistory(url))
        #expect(await history.getHistory(profile: f.personalProfile).entries.isEmpty)
        #expect(await history.getHistory(profile: f.workProfile).entries.map(\.title) == ["Inbox Work"])
        f.window.isIncognito = true
        f.manager.searchSuggestions(for: "inbox", scope: .history)
        #expect(f.manager.suggestions.isEmpty && !f.manager.forgetHistory(url))
    }

    @Test(.timeLimit(.minutes(1))) func browserManagementAddressesStayOutOfRemoteSuggestions() async throws {
        let f = try SuggestionFixture(); defer { f.close() }
        _ = await f.nextRequest { f.manager.searchSuggestions(for: "ordinary query") }
        SuggestionProtocol.finish()
        await f.settle()
        try #require(f.manager.suggestions.contains { $0.section == "Suggestions" })
        let lookups = f.lookups

        for address in ["chrome:", "chrome://password-manager/passwords?q=work",
                        " ABOUT:password-manager/passwords "] {
            f.manager.searchSuggestions(for: address)
            try #require(!f.manager.isLoading)
            #expect(!f.manager.suggestions.contains { $0.section == "Suggestions" })
        }
        #expect(f.lookups == lookups && SuggestionProtocol.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func editedProfileAndOrdinaryPaletteUseTheirOwnProviderWithoutCredentials() async throws {
        let f = try SuggestionFixture(); defer { f.close() }
        f.manager.setWebSuggestionTarget(for: f.workPage) { true }
        let work = await f.nextRequest { f.manager.searchSuggestions(for: "synthetic") }
        #expect(work.url?.host == "suggestqueries.google.com" && f.lookups == [f.workProfile])
        SuggestionProtocol.finish(); await f.settle()
        #expect(f.manager.suggestions.contains { $0.section == "Suggestions" })
        f.manager.clearWebSuggestionTarget()
        let personal = await f.nextRequest { f.manager.searchSuggestions(for: "another") }
        #expect(personal.url?.host == "kagisuggest.com" && f.lookups.last == f.personalProfile)
        #expect(URLComponents(url: personal.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) == ["q"])
        for request in SuggestionProtocol.requests {
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
        #expect(f.session.configuration.httpCookieStorage == nil && f.session.configuration.urlCredentialStorage == nil)
        #expect(f.session.configuration.urlCache == nil && !f.session.configuration.httpShouldSetCookies)
        SuggestionProtocol.finish(); await f.settle()
    }
    @Test(.timeLimit(.minutes(1))) func changedFrontSelectionDuringLookupDoesNotSendOrFallBack() async throws {
        let f = try SuggestionFixture(); defer { f.close() }
        let selected = f.window.selectedItemID
        f.manager.setWebSuggestionTarget(for: f.workPage) { f.window.selectedItemID == selected }
        var reply: (@MainActor (Result<ProfileSearchState, Error>) -> Void)?
        await withCheckedContinuation { ready in
            f.onLookup = { profile, done in #expect(profile == f.workProfile); reply = done; ready.resume() }
            f.manager.searchSuggestions(for: "synthetic")
        }
        f.window.selectedItemBySpace[f.window.spaceID!] = f.personalPage.itemID
        reply?(.success(f.state(f.workProfile))); await f.settle()
        #expect(f.lookups == [f.workProfile] && SuggestionProtocol.requests.isEmpty)
    }
    @Test(.timeLimit(.minutes(1))) func replacingCancelledLookupOnlySendsNewTargetRequest() async throws {
        let f = try SuggestionFixture(); defer { f.close() }
        f.manager.setWebSuggestionTarget(for: f.workPage) { true }
        var oldReply: (@MainActor (Result<ProfileSearchState, Error>) -> Void)?
        await withCheckedContinuation { ready in
            f.onLookup = { _, done in oldReply = done; ready.resume() }
            f.manager.searchSuggestions(for: "old")
        }
        f.onLookup = nil
        f.manager.setWebSuggestionTarget(for: f.personalPage) { true }
        let request = await f.nextRequest {
            oldReply?(.success(f.state(f.workProfile)))
            f.manager.searchSuggestions(for: "new")
        }
        #expect(request.url?.host == "kagisuggest.com")
        #expect(SuggestionProtocol.requests.count == 1)
        SuggestionProtocol.finish(); await f.settle()
    }
    @Test(.timeLimit(.minutes(1))) func changedPageProfileDropsActualPendingTransportReply() async throws {
        let f = try SuggestionFixture(); defer { f.close() }
        f.manager.setWebSuggestionTarget(for: f.workPage) { true }
        _ = await f.nextRequest { f.manager.searchSuggestions(for: "synthetic") }
        #expect(f.tabs.perform(.main, "reassignSuggestionTarget", undoable: false) {
            try $0.setProfile(f.workSpace, to: f.personalProfile)
        } != nil)
        SuggestionProtocol.finish(); await f.settle()
        #expect(f.lookups == [f.workProfile])
        #expect(!f.manager.suggestions.contains { $0.section == "Suggestions" })
    }
    @Test(.timeLimit(.minutes(1))) func privatePageInRegularWindowAndPrivateWindowNeverLookUpOrSend() async throws {
        let f = try SuggestionFixture(); defer { f.close() }
        let privatePage = PageSession(itemID: UUID(), url: URL(string: "https://private.invalid/")!,
            title: "Synthetic private", isPrivate: true, controller: nil)
        privatePage.detachedProfile = f.workPage.profile
        #expect(!f.window.isIncognito && privatePage.profile?.id == f.workProfile)
        f.manager.setWebSuggestionTarget(for: privatePage) { true }
        f.manager.searchSuggestions(for: "private"); await f.settle()
        #expect(f.lookups.isEmpty && SuggestionProtocol.requests.isEmpty)
        f.manager.clearWebSuggestionTarget(); f.window.isIncognito = true
        f.manager.searchSuggestions(for: "private window"); await f.settle()
        #expect(f.lookups.isEmpty && SuggestionProtocol.requests.isEmpty)
    }
    @Test(.timeLimit(.minutes(1))) func refusedEditedProfileDoesNotUseWindowProvider() async throws {
        let f = try SuggestionFixture(); defer { f.close() }
        f.onLookup = { _, done in done(.failure(ProfileSearchError.refused)) }
        f.manager.setWebSuggestionTarget(for: f.workPage) { true }
        f.manager.searchSuggestions(for: "synthetic"); await f.settle()
        #expect(f.lookups == [f.workProfile] && SuggestionProtocol.requests.isEmpty)
    }
}
