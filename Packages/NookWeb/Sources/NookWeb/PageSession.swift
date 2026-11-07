// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession.swift
//  Nook
//
//  One live page for one item. Holds the web view, committed URL, title, favicon, loading,
//  navigation and media state. The item itself (parent, order, home URL) lives in TabTree;
//  the session reports committed URLs and titles to its TabsController.
//

import Combine
import FaviconFinder
import NookBlocker
import NookTabsCore
import NookSettings
import OSLog
import SwiftUI
import Translation
import WebKit

@MainActor
@Observable
public final class PageSession: NSObject, Identifiable {
    // MARK: - Identity

    public let itemID: UUID
    public var id: UUID { itemID }
    @ObservationIgnored static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "PageSession")
    /// A session in a private window: ephemeral profile, never saved, no extensions.
    public let isPrivate: Bool

    @ObservationIgnored public weak var controller: TabsController?

    /// The profile whose data store this page uses.
    public var profile: Profile? {
        detachedProfile ?? controller?.profile(for: self)
    }

    // MARK: - Detached Pages

    /// Set while the page is shown outside the tab tree, in Peek or a mini window: the data store
    /// it uses and the window it belongs to. Cleared when the page becomes a tab.
    @ObservationIgnored public internal(set) var detachedProfile: Profile?
    @ObservationIgnored public internal(set) weak var detachedWindow: BrowserWindowState?
    /// Runs when the page calls `window.close()`, so Peek or the mini window can close.
    @ObservationIgnored public var onClose: (() -> Void)?
    public var isDetached: Bool { detachedProfile != nil }

    // MARK: - Page State

    /// Last committed URL (or the URL being loaded when nothing has committed yet).
    public var url: URL
    public var title: String
    public var favicon: SwiftUI.Image
    /// A page the ad blocker stopped from loading. The blocked-page card shows while it is set.
    public internal(set) var blockedURL: URL?
    /// A page whose server's certificate failed the check. The certificate warning card shows while it is set.
    public internal(set) var certificateWarning: CertificateWarning?
    /// The site enhanced fingerprinting protection is off for until the tab leaves it.
    var enhancedFingerprintingProtectionOffHost: String?

    public enum LoadingState: Equatable {
        case idle
        case didStartProvisionalNavigation
        case didCommit
        case didFinish
        case didFail(Error)
        case didFailProvisionalNavigation(Error)

        public static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                (.didStartProvisionalNavigation, .didStartProvisionalNavigation),
                (.didCommit, .didCommit),
                (.didFinish, .didFinish):
                return true
            case (.didFail, .didFail),
                (.didFailProvisionalNavigation, .didFailProvisionalNavigation):
                return lhs.description == rhs.description
            default:
                return false
            }
        }

        public var isLoading: Bool {
            switch self {
            case .idle, .didFinish, .didFail, .didFailProvisionalNavigation:
                return false
            case .didStartProvisionalNavigation, .didCommit:
                return true
            }
        }

        var description: String {
            switch self {
            case .idle:
                return "Idle"
            case .didStartProvisionalNavigation:
                return "Loading started"
            case .didCommit:
                return "Content loading"
            case .didFinish:
                return "Loading finished"
            case .didFail(let error):
                return "Loading failed: \(error.localizedDescription)"
            case .didFailProvisionalNavigation(let error):
                return "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    public var loadingState: LoadingState = .idle
    public var isLoading: Bool { loadingState.isLoading }
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false
    /// WebKit's own PDF viewer is showing the page, so Nook draws its controls over it.
    public var isDisplayingPDF: Bool = false
    /// A small picture of the page taken as the window left it, for the Control-Tab switcher.
    public var switcherSnapshot: PlatformImage?
    /// The link under the pointer while Shift is held, for Link Previews; nil otherwise.
    public var linkPreview: LinkPreviewTarget?
    /// Bumped whenever the PDF controls should show: a PDF loads, or the pointer moves over one.
    public private(set) var pdfControlsReveal = 0
    @ObservationIgnored private var lastPDFControlsReveal: ContinuousClock.Instant?

    /// Called on every mouse move over the page. Cheap on an ordinary page, and on a PDF it
    /// publishes at most four times a second, since each publish redraws the controls.
    public func pointerMovedOverPage() {
        guard isDisplayingPDF else { return }
        let now = ContinuousClock.now
        if let last = lastPDFControlsReveal, now - last < .milliseconds(250) { return }
        lastPDFControlsReveal = now
        pdfControlsReveal &+= 1
    }

    /// After a load: a reload keeps the controls' view, so without this they stayed hidden.
    func pdfLoadStateChanged(_ webView: WKWebView) {
        isDisplayingPDF = webView.nookIsDisplayingPDF
        if isDisplayingPDF { pdfControlsReveal &+= 1 }
    }

    // MARK: - Translation

    /// The page's text is shown translated, or a translation is under way.
    public internal(set) var isTranslated = false
    /// The detected language while the window offers to translate the page.
    public internal(set) var translationOffer: Locale.Language?
    /// Requests a view-hosted session for language downloads, or any translation on Sequoia.
    public internal(set) var translationRequest: TranslationSession.Configuration?
    /// Says why some of the text did not go through the AI engine, while the page is translated.
    public internal(set) var translationNotice: PageTranslationNotice?
    @ObservationIgnored var translationSource: Locale.Language?
    @ObservationIgnored var translationGeneration = 0
    @ObservationIgnored var translationFeed: AsyncStream<[[String: Any]]>.Continuation?
    /// Text the page added while no run was reading the feed, for the next run.
    @ObservationIgnored var translationBacklog: [[String: Any]] = []
    @ObservationIgnored var installedTranslation: Task<Void, Never>?
    @ObservationIgnored var aiTranslator: AIPageTranslator?
    /// The AI engine's requests in flight; resetting the translation cancels them.
    @ObservationIgnored var aiTranslationWork: Task<Void, Never>?

    // MARK: - Web Process Crash Tracking

    public var webProcessCrashCount: Int = 0
    public var lastWebProcessCrashDate: Date = .distantPast

    /// The last page whose text went to history search, so a re-commit does not read it again.
    @ObservationIgnored var lastTextCapture: (url: URL, at: Date)?

    // MARK: - Media State

    public var hasPlayingVideo: Bool = false
    public var hasVideoContent: Bool = false
    public var hasPiPActive: Bool = false
    public var hasPlayingAudio: Bool = false
    public internal(set) var media = PageMedia()
    @ObservationIgnored var mediaFrames = MediaFrames<WKFrameInfo?>()
    /// Subframes navigations named, by frame handle, asked again with those that reported.
    @ObservationIgnored var seenMediaFrames: [AnyHashable: WKFrameInfo] = [:]
    @ObservationIgnored var mediaReask = ReaskGate()
    /// WebKit's own word on whether the page plays sound; nil until the web view reports it.
    @ObservationIgnored var webKitAudible: Bool?
    /// WebKit's private, KVO-compliant `_isPlayingAudio`: what Safari's tab speaker follows. It
    /// covers every frame, Web Audio and elements outside the document, stays on while the tab is
    /// muted (`_setPageMuted:`), and goes off when the page mutes or pauses its media.
    static let isPlayingAudioKey = "_isPlayingAudio"
    static let isPlayingAudioSelector = NSSelectorFromString(isPlayingAudioKey)
    public var isAudioMuted: Bool = false
    public var hasAudioContent: Bool = false {
        didSet {
            if oldValue != hasAudioContent {
                if hasAudioContent {
                    startNativeAudioMonitoring()
                } else {
                    stopNativeAudioMonitoring()
                }
            }
        }
    }

    // MARK: - Chrome

    public var pageBackgroundColor: PlatformColor? = nil
    public var topBarBackgroundColor: PlatformColor? = nil
    /// Option key state for Peek on link click.
    @ObservationIgnored public var isOptionKeyDown: Bool = false
    @ObservationIgnored public var onLinkHover: ((String?) -> Void)? = nil
    @ObservationIgnored public var onCommandHover: ((String?) -> Void)? = nil
    @ObservationIgnored public var pendingContextMenuPayload: WebContextMenuPayload?

    // MARK: - OAuth Flow State

    /// Whether this page hosts an OAuth/sign-in flow popup.
    public var isOAuthFlow: Bool = false
    /// The item whose page started this OAuth flow.
    @ObservationIgnored var oauthParentItemID: UUID?
    /// The OAuth provider host (e.g., "accounts.google.com") for tracking protection exemption.
    @ObservationIgnored var oauthProviderHost: String?

    // MARK: - Internal State

    /// Back and forward history kept across an unload, so the next view comes back with it.
    @ObservationIgnored var savedHistory: Any?
    /// Counts back and forward swipes, so a late snapshot cleanup never touches a newer swipe.
    @ObservationIgnored var navigationGestureCount = 0
    /// One-shot initial-navigation suppression for a WebKit-created popup.
    @ObservationIgnored var isPopupHost: Bool = false
    /// The page's address as it may be stored, copied or shown: without a Kagi session token.
    public var storableURL: URL { KagiSession.withoutToken(url) }

    /// The palette chose this page's next load, so its visit counts double in history ranking.
    @ObservationIgnored public var typedVisitPending = false
    /// How the latest main-frame navigation started; a reload adds nothing to history ranking.
    @ObservationIgnored var mainFrameNavigationType: WKNavigationType = .other
    /// JavaScript dialogs since the last commit, and whether the user silenced the page.
    @ObservationIgnored var jsDialogCount = 0
    @ObservationIgnored var jsDialogsSuppressed = false
    @ObservationIgnored var hasFavicon: Bool = false
    @ObservationIgnored var faviconFetchInFlight: Bool = false
    @ObservationIgnored var faviconFetchAttempts: Int = 0
    static let maxFaviconRetries = 3

    @ObservationIgnored var lastSampledDomain: String? = nil
    @ObservationIgnored var lastTopBarDomain: String? = nil
    @ObservationIgnored var pendingThemeColorUpdate: DispatchWorkItem? = nil

    @ObservationIgnored var audioDeviceListenerProc: AudioDeviceListenerProc?
    @ObservationIgnored var audioListenerHelper: AudioListenerHelper?
    @ObservationIgnored var isMonitoringNativeAudio = false
    @ObservationIgnored var hasAddedCoreAudioListener = false
    /// AudioDeviceID the "is running somewhere" listener is currently attached to.
    /// UInt32 rather than AudioDeviceID so this file stays free of a macOS-only type.
    @ObservationIgnored var audioRunningListenerDevice: UInt32?
    @ObservationIgnored var profileAwaitCancellable: AnyCancellable?
    @ObservationIgnored var webStoreHandler: AnyObject?
    @ObservationIgnored var didNotifyOpenToExtensions: Bool = false

    @ObservationIgnored let themeColorObservedWebViews = NSHashTable<AnyObject>.weakObjects()
    @ObservationIgnored let navigationStateObservedWebViews = NSHashTable<AnyObject>.weakObjects()

    // MARK: - Web View Ownership

    private var navigationDocumentURL: URL?
    private var navigationHasCommittedPage = false
    private var navigationVisitRecorded = false
    private var navigationFinishedReported = false
    private var navigationCancelled = false
    @ObservationIgnored var nativeCreation: NativePageCreation?
    @ObservationIgnored var nativeRelease: NativePageRelease?
    @ObservationIgnored weak var nativeResourceHost: (any NativePageHost)?
    @ObservationIgnored var nativeRequestedURL: URL?
    @ObservationIgnored weak var nativePreparationWindow: BrowserWindowState?
    @ObservationIgnored var nativePreparationCompletions: [@MainActor (Bool) -> Void] = []
    @ObservationIgnored var nativeIsEnding = false
    @ObservationIgnored var nativeUnloadPending = false
    var navigation: (any PageNavigation)?
    var primaryWebView: WKWebView? {
        didSet {
            guard primaryWebView !== oldValue else { return }
            navigation?.invalidate()
            navigation = nil
            guard let primaryWebView else { return }
            let adapter = WebKitPageNavigation(webView: primaryWebView, profileID: profile?.id)
            navigation = adapter
            adapter.onEvent = { [weak self, weak adapter] event in
                guard let self, let adapter, self.navigation === adapter else { return }
                self.navigationChanged(event)
            }
            adapter.onStateChanged = { [weak self, weak adapter] state in
                guard let self, let adapter, self.navigation === adapter else { return }
                self.applyNavigationState(state)
            }
            updateNavigationState()
        }
    }

    /// Attach an engine-owned page without creating a WebKit surface. An existing
    /// WebKit page must first be unloaded; never keep two live engines for one item.
    public func installNavigation(_ page: any PageNavigation) {
        precondition(primaryWebView == nil, "Unload the WebKit page before replacing its engine")
        precondition(profile?.id == nil || profile?.id == page.profileID,
                     "Navigation must belong to this page's profile")
        navigation?.stop()
        navigation?.invalidate()
        navigation = page
        page.onEvent = { [weak self, weak page] event in
            guard let self, let page, self.navigation === page else { return }
            self.navigationChanged(event)
        }
        page.onStateChanged = { [weak self, weak page] state in
            guard let self, let page, self.navigation === page else { return }
            self.applyNavigationState(state)
        }
        applyNavigationState(page.state)
        if let url = page.state.url { self.url = url }
        navigationDocumentURL = page.state.isLoading ? nil : page.state.url
        navigationHasCommittedPage = page.state.url != nil && !page.state.isLoading
        navigationVisitRecorded = navigationHasCommittedPage
        navigationFinishedReported = navigationHasCommittedPage
        navigationCancelled = false
        loadingState = page.state.isLoading ? .didStartProvisionalNavigation :
            (page.state.url == nil ? .idle : .didFinish)
    }

    private func applyNavigationState(_ state: PageNavigationState) {
        canGoBack = state.canGoBack
        canGoForward = state.canGoForward
        if let title = state.title, !title.isEmpty { updateTitle(title) }
        // A displayed pending URL is not a committed URL to persist. Only
        // lifecycle events notify the tree or append a history visit.
        if let url = state.url { self.url = url }
        if state.isLoading {
            if !loadingState.isLoading { loadingState = .didStartProvisionalNavigation }
        } else if loadingState.isLoading {
            loadingState = .didFinish
        }
        // A nonloading snapshot must not erase an explicit failure/cancellation.
    }

    func navigationChanged(_ event: PageNavigationEvent) {
        switch event {
        case .started(let newURL):
            navigationVisitRecorded = false
            navigationFinishedReported = false
            navigationCancelled = false
            loadingState = .didStartProvisionalNavigation
            blockedURL = nil
            certificateWarning = nil
            controller?.tabEvents?.tabPropertiesChanged(self, properties: [.loading])
            if let newURL {
                if newURL != navigationDocumentURL {
                    hasAudioContent = false
                    hasPlayingAudio = false
                    if let domain = extractDomain(from: newURL), domain != lastSampledDomain {
                        lastSampledDomain = nil
                        lastTopBarDomain = nil
                    }
                }
                url = newURL
            }
        case .committed(let newURL, let sameDocument):
            if let newURL { navigationDocumentURL = newURL }
            if newURL != nil { navigationHasCommittedPage = true }
            if !sameDocument {
                navigationVisitRecorded = false
                navigationFinishedReported = false
                navigationCancelled = false
                loadingState = .didCommit
                linkPreview = nil
                certificateWarning = nil
                controller?.tabEvents?.tabPropertiesChanged(self, properties: [.loading])
            }
            if let newURL {
                url = newURL
                controller?.pageCommitted(itemID: itemID, url: newURL)
                controller?.sessionDelegate?.navigateAcrossWindows(itemID, to: newURL)
                if !isDetached { controller?.sessionDelegate?.shortcutDetectorDidNavigate(to: newURL) }
                controller?.tabEvents?.grantAccess(to: newURL)
                controller?.tabEvents?.tabPropertiesChanged(self, properties: [.URL])
            }
        case .finished(let newURL, let finalTitle, let isReload):
            guard !navigationCancelled else { return }
            if let newURL { navigationDocumentURL = newURL }
            if newURL != nil { navigationHasCommittedPage = true }
            loadingState = .didFinish
            if !navigationFinishedReported {
                navigationFinishedReported = true
                controller?.tabEvents?.tabPropertiesChanged(self, properties: [.loading])
                if let newURL {
                    url = newURL
                    controller?.tabEvents?.grantAccess(to: newURL)
                    controller?.tabEvents?.tabPropertiesChanged(self, properties: [.URL])
                    controller?.tabEvents?.wakeBackgroundWorkers()
                    controller?.pageCommitted(itemID: itemID, url: newURL)
                    controller?.sessionDelegate?.navigateAcrossWindows(itemID, to: newURL)
                }
            }
            if let finalTitle, let newURL {
                updateTitle(finalTitle)
                guard !navigationVisitRecorded else { return }
                navigationVisitRecorded = true
                let boundProfile = profile
                let profileID = navigation?.profileID ?? boundProfile?.id ?? controller?.sessionDelegate?.currentProfile?.id
                let ephemeral = isPrivate || isAgentPage || boundProfile?.isEphemeral == true
                let weight: Double = typedVisitPending ? 2 : isReload ? 0 : 1
                typedVisitPending = false
                controller?.history?.addVisit(url: newURL, title: finalTitle, timestamp: Date(),
                    tabId: id, profileId: profileID, isEphemeral: ephemeral, weight: weight)
            }
        case .failed(let error, let provisional, let committedURL):
            if let committedURL { navigationDocumentURL = committedURL }
            if let committedURL, committedURL != url {
                url = committedURL
                controller?.tabEvents?.tabPropertiesChanged(self, properties: [.URL])
                controller?.pageCommitted(itemID: itemID, url: committedURL)
            }
            loadingState = provisional ? .didFailProvisionalNavigation(error) : .didFail(error)
        case .cancelled(let committedURL):
            if let committedURL { navigationDocumentURL = committedURL }
            navigationCancelled = true
            navigationVisitRecorded = true
            typedVisitPending = false
            loadingState = .idle
            if let committedURL, committedURL != url {
                url = committedURL
                controller?.tabEvents?.tabPropertiesChanged(self, properties: [.URL])
                controller?.pageCommitted(itemID: itemID, url: committedURL)
            }
            controller?.tabEvents?.tabPropertiesChanged(self, properties: [.loading])
        case .titleChanged(let title):
            if !title.isEmpty { updateTitle(title) }
        case .ownerEnded:
            nativeOwnerEnded()
        case .closed:
            if nativeRelease != nil {
                completeNativeRelease(.closed)
                return
            }
            nativeIsEnding = true
            nativeResourceHost = nil
            // Engine deletion already happened. Detach before callbacks and
            // never call stop/close back into the deleted native page.
            let ended = navigation
            navigation = nil
            ended?.invalidate()
            navigationHasCommittedPage = false
            loadingState = .idle
            onClose?()
            if !isDetached { controller?.close(itemID) }
        }
    }

    @discardableResult
    func navigationChanged(_ event: PageNavigationEvent, from view: WKWebView,
                           navigation token: WKNavigation? = nil) -> Bool {
        guard acceptsNavigationCallbacks(from: view) else { return false }
        if view === primaryWebView, let adapter = navigation as? WebKitPageNavigation {
            return adapter.report(event, navigation: token)
        }
        // Legacy secondary windows remain WebKit-specific until hosting is ported.
        navigationChanged(event)
        return true
    }

    func acceptsNavigationCallbacks(from view: WKWebView) -> Bool {
        guard navigation != nil else { return false }
        return view === primaryWebView ||
            controller?.webViews?.allWebViews(for: itemID).contains(where: { $0 === view }) == true
    }

    /// The window that owns the primary web view; nil until a window displays the page.
    @ObservationIgnored var primaryWindowId: UUID?

    public var isUnloaded: Bool { navigation == nil }

    /// Console and network log while Developer Mode is on; nil otherwise.
    public internal(set) var devCapture: DevCapture?

    /// The existing web view. Never creates one.
    public var webView: WKWebView? { primaryWebView }

    /// Ends the suspended pages WebKit keeps for instant Back and Forward, each a whole
    /// WebContent process. History stays; Back loads the page again.
    public func clearPageCache() { primaryWebView?.nookClearBackForwardCache() }

    /// The web view, created on first access.
    public var activeWebView: WKWebView {
        if primaryWebView == nil {
            setupWebView()
        }
        return primaryWebView!
    }

    /// The web view only once a window displays it, so callers never create orphan views.
    public var assignedWebView: WKWebView? {
        primaryWindowId != nil ? primaryWebView : nil
    }

    // MARK: - Init

    public init(
        itemID: UUID,
        url: URL,
        title: String,
        isPrivate: Bool,
        controller: TabsController?
    ) {
        self.itemID = itemID
        self.url = url
        self.title = title
        self.isPrivate = isPrivate
        self.controller = controller
        self.favicon = SwiftUI.Image(systemName: "globe")
        super.init()
        restoreFaviconFromCache()
    }

    deinit {
        profileAwaitCancellable?.cancel()
        themeColorObservedWebViews.removeAllObjects()
    }

    // MARK: - Web View Lifecycle

    public func loadWebViewIfNeeded() {
        if usesNativePageHost {
            guard let controller, let window = controller.nativePageWindow(for: self) else { return }
            if (navigation == nil || nativeIsEnding), window.selectedItemID == itemID,
               window.nativeSelectionGeneration == nil {
                controller.select(itemID, in: window)
            } else {
                ensureNativePage(in: window)
            }
            return
        }
        if navigation == nil {
            setupWebView()
        }
        ensureFaviconLoaded()
    }

    /// Makes `webView` the primary view, owned by the window that displays it first.
    public func assignWebView(_ webView: WKWebView, toWindow windowId: UUID) {
        primaryWebView = webView
        primaryWindowId = windowId
    }

    private func setupWebView(initialLoad: Bool = true) {
        guard navigation == nil else { return }
        let interval = BrowserPerformance.signposter.beginInterval("WebViewCreation")
        defer { BrowserPerformance.signposter.endInterval("WebViewCreation", interval) }
        let resolvedProfile = profile
        guard (resolvedProfile?.engine ?? controller?.profileEngine ?? .webKit) == .webKit else {
            // The native host installs its page explicitly. Never satisfy a
            // legacy lazy-load request with a fallback WK page/store.
            return
        }
        let configuration: WKWebViewConfiguration
        if let resolvedProfile {
            configuration = BrowserConfiguration.shared.webViewConfiguration(for: resolvedProfile)
        } else {
            // Edge case: no profile yet. Delay creating WKWebView until one resolves.
            if profileAwaitCancellable == nil {
                profileAwaitCancellable = controller?.sessionDelegate?
                    .currentProfilePublisher
                    .receive(on: RunLoop.main)
                    .sink { [weak self] value in
                        guard let self else { return }
                        if value != nil && self.primaryWebView == nil {
                            self.profileAwaitCancellable?.cancel()
                            self.profileAwaitCancellable = nil
                            self.setupWebView()
                            if self.primaryWebView != nil {
                                for (_, windowState) in self.controller?.windowRegistry.windows ?? [:] {
                                    windowState.refreshCompositor()
                                }
                            }
                        }
                    }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.profileAwaitCancellable?.cancel()
                    self?.profileAwaitCancellable = nil
                }
            }
            return
        }

        // Private and Agent pages never get the extension controller: extensions could open
        // windows and activate the app from an Agent page.
        if isPrivate || isAgentPage {
            configuration.webExtensionController = nil
        } else if configuration.webExtensionController == nil,
                  let extensionController = controller?.tabEvents?.nativeController {
            configuration.webExtensionController = extensionController
        }

        // An agent page cannot take the person's screen for element full screen. Its own copy of
        // the preferences, so other pages keep full screen.
        if isAgentPage, let preferences = configuration.preferences.copy() as? WKPreferences {
            preferences.isElementFullscreenEnabled = false
            configuration.preferences = preferences
        }
        let created = controller?.webViews?.makeWebView(configuration: configuration)
        (created as? SessionWebView)?.contextMenuBridge = WebContextMenuBridge(session: self, configuration: configuration)
        primaryWebView = created

        guard let webView = primaryWebView else {
            Self.log.error("No web view created for item \(self.itemID.uuidString, privacy: .public)")
            return
        }
        (webView as? SessionWebView)?.owningSession = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        setupThemeColorObserver(for: webView)
        setupNavigationStateObservers(for: webView)
        configure(webView)

        // Inform extensions before loading so content scripts and messaging can resolve this
        // page during early document phases.
        if !didNotifyOpenToExtensions {
            controller?.tabEvents?.tabOpened(self)
            if controller?.activeWindowSession === self {
                controller?.tabEvents?.tabActivated(new: self, previous: nil)
            }
            didNotifyOpenToExtensions = true
        }
        // Consume popup suppression only after setup succeeds. WebKit drives the original
        // navigation; any replacement view must load the saved URL.
        let shouldLoadInitialURL = initialLoad && !isPopupHost
        isPopupHost = false
        let history = savedHistory
        savedHistory = nil
        if shouldLoadInitialURL, let history {
            webView.interactionState = history
            // Restoring shows the cached copy, as Back does; reload revalidates it like a fresh load.
            if webView.reload() == nil { load(url) }
        } else if shouldLoadInitialURL {
            load(url)
        }
    }

    /// Handlers, user agent and preferences shared by primary, clone and popup views.
    /// The view's controller must belong to this view alone: handlers are keyed by name.
    public func configure(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        for name in messageHandlerNames {
            controller.removeScriptMessageHandler(forName: name)
            controller.add(self, name: name)
        }
        controller.removeScriptMessageHandler(forName: "pipStateChange", contentWorld: Self.pipStateWorld)
        controller.add(self, contentWorld: Self.pipStateWorld, name: "pipStateChange")
        controller.removeScriptMessageHandler(forName: Self.translateHandlerName, contentWorld: Self.translateWorld)
        controller.add(self, contentWorld: Self.translateWorld, name: Self.translateHandlerName)
        controller.addUserScript(WKUserScript(source: MediaScript.reporter(handler: "mediaStateChange_\(itemID.uuidString)"),
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        #if os(macOS)
        self.controller?.vault?.attach(to: webView, session: self)
        #endif
        webView.customUserAgent = PlatformUserAgent.custom
        // Let the web content control its own background so extension styles (like Dark
        // Reader) can paint dark backgrounds. The themed background shows only while loading.
        webView.setDrawsPageBackground(true)
        if developerModeOn { attachDevCaptureHandler(to: webView) }
        webView.isInspectable = true
        webView.allowsLinkPreview = true
        webView.configuration.preferences.isFraudulentWebsiteWarningEnabled = true
    }

    /// Installs a WebKit-created popup view as this session's primary view. WebKit drives the
    /// popup's first navigation.
    func installPopupWebView(_ webView: WKWebView) {
        (webView as? SessionWebView)?.owningSession = self
        (webView as? SessionWebView)?.contextMenuBridge = WebContextMenuBridge(session: self, configuration: webView.configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        primaryWebView = webView
        configure(webView)
        setupThemeColorObserver(for: webView)
        setupNavigationStateObservers(for: webView)
        if !didNotifyOpenToExtensions, !isPrivate {
            controller?.tabEvents?.tabOpened(self)
            didNotifyOpenToExtensions = true
        }
    }

    /// Updates the extension controller on the existing web view.
    public func applyConfigurationOverride(_ configuration: WKWebViewConfiguration) {
        guard let existing = primaryWebView else { return }
        if let extensionController = configuration.webExtensionController {
            existing.configuration.webExtensionController = extensionController
        }
    }

    /// Releases every web view for this page (primary and window clones) and resets
    /// live state. The item and its URL stay; selecting it again loads a fresh view.
    public func unload() {
        if requiresNativeResourceRelease {
            guard !nativeUnloadPending else { return }
            nativeUnloadPending = true
            requestNativeRelease { [weak self] outcome in
                guard let self else { return }
                self.nativeUnloadPending = false
                if outcome == .closed { self.finishUnloading() }
            }
            return
        }
        cancelNativeCreation()
        finishUnloading()
    }

    private func finishUnloading() {
        controller?.onPageUnloaded?(itemID)
        let interval = BrowserPerformance.signposter.beginInterval("TabEviction")
        defer { BrowserPerformance.signposter.endInterval("TabEviction", interval) }
        let primary = primaryWebView
        if let primary, primary.backForwardList.currentItem != nil {
            savedHistory = primary.interactionState
        }
        navigation?.stop()
        navigation?.invalidate()
        navigation = nil
        navigationHasCommittedPage = false
        let coordinator = controller?.webViews
        let primaryIsPooled = primary.map { view in
            coordinator?.allWebViews(for: itemID).contains(where: { $0 === view }) == true
        } ?? false
        coordinator?.releaseWebViews(for: self)
        if let primary, !primaryIsPooled { cleanupClone(primary) }
        primaryWebView = nil
        // WebKit only supplies the original popup navigation. A replacement view must load the
        // saved URL through the normal setup path.
        isPopupHost = false
        primaryWindowId = nil
        // The next view announces itself again (activation included).
        didNotifyOpenToExtensions = false
        stopNativeAudioMonitoring()
        profileAwaitCancellable?.cancel()
        profileAwaitCancellable = nil
        webStoreHandler = nil
        devCapture = nil
        resetTranslation()
        loadingState = .idle
        hasPiPActive = false
        hasPlayingVideo = false
        hasPlayingAudio = false
        hasAudioContent = false
        hasVideoContent = false
        mediaFrames = MediaFrames()
        seenMediaFrames = [:]
        webKitAudible = nil
        media = PageMedia()
        // Also covers `tearDown`, which unloads first.
        switcherSnapshot = nil
    }

    /// Final cleanup when the page ends (item closed, pinned page closed, window closed).
    func tearDown() {
        hasPiPActive = false
        unload()
        savedHistory = nil
        isAudioMuted = false
        controller?.sessionDelegate?.cleanupZoom(for: itemID)
        if webStoreHandler != nil {
            if let controller = primaryWebView?.configuration.userContentController {
                self.controller?.sessionDelegate?.removeWebStoreHandler(from: controller)
            }
            webStoreHandler = nil
        }
    }

    /// Detaches a view from this session: handlers, observers, delegates, superview.
    public func cleanupClone(_ webView: WKWebView) {
        webView.stopLoading()
        // Stop playback through WebKit; releasing the view tears down its document.
        webView.pauseAllMediaPlayback(completionHandler: nil)

        let controller = webView.configuration.userContentController
        for handlerName in messageHandlerNames {
            controller.removeScriptMessageHandler(forName: handlerName)
        }
        controller.removeScriptMessageHandler(forName: "pipStateChange", contentWorld: Self.pipStateWorld)
        controller.removeScriptMessageHandler(forName: Self.translateHandlerName, contentWorld: Self.translateWorld)
        self.controller?.sessionDelegate?.removeWebStoreHandler(from: controller)
        #if os(macOS)
        VaultService.detach(from: controller)
        #endif
        detachDevCaptureHandler(from: webView)
        controller.removeScriptMessageHandler(
            forName: AdvancedRulesEngine.messageHandlerName, contentWorld: .page)

        // Break the retain cycle WKWebView -> contextMenuBridge -> userContentController -> WKWebView.
        if let focusable = webView as? SessionWebView {
            focusable.contextMenuBridge?.detach()
            focusable.contextMenuBridge = nil
        }

        removeThemeColorObserver(from: webView)
        removeNavigationStateObservers(from: webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.controller?.webViews?.removeFromContainers(webView)
    }

    // MARK: - Navigation

    /// Loads a URL into a specific view. File URLs get read access to their directory so local
    /// subresources load. Uses the protocol cache policy: restoring an evicted page with
    /// returnCacheDataElseLoad served the stale cached document without revalidation.
    public static func loadPage(_ url: URL, in webView: WKWebView) {
        WebKitPageNavigation.load(url, in: webView)
    }

    public func load(_ newURL: URL) {
        url = newURL
        // A new page on an unloaded session starts fresh instead of restoring, then leaving, the old one.
        savedHistory = nil
        loadingState = .didStartProvisionalNavigation

        // Grant extension access before loading so content scripts inject at document_start.
        controller?.tabEvents?.grantAccess(to: newURL)

        // Reset audio tracking for the new page; the mute preference is preserved.
        hasAudioContent = false
        hasPlayingAudio = false

        hasFavicon = false
        faviconFetchAttempts = 0

        if usesNativePageHost {
            if let navigation, navigation.profileID == profile?.id {
                navigation.load(newURL)
            } else {
                nativeRequestedURL = newURL
                ensureNativePage()
            }
        } else {
            if navigation == nil { setupWebView(initialLoad: false) }
            navigation?.load(newURL)
        }

        // Keep other windows displaying this page on the same URL.
        controller?.sessionDelegate?.navigateAcrossWindows(itemID, to: newURL)

        Task { @MainActor in
            await fetchAndSetFavicon(for: newURL)
        }
    }

    /// Navigates to typed input with search engine normalization.
    public func navigate(to input: String) {
        let template = controller.map { $0.searchTemplate(forSpace: $0.spaceID(of: itemID)) } ?? SearchProvider.google.queryTemplate
        guard let validURL = URL(string: normalizeURL(input, queryTemplate: template)) else { return }
        load(validURL)
    }

    /// Back in `view`, one window's view of this page (the primary by default). With no page left
    /// to go back to, the tab closes and the tab that opened it shows.
    public func goBack(in view: WKWebView? = nil) {
        let wentBack: Bool
        if let view, view !== primaryWebView {
            wentBack = WebKitPageNavigation.goBack(in: view)
        } else {
            wentBack = navigation?.goBack() ?? false
        }
        if !wentBack, !canGoBack, let controller, let window = controller.window(for: self) {
            controller.returnToOpener(itemID, in: window)
        }
    }

    /// Whether Back does anything: history to go back through, or a tab to return to.
    public var canGoBackOrReturn: Bool { canGoBack || controller?.opener(of: itemID) != nil }

    public func goForward() {
        guard canGoForward else { return }
        navigation?.goForward()
    }

    public func refresh() {
        // An unloaded page has nothing to reload: recreate it, which loads the saved URL.
        guard navigation != nil else {
            loadWebViewIfNeeded()
            controller?.refreshWindows(showing: itemID)
            return
        }
        loadingState = .didStartProvisionalNavigation
        if primaryWebView == nil {
            if navigation?.reload() != true { navigation?.load(url) }
            return
        }
        // The primary view can also belong to the coordinator. Reload each view once.
        var views = controller?.webViews?.allWebViews(for: itemID) ?? []
        if let primary = primaryWebView { views.append(primary) }
        var reloaded = Set<ObjectIdentifier>()
        for view in views where reloaded.insert(ObjectIdentifier(view)).inserted {
            // reload() does nothing when no page ever committed (first load failed).
            if view === primaryWebView {
                if navigation?.reload() != true { navigation?.load(url) }
            } else if !WebKitPageNavigation.reload(view) {
                WebKitPageNavigation.load(url, in: view)
            }
        }
    }

    public func stop() {
        navigation?.stop()
        loadingState = .idle
    }

    /// Loads the page the ad blocker stopped, unblocked until this page moves to another host.
    public func continueToBlockedPage() {
        guard let blockedURL else { return }
        controller?.blocker.continueToBlockedPage(blockedURL, in: self)
        load(blockedURL)
    }

    /// Asks the person to confirm, then loads the page under the certificate warning on its certificate.
    public func visitDespiteCertificateWarning() {
        guard let certificateWarning, certificateWarning.allowsVisit else { return }
        controller?.sessionDelegate?.confirmVisit(despite: certificateWarning, in: self)
    }

    /// Loads the page under `warning` again the way the failed navigation asked for it, so the
    /// history ends up as if the first try had worked. A failed load leaves the committed page
    /// current, so a plain reload would reload that page instead.
    public func retryLoad(of warning: CertificateWarning) {
        let webView = activeWebView
        let list = webView.backForwardList
        let offset = Self.retryOffset(
            for: warning.url, after: mainFrameNavigationType, current: list.currentItem?.url,
            back: list.backList.map(\.url), forward: list.forwardList.map(\.url))
        if offset == 0 {
            webView.reload()
        } else if let offset, let item = list.item(at: offset) {
            webView.go(to: item)
        } else {
            load(warning.url)
        }
    }

    /// Where `url` sits in the history for retrying a navigation of `navigationType` to it: 0 to
    /// reload the current page, the nearest entry back (negative) or forward for a Back or Forward
    /// step, nil to load it as a new page.
    nonisolated static func retryOffset(
        for url: URL, after navigationType: WKNavigationType, current: URL?, back: [URL], forward: [URL]
    ) -> Int? {
        switch navigationType {
        case .reload:
            return current == url ? 0 : nil
        case .backForward:
            for distance in 1...max(1, back.count, forward.count) {
                if back.count >= distance, back[back.count - distance] == url { return -distance }
                if forward.count >= distance, forward[distance - 1] == url { return distance }
            }
            return nil
        default:
            return nil
        }
    }

    /// Back to the page still showing under the blocked-page or certificate card, or closes a page that has none.
    public func leaveBlockedPage() {
        if hasCommittedPage {
            blockedURL = nil
            certificateWarning = nil
        } else if isDetached {
            onClose?()
        } else {
            controller?.close(itemID)
        }
    }

    /// False until a page commits: a blocked first load leaves nothing to go back to.
    public var hasCommittedPage: Bool {
        if let primaryWebView { return primaryWebView.backForwardList.currentItem != nil }
        return navigationHasCommittedPage
    }

    /// Selects this page in the active window (a click inside the web view).
    public func activate() {
        guard let window = controller?.window(for: self) else { return }
        controller?.select(itemID, in: window)
    }

    public func updateNavigationState() {
        guard let state = navigation?.state else { return }
        let newCanGoBack = state.canGoBack
        let newCanGoForward = state.canGoForward
        if newCanGoBack != canGoBack || newCanGoForward != canGoForward {
            canGoBack = newCanGoBack
            canGoForward = newCanGoForward
        }
    }

    /// KVO on canGoBack/canGoForward gives real-time updates. A single delayed check catches
    /// WebKit's back-forward list settling asynchronously after a commit.
    func updateNavigationStateEnhanced(source: String = "unknown") {
        updateNavigationState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateNavigationState()
        }
    }

    public func updateTitle(_ newTitle: String) {
        let resolved = newTitle.isEmpty ? url.host ?? "New Tab" : newTitle
        guard resolved != title else { return }
        title = resolved
        controller?.pageTitleChanged(itemID: itemID, title: resolved)
        controller?.tabEvents?.tabPropertiesChanged(self, properties: [.title])
    }

    // MARK: - Observation

    public func setupNavigationStateObservers(for webView: WKWebView) {
        if !navigationStateObservedWebViews.contains(webView) {
            webView.addObserver(self, forKeyPath: "fullscreenState", options: [.new], context: nil)
            let observesAudio = webView.responds(to: Self.isPlayingAudioSelector)
            mediaLog.info("""
                media audio signal observed item=\(self.itemID, privacy: .public) responds=\(observesAudio, privacy: .public) \
                primary=\(webView === self.primaryWebView, privacy: .public)
                """)
            if observesAudio {
                webView.addObserver(self, forKeyPath: Self.isPlayingAudioKey, options: [.new, .old, .initial], context: nil)
            }
            // No URL observer: it fired during setup and overwrote restored URLs.
            // didCommit/didFinish own URL updates.
            navigationStateObservedWebViews.add(webView)
        }
    }

    func removeNavigationStateObservers(from webView: WKWebView) {
        if navigationStateObservedWebViews.contains(webView) {
            webView.removeObserver(self, forKeyPath: "fullscreenState")
            if webView.responds(to: Self.isPlayingAudioSelector) {
                webView.removeObserver(self, forKeyPath: Self.isPlayingAudioKey)
            }
            navigationStateObservedWebViews.remove(webView)
        }
    }

    public override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "themeColor", let webView = object as? WKWebView {
            // Debounce: themeColor KVO fires several times during a page load.
            pendingThemeColorUpdate?.cancel()
            let item = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.updateBackgroundColor(from: webView)
            }
            pendingThemeColorUpdate = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        } else if keyPath == Self.isPlayingAudioKey, let webView = object as? WKWebView {
            let audible = webView.value(forKey: Self.isPlayingAudioKey) as? Bool
            let applied = webView === self.webView && audible != nil
            mediaLog.info("""
                media audio signal item=\(self.itemID, privacy: .public) \
                value=\(audible.map(String.init) ?? "nil", privacy: .public) \
                initial=\(change?[.oldKey] == nil, privacy: .public) applied=\(applied, privacy: .public)
                """)
            if applied, let audible { webKitAudioChanged(audible) }
        } else if keyPath == "fullscreenState", let webView = object as? WKWebView {
            // The compositor skips its passes while fullscreen; catch up once the page is back.
            if webView.fullscreenState == .notInFullscreen { controller?.refreshWindows(showing: itemID) }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    // MARK: - Favicon

    /// Chromium supplies its own icon; its pages must never use WebKit's
    /// process-wide URLSession/cache path, including during model construction.
    private var usesWebKitFavicon: Bool {
        guard controller?.loadsWebKitFavicons != false else { return false }
        if let navigation { return navigation is WebKitPageNavigation }
        return (detachedProfile?.engine ?? controller?.profileEngine ?? .webKit) == .webKit
    }

    /// Starts a favicon fetch when none has loaded yet, up to `maxFaviconRetries` failures.
    public func ensureFaviconLoaded() {
        guard usesWebKitFavicon else { return }
        guard !hasFavicon, !faviconFetchInFlight else { return }
        guard faviconFetchAttempts < Self.maxFaviconRetries else { return }
        faviconFetchInFlight = true
        Task { @MainActor in
            await fetchAndSetFavicon(for: url)
            faviconFetchInFlight = false
        }
    }

    /// Memory then disk cache, synchronously. Gives restored rows their favicon at once.
    func restoreFaviconFromCache() {
        guard usesWebKitFavicon else { return }
        guard url.scheme == "http" || url.scheme == "https", let host = url.host else { return }
        if let cached = FaviconCache.shared.image(for: host) ?? FaviconCache.shared.imageFromDiskSync(for: host) {
            favicon = SwiftUI.Image(platformImage: cached)
            hasFavicon = true
        }
    }

    func fetchAndSetFavicon(for url: URL) async {
        guard usesWebKitFavicon else { return }
        let defaultFavicon = SwiftUI.Image(systemName: "globe")
        guard url.scheme == "http" || url.scheme == "https", url.host != nil else {
            favicon = defaultFavicon
            return
        }
        let cacheKey = url.host ?? url.absoluteString

        // Show the cached icon at once, and refetch it once a day so a site's new icon replaces the old one.
        let cached = await FaviconCache.shared.cachedImage(for: cacheKey)
        if let cached {
            favicon = SwiftUI.Image(platformImage: cached)
            hasFavicon = true
            guard await FaviconCache.shared.isStale(cacheKey) else { return }
        }

        faviconFetchAttempts += 1

        // FaviconFinder parses HTML <link> tags, then falls back to /favicon.ico. It only
        // fetches through URLSession.shared (shared cookies, disk URLCache), so a private
        // page skips it and takes the root icon below.
        if !isPrivate, let nsImage = await Self.fetchFaviconImage(for: url) {
            FaviconCache.shared.store(nsImage, for: cacheKey)
            favicon = SwiftUI.Image(platformImage: FaviconCache.shared.image(for: cacheKey) ?? nsImage)
            hasFavicon = true
            return
        }

        // Last resort: the root /favicon.ico (for sites whose <link> targets return 403).
        if let rootFaviconURL = URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL,
           let nsImage = await Self.downloadImage(from: rootFaviconURL, isPrivate: isPrivate) {
            // A private page's host must not reach ~/Library/Caches/FaviconCache.
            FaviconCache.shared.store(nsImage, for: cacheKey, toDisk: !isPrivate)
            favicon = SwiftUI.Image(platformImage: FaviconCache.shared.image(for: cacheKey) ?? nsImage)
            hasFavicon = true
            return
        }

        // A failed refresh keeps the cached icon; otherwise hasFavicon stays false so
        // ensureFaviconLoaded() can retry.
        if cached == nil { favicon = defaultFavicon }
    }

    private static func fetchFaviconImage(for url: URL) async -> PlatformImage? {
        do {
            let favicon = try await FaviconFinder(url: url)
                .fetchFaviconURLs()
                .download()
                .largest()
            return favicon.image?.image
        } catch {
            return nil
        }
    }

    /// What private pages fetch their favicon with. An ephemeral config still holds cookies in
    /// memory for the life of the process, so a favicon endpoint could hand back an identifier
    /// that links one private window to the next. Turn cookies, credentials and caching off.
    private static let privateFaviconSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static func downloadImage(from url: URL, isPrivate: Bool) async -> PlatformImage? {
        do {
            let session = isPrivate ? privateFaviconSession : URLSession.shared
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            return PlatformImage(data: data)
        } catch {
            return nil
        }
    }

    // MARK: - Context Menu

    func deliverContextMenuPayload(_ payload: WebContextMenuPayload?) {
        pendingContextMenuPayload = payload
        if let webView = primaryWebView as? SessionWebView {
            webView.contextMenuPayloadDidUpdate(payload)
        }
    }

    // MARK: - Opening links

    /// Opens `url` in a new tab, in the background unless `foreground`, in this page's window and space, as a child of this tab
    /// (a trail). Used by "Open Link in New Tab" in the context menu, a middle click and a
    /// Command-click on a link.
    /// A private window's own tree keeps the link inside that window.
    ///
    /// The URL comes from the page's own markup, so the scheme is checked here rather
    /// than at each caller: a page must not be able to talk Nook into opening a tab on
    /// `javascript:`, `data:` or `file:`.
    /// ponytail: http(s) only. Widen if someone reports a legitimate scheme.
    public func openInNewTab(_ url: URL, foreground: Bool = false) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        guard let tabs = controller, let window = tabs.window(for: self) else { return }
        tabs.open(url: url, in: window, placement: foreground ? .newTab : .background, from: itemID)
    }

    // MARK: - Equality

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PageSession else { return false }
        return itemID == other.itemID
    }

    public override var hash: Int { itemID.hashValue }
}

private extension WKWebView {
    /// `_isDisplayingPDF`, private since macOS 15 and iOS 18. Only a getter name exists, so KVC
    /// on `_displayingPDF` throws. Shared by both platforms since navigation code is; only macOS
    /// draws controls from it.
    var nookIsDisplayingPDF: Bool {
        let selector = NSSelectorFromString("_isDisplayingPDF")
        guard responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: selector), to: Getter.self)(self, selector)
    }

    /// `_clearBackForwardCache`, private on both platforms.
    func nookClearBackForwardCache() {
        let selector = NSSelectorFromString("_clearBackForwardCache")
        guard responds(to: selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method(for: selector), to: Call.self)(self, selector)
    }
}

extension PageSession {
    /// Owner termination never earns metadata deletion or resumes queued selection.
    func nativeOwnerEnded() {
        nativeIsEnding = true
        let release = nativeRelease
        nativeRelease = nil
        controller?.cancelNativeSelection(for: self)
        nativePreparationWindow = nil
        cancelNativeCreation()
        let ended = navigation
        navigation = nil
        nativeResourceHost = nil
        ended?.invalidate()
        navigationHasCommittedPage = false
        loadingState = .idle
        for completion in release?.completions ?? [] { completion(.ownerEnded) }
        // Reentrant completion callbacks cannot revive a request into the ending owner.
        controller?.cancelNativeSelection(for: self)
        nativePreparationWindow = nil
        cancelNativeCreation()
        nativeIsEnding = false
    }
}
