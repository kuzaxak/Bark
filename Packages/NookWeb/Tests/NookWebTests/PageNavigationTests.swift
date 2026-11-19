// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import WebKit
@testable import NookWeb

@MainActor
struct PageNavigationTests {
    @Test func explicitWebKitAccessOnlyReturnsExistingWebKitViews() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        #expect(WebKitPageAccess.existingView(for: session) == nil)
        #expect(WebKitPageAccess.processID(for: session) == nil)
        #expect(WebKitPageAccess.assignedView(for: session) == nil)
        #expect(session.isUnloaded)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = RecordingWebView(frame: .zero, configuration: configuration)
        session.primaryWebView = view
        #expect(WebKitPageAccess.existingView(for: session) === view)
        #expect(WebKitPageAccess.assignedView(for: session) == nil)
        session.primaryWindowId = UUID()
        #expect(WebKitPageAccess.assignedView(for: session) === view)

        // A stale view/window assignment during a profile transition grants no
        // access through this adapter to a Chromium-owned session.
        session.detachedProfile = Profile(id: UUID(), engine: .chromium)
        #expect(WebKitPageAccess.existingView(for: session) == nil)
        #expect(WebKitPageAccess.processID(for: session) == nil)
        #expect(WebKitPageAccess.assignedView(for: session) == nil)
        #expect(session.primaryWebView === view)
    }

    @Test func webKitViewLookupRejectsANativeOwnerEvenWithARetainedView() throws {
        let host = try Host(isPrivate: true)
        let space = try #require(host.window.spaceID)
        let item = try #require(host.tabs.open(url: URL(string: "about:blank")!, in: host.window,
            placement: .background, parent: .tabs(spaceID: space)))
        let session = try #require(host.tabs.ensureSession(for: item))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = RecordingWebView(frame: .zero, configuration: configuration)
        session.installPopupWebView(view)
        defer { session.detachedProfile = nil; session.unload() }

        #expect(WebKitPageAccess.session(for: view, in: host.tabs) === session)
        session.detachedProfile = Profile.createEphemeral(engine: .chromium)
        #expect(WebKitPageAccess.session(for: view, in: host.tabs) == nil)
        #expect(WebKitPageAccess.processID(for: session) == nil)
        #expect(session.primaryWebView === view)
    }

    @Test func muteUsesObservedStateAndRefusalNeverChangesTheModel() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "Audio", isPrivate: false, controller: nil)
        let page = RecordingNavigation(profileID: UUID())
        session.installNavigation(page)
        session.setMuted(true)
        #expect(page.muteRequests == [true] && !session.isAudioMuted)
        page.acceptsMute = true
        session.setMuted(true)
        #expect(page.muteRequests == [true, true] && !session.isAudioMuted)
        page.state.isAudioMuted = true; page.state.isAudible = true
        page.onStateChanged?(page.state)
        #expect(session.isAudioMuted && session.hasPlayingAudio && session.hasAudioContent)
        session.toggleMute()
        #expect(page.muteRequests.last == false && session.isAudioMuted)
        page.state.isAudioMuted = false; page.state.isAudible = false
        page.onStateChanged?(page.state)
        #expect(!session.isAudioMuted && !session.hasPlayingAudio && !session.hasAudioContent)
        #expect(session.primaryWebView == nil && !page.invalidated)
    }

    @Test func sessionCommandsUseInstalledEngineWithoutCreatingWebKit() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        // An independently installed navigation has no Chromium window or resource owner.
        let page = RecordingNavigation(profileID: UUID())
        session.installNavigation(page)
        #expect(!session.isUnloaded)
        #expect(session.primaryWebView == nil)
        session.loadWebViewIfNeeded()
        #expect(session.primaryWebView == nil)
        let url = URL(string: "about:blank#next")!
        session.load(url)
        #expect(page.loaded == [url])
        #expect(session.url == url)
        page.publish(back: true, forward: true)
        #expect(session.canGoBack && session.canGoForward)
        session.goBack()
        session.goForward()
        session.refresh()
        session.stop()
        #expect(page.back == 1 && page.forward == 1 && page.reloads == 1)
        #expect(page.stops == 1)
        #expect(session.loadingState == .idle)
        session.unload()
        #expect(session.isUnloaded)
        #expect(page.invalidated)
    }

    @Test func legacyBackTargetsTheSuppliedWebKitViewRatherThanPrimaryNavigation() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let selected = RecordingNavigation(profileID: UUID())
        session.installNavigation(selected)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let legacyView = NavigationView(frame: .zero, configuration: configuration)
        legacyView.setBack(true)

        WebKitPageCommands.goBack(on: session, in: legacyView)
        #expect(legacyView.back == 1 && selected.back == 0)

        session.goBack()
        #expect(legacyView.back == 1 && selected.back == 1)
    }

    @Test func loadedWebKitSessionReleasesWithItsController() throws {
        var host: Host? = try Host()
        let item = try #require(host?.window.selectedItemID)
        var session: PageSession? = try #require(host?.tabs.ensureSession(for: item))
        let profile = try #require(session?.profile)
        let view = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        session?.installNavigation(WebKitPageNavigation(webView: view, profileID: profile.id))
        weak var released = session
        session?.load(URL(string: "https://navigation-fixture.invalid/queued")!)
        host = nil
        #expect(session?.controller == nil)
        session = nil
        #expect(released == nil)
    }

    @Test func explicitLoadOfUnloadedSessionDispatchesOnce() throws {
        let host = try Host(isPrivate: true)
        let space = try #require(host.window.spaceID)
        let initial = URL(string: "about:blank")!
        let id = try #require(host.tabs.open(url: initial, in: host.window,
            placement: .background, parent: .tabs(spaceID: space)))
        let session = try #require(host.tabs.ensureSession(for: id))
        #expect(session.isUnloaded)
        let destination = URL(string: "about:blank#explicit")!
        session.load(destination)
        let view = try #require(WebKitPageAccess.existingView(for: session) as? RecordingWebView)
        #expect(view.requested == [destination])
        session.unload()
    }

    @Test func pendingSnapshotDoesNotHideDocumentChangeFromStart() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let page = RecordingNavigation(profileID: UUID())
        let old = URL(string: "https://old.invalid/")!
        page.state = PageNavigationState(url: old, title: "Old",
                                        canGoBack: false, canGoForward: false)
        session.installNavigation(page)
        session.hasAudioContent = true
        session.hasPlayingAudio = true
        let next = URL(string: "https://next.invalid/")!
        page.state = PageNavigationState(url: next, isLoading: true,
                                        canGoBack: false, canGoForward: false)
        page.onStateChanged?(page.state)
        #expect(session.url == next)
        page.onEvent?(.started(next))
        #expect(!session.hasAudioContent && !session.hasPlayingAudio)
        session.unload()
    }

    @Test func admittedCloseRetiresWithoutStopOrRecursiveClose() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let page = RecordingNavigation(profileID: UUID())
        session.installNavigation(page)
        var closed = 0
        session.onClose = { closed += 1 }
        let deliver = page.onEvent
        deliver?(.closed)
        #expect(session.isUnloaded && session.loadingState == .idle)
        #expect(page.invalidated && page.stops == 0 && closed == 1)
        deliver?(.closed)
        deliver?(.started(URL(string: "about:blank#retired")!))
        #expect(closed == 1 && session.loadingState == .idle)
    }

    @Test func replacedAndUnloadedOwnersCannotPublishLateState() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let first = RecordingNavigation(profileID: UUID())
        session.installNavigation(first)
        let late = first.onStateChanged
        let replacement = RecordingNavigation(profileID: UUID())
        session.installNavigation(replacement)
        #expect(first.invalidated)
        late?(PageNavigationState(canGoBack: true, canGoForward: true))
        #expect(!session.canGoBack && !session.canGoForward)
        replacement.publish(back: true, forward: false)
        #expect(session.canGoBack && !session.canGoForward)
        let afterUnload = replacement.onStateChanged
        session.unload()
        afterUnload?(PageNavigationState(canGoBack: false, canGoForward: true))
        #expect(session.canGoBack && !session.canGoForward)
    }

    @Test func bindingSeedIsNotAVisitAndSameDocumentCommitKeepsLoadingPhase() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Restored", isPrivate: true, controller: nil)
        let page = RecordingNavigation(profileID: UUID())
        let committed = URL(string: "https://seed.invalid/committed")!
        page.state = PageNavigationState(url: committed, title: "Already loaded",
                                        canGoBack: true, canGoForward: false)
        session.typedVisitPending = true
        session.installNavigation(page)
        #expect(session.url == committed && session.title == "Already loaded")
        #expect(session.loadingState == .didFinish && session.hasCommittedPage)
        #expect(session.typedVisitPending, "Binding must not append a history visit")
        let fragment = URL(string: committed.absoluteString + "#section")!
        page.onEvent?(.committed(fragment, sameDocument: true))
        #expect(session.url == fragment && session.loadingState == .didFinish)
        page.onEvent?(.started(URL(string: "https://seed.invalid/fails")!))
        page.onEvent?(.failed(URLError(.cannotConnectToHost), provisional: true,
                             committedURL: fragment))
        #expect(session.url == fragment)
        #expect(!session.isLoading)
        page.onEvent?(.finished(fragment, title: "Final", isReload: false))
        #expect(!session.typedVisitPending)
        #expect(session.title == "Final")
        session.typedVisitPending = true
        page.onEvent?(.finished(fragment, title: "Final", isReload: false))
        #expect(session.typedVisitPending, "Duplicate finish cannot append another visit")
        page.onEvent?(.started(committed))
        page.onEvent?(.cancelled(committedURL: fragment))
        #expect(session.url == fragment && session.loadingState == .idle)
        page.onEvent?(.finished(committed, title: "Cancelled title", isReload: false))
        #expect(session.title == "Final" && session.loadingState == .idle)
        let late = page.onEvent
        session.unload()
        late?(.started(committed))
        late?(.titleChanged("Retired title"))
        #expect(session.loadingState == .idle && session.title == "Final")
    }

    @Test func realWebKitPageKeepsHistoryAcrossCommands() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookNavigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.html")
        let second = directory.appendingPathComponent("second.html")
        try "<title>First</title><p>one</p>".write(to: first, atomically: true, encoding: .utf8)
        try "<title>Second</title><p>two</p>".write(to: second, atomically: true, encoding: .utf8)
        let session = PageSession(itemID: UUID(), url: first, title: "Test",
                                  isPrivate: true, controller: nil)
        let profile = Profile.createEphemeral(engine: .webKit)
        session.detachedProfile = profile
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = try #require(profile.webKitStorage?.dataStore)
        let view = WKWebView(frame: .zero, configuration: configuration)
        session.installPopupWebView(view)
        defer { session.unload() }
        let page = try #require(session.navigation as? WebKitPageNavigation)
        func finished(_ action: () -> Void) async {
            let receive = page.onEvent
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var waiting = true
                page.onEvent = { event in
                    receive?(event)
                    if case .finished(_, let title, _) = event, title != nil, waiting {
                        waiting = false
                        page.onEvent = receive
                        continuation.resume()
                    }
                }
                action()
            }
        }
        await finished { session.load(first) }
        #expect(session.title == "First" && !session.isLoading)
        await finished { session.load(second) }
        #expect(session.title == "Second" && session.canGoBack)
        await finished { session.goBack() }
        #expect(session.url == first && session.canGoForward)
        #expect(page.profileID == profile.id)
        await finished { session.goForward() }
        #expect(session.url == second && session.title == "Second")
    }

    @Test func webKitNavigationDelegateIgnoresAnUnloadedView() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let first = NavigationView(frame: .zero, configuration: configuration)
        session.installPopupWebView(first)
        let adapter = session.webKitDelegate
        #expect(first.navigationDelegate === adapter)
        #expect(adapter.responds(to: NSSelectorFromString(
            "_webView:contentRuleListWithIdentifier:performedAction:forURL:")))
        #expect(adapter.responds(to: NSSelectorFromString("_webViewDidBeginNavigationGesture:")))
        #expect(adapter.responds(to: NSSelectorFromString(
            "_webViewDidEndNavigationGesture:withNavigationToBackForwardListItem:")))
        adapter.webViewDidBeginNavigationGesture(first)
        #expect(session.navigationGestureCount == 1)
        session.unload()
        let second = NavigationView(frame: .zero, configuration: configuration)
        session.installPopupWebView(second)
        defer { session.unload() }

        // Simulate an already dispatched callback after the old view retired.
        adapter.webViewDidBeginNavigationGesture(first)
        #expect(session.navigationGestureCount == 1)
        adapter.webView(first, didStartProvisionalNavigation: nil)
        #expect(!session.isLoading)
        adapter.webView(second, didStartProvisionalNavigation: nil)
        #expect(session.isLoading)
    }

    @Test func supersededWebKitFailureCannotRegressNewNavigation() throws {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let view = NavigationView(frame: .zero, configuration: WKWebViewConfiguration())
        session.installPopupWebView(view)
        defer { session.unload() }
        let page = try #require(session.navigation as? WebKitPageNavigation)
        // WKNavigation() has no engine backing and crashes in dealloc. Obtain
        // real navigation identities from WebKit, even for this admission test.
        let old = try #require(view.loadHTMLString("<title>old</title>", baseURL: nil))
        let current = try #require(view.loadHTMLString("<title>new</title>", baseURL: nil))
        page.report(.started(URL(string: "https://navigation.invalid/old")!), navigation: old)
        let destination = URL(string: "https://navigation.invalid/new")!
        page.report(.started(destination), navigation: current)
        session.webKitDelegate.webView(view, didFailProvisionalNavigation: old,
                        withError: URLError(.cancelled))
        #expect(session.url == destination && session.isLoading)
        session.stop()
        session.webKitDelegate.webView(view, didFailProvisionalNavigation: current,
                        withError: URLError(.cancelled))
        #expect(session.loadingState == .idle && session.url == destination)
    }

    @Test func webKitAdapterRoutesRequestsAndStopsAfterInvalidation() {
        let view = NavigationView(frame: .zero, configuration: WKWebViewConfiguration())
        let profile = UUID()
        let page = WebKitPageNavigation(webView: view, profileID: profile)
        var observed: [PageNavigationState] = []
        page.onStateChanged = { observed.append($0) }
        view.setBack(true)
        #expect(observed.last?.canGoBack == true)
        #expect(page.goBack())
        #expect(view.back == 1)
        let remote = URL(string: "https://navigation.invalid/")!
        page.load(remote)
        #expect(view.request?.url == remote)
        #expect(view.request?.timeoutInterval == 30)
        let file = URL(fileURLWithPath: "/tmp/nook-navigation-fixture/page.html")
        page.load(file)
        #expect(view.fileURL == file)
        #expect(view.readScope == file.deletingLastPathComponent())
        page.stop()
        #expect(view.stops == 1)
        let count = observed.count
        page.invalidate()
        view.setBack(false)
        #expect(observed.count == count)
        page.load(remote)
        #expect(view.requestCount == 1)
        #expect(!page.goBack())
        #expect(page.profileID == profile)
    }
}

@MainActor
private final class RecordingNavigation: PageNavigation {
    let profileID: UUID?
    var state = PageNavigationState(canGoBack: false, canGoForward: false)
    var onStateChanged: ((PageNavigationState) -> Void)?
    var onEvent: ((PageNavigationEvent) -> Void)?
    var loaded: [URL] = []
    var back = 0
    var forward = 0
    var reloads = 0
    var stops = 0
    var invalidated = false
    var acceptsMute = false
    var muteRequests: [Bool] = []
    func setAudioMuted(_ muted: Bool) -> Bool { muteRequests.append(muted); return acceptsMute }
    init(profileID: UUID) { self.profileID = profileID }
    func publish(back: Bool, forward: Bool) {
        state = PageNavigationState(canGoBack: back, canGoForward: forward)
        onStateChanged?(state)
    }
    func load(_ url: URL) { loaded.append(url) }
    func goBack() -> Bool { back += 1; return true }
    func goForward() -> Bool { forward += 1; return true }
    func reload() -> Bool { reloads += 1; return true }
    func stop() { stops += 1 }
    func invalidate() { invalidated = true; onStateChanged = nil; onEvent = nil }
}

@MainActor
private final class NavigationView: WKWebView {
    var request: URLRequest?
    var requestCount = 0
    var fileURL: URL?
    var readScope: URL?
    var back = 0
    var stops = 0
    private var backAvailable = false
    override var canGoBack: Bool { backAvailable }
    func setBack(_ available: Bool) {
        willChangeValue(forKey: "canGoBack")
        backAvailable = available
        didChangeValue(forKey: "canGoBack")
    }
    override func load(_ request: URLRequest) -> WKNavigation? {
        self.request = request
        requestCount += 1
        return nil
    }
    override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        fileURL = URL
        readScope = readAccessURL
        return nil
    }
    override func goBack() -> WKNavigation? { back += 1; return nil }
    override func stopLoading() { stops += 1 }
}
