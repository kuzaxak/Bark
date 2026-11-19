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

    // A session keeps the runtime of its first owner across detachment,
    // including when ARC clears the weak controller without calling didSet.
    @ObservationIgnored private var runtimeEngine: Profile.Engine?

    var usesNativePageHost: Bool {
        runtimeEngine == .chromium || detachedProfile?.engine == .chromium
    }

    private var usesWebKitPageHost: Bool {
        runtimeEngine == .webKit && !usesNativePageHost && controller?.profileEngine == .webKit
    }

    @ObservationIgnored public weak var controller: TabsController? {
        didSet {
            if let engine = controller?.profileEngine {
                if let runtimeEngine, runtimeEngine != engine {
                    controller = oldValue
                    return
                }
                runtimeEngine = engine
            }
            if controller !== oldValue {
                cancelNativePageTextCapture()
                resetNativeBoostCSS()
                if controller != nil { refreshNativeBoostCSS() }
            }
        }
    }

    /// The profile whose data store this page uses.
    public var profile: Profile? {
        detachedProfile ?? controller?.profile(for: self)
    }

    // MARK: - Detached Pages

    /// Set while the page is shown outside the tab tree, in Peek or a mini window: the data store
    /// it uses and the window it belongs to. Cleared when the page becomes a tab.
    @ObservationIgnored public internal(set) var detachedProfile: Profile? {
        didSet {
            if runtimeEngine == nil { runtimeEngine = detachedProfile?.engine }
        }
    }
    @ObservationIgnored public internal(set) weak var detachedWindow: BrowserWindowState?
    /// Runs when the page calls `window.close()`, so Peek or the mini window can close.
    @ObservationIgnored public var onClose: (() -> Void)?
    public var isDetached: Bool { detachedProfile != nil }

    // MARK: - Page State

    /// Last committed URL (or the URL being loaded when nothing has committed yet).
    public var url: URL
    public var title: String
    private var faviconImage: PlatformImage?
    public var favicon: SwiftUI.Image {
        faviconImage.map(SwiftUI.Image.init(platformImage:)) ?? SwiftUI.Image(systemName: "globe")
    }
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

    public var loadingState: LoadingState = .idle {
        didSet { if !loadingState.isLoading { loadProgress = nil } }
    }
    public private(set) var loadProgress: Double?
    public var isLoading: Bool { loadingState.isLoading }
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false
    /// Whether the current WebKit document is a PDF, for text capture and translation.
    var isDisplayingPDF = false
    /// A small picture of the page taken as the window left it, for the Control-Tab switcher.
    public var switcherSnapshot: PlatformImage? {
        didSet { if switcherSnapshot == nil { switcherSnapshotGeneration &+= 1 } }
    }
    @ObservationIgnored var switcherSnapshotGeneration: UInt64 = 0
    @ObservationIgnored var switcherCaptureInFlight: UUID?

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
    @ObservationIgnored var nativePageTextTask: Task<Void, Never>?
    @ObservationIgnored var nativeTopBarSample: Task<Void, Never>?

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
            // Native engine snapshots are authoritative; legacy device-output
            // monitoring cannot identify a Chromium tab's activity.
            if usesNativePageHost || (navigation != nil && !(navigation is WebKitPageNavigation)) { return }
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

    // MARK: - OAuth Flow State

    /// Whether this page hosts an OAuth/sign-in flow popup.
    public var isOAuthFlow: Bool = false {
        didSet {
            if isOAuthFlow != oldValue { controller?.blocker.refreshNetworkPolicy(for: self) }
        }
    }

    // MARK: - Internal State

    /// Back and forward history kept across an unload, so the next view comes back with it.
    @ObservationIgnored var savedHistory: Any?
    /// Counts back and forward swipes, so a late snapshot cleanup never touches a newer swipe.
    @ObservationIgnored var navigationGestureCount = 0
    /// The page's address as it may be stored, copied or shown: without a Kagi session token.
    public var storableURL: URL { KagiSession.withoutToken(url) }

    /// The palette chose this page's next load, so its visit counts double in history ranking.
    @ObservationIgnored public var typedVisitPending = false
    /// How the latest main-frame navigation started; a reload adds nothing to history ranking.
    @ObservationIgnored var mainFrameNavigationType: WKNavigationType = .other
    /// JavaScript dialogs since the last commit, and whether the user silenced the page.
    @ObservationIgnored var jsDialogCount = 0
    @ObservationIgnored var jsDialogsSuppressed = false

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
    @ObservationIgnored var didNotifyOpenToExtensions: Bool = false

    @ObservationIgnored let themeColorObservedWebViews = NSHashTable<AnyObject>.weakObjects()
    @ObservationIgnored let navigationStateObservedWebViews = NSHashTable<AnyObject>.weakObjects()

    // MARK: - Web View Ownership

    @ObservationIgnored private var nativeBoostTask: Task<Void, Never>?
    @ObservationIgnored private var nativeBoostObserver: NSObjectProtocol?
    @ObservationIgnored private var nativeBoostDocument: UInt64 = 0
    @ObservationIgnored private var nativeBoostRequest: UInt64 = 0
    @ObservationIgnored private var nativeBoostCSS: String?
    @ObservationIgnored private var nativeBoostPreview: (id: UUID, document: UInt64, draft: Boost?)?
    private var navigationDocumentURL: URL?
    private var navigationHasCommittedPage = false
    private var navigationVisitRecorded = false
    private var navigationFinishedReported = false
    private var navigationCancelled = false
    var nativeAgentPreparationID: UUID?
    var nativeAgentWaitID: UUID?
    public private(set) var nativeNavigationSerial: UInt64 = 0
    var nativeNavigationPendingStart = false
    var nativeNavigationFinishedWasReload = false
    @ObservationIgnored var nativeCreation: NativePageCreation?
    @ObservationIgnored var nativeRelease: NativePageRelease?
    @ObservationIgnored weak var nativeResourceHost: (any NativePageResourceOwner)?
    @ObservationIgnored var nativeRequestedURL: URL?
    @ObservationIgnored var nativePrivatePendingSearch: String?
    @ObservationIgnored var nativeSearchIntent: (id: UUID, query: String, serial: UInt64?)?
    @ObservationIgnored weak var nativePreparationWindow: BrowserWindowState?
    @ObservationIgnored var nativePreparationCompletions: [@MainActor (Bool) -> Void] = []
    /// Only the synchronous private-tree ownership handoff owns this token.
    @ObservationIgnored var nativeTransfer: (token: UUID, destination: UUID)?
    @ObservationIgnored var nativeIsEnding = false
    @ObservationIgnored var nativeUnloadPending = false
    /// Reading the bound engine page never creates or loads a resource.
    public var nativeVaultNotice: String?
    @ObservationIgnored private var nativeVaultDetach: (@MainActor () -> Void)?
    public internal(set) var navigation: (any PageNavigation)? {
        didSet {
            guard oldValue !== navigation else { return }
            faviconImage = nil
            loadProgress = nil
            nativeVaultNotice = nil
            #if os(macOS)
            nativeVaultDetach?()
            nativeVaultDetach = nil
            if !isAgentPage, let page = navigation as? any VaultNativePage, let vault = controller?.vault {
                nativeVaultDetach = vault.attach(to: page, session: self)
            }
            #endif
            cancelNativePageTextCapture()
            oldValue?.onTranslationNodes = nil
            resetTranslation()
        }
    }
    @ObservationIgnored lazy var webKitDelegate = WebKitPageDelegateAdapter(session: self)

    var primaryWebView: WKWebView? {
        didSet {
            guard primaryWebView !== oldValue else { return }
            navigation?.invalidate()
            navigation = nil
            resetNativeBoostCSS()
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
        isDisplayingPDF = false
        if usesNativePageHost { nativeNavigationPendingStart = false }
        page.onEvent = { [weak self, weak page] event in
            guard let self, let page, self.navigation === page else { return }
            self.navigationChanged(event)
        }
        page.onStateChanged = { [weak self, weak page] state in
            guard let self, let page, self.navigation === page else { return }
            self.applyNavigationState(state)
            self.settleStagedNativeSearch()
        }
        applyNavigationState(page.state, applyingInitialMedia: true)
        if let url = page.state.url { self.url = url }
        navigationDocumentURL = page.state.isLoading ? nil : page.state.url
        navigationHasCommittedPage = page.state.url != nil && !page.state.isLoading
        navigationVisitRecorded = navigationHasCommittedPage
        navigationFinishedReported = navigationHasCommittedPage
        navigationCancelled = false
        loadingState = page.state.isLoading ? .didStartProvisionalNavigation :
            (page.state.url == nil ? .idle : .didFinish)
        resetNativeBoostCSS()
        refreshNativeBoostCSS()
    }

    /// A bound factory blank is not completion of its requested target load.
    /// This reuses actual navigation events, including dispatch failure/cancel.
    var nativeStartupNavigationHasSettled: Bool {
        guard navigation != nil, nativeCreation == nil, !nativeIsEnding, nativeSearchIntent == nil else { return false }
        switch loadingState {
        case .didFinish: return navigationFinishedReported
        case .didFail, .didFailProvisionalNavigation: return true
        default: return navigationCancelled
        }
    }

    func loadNativeTarget(_ target: URL, through page: any PageNavigation) {
        if let intent = nativeSearchIntent {
            performNativeSearch(intent, through: page)
            return
        }
        nativeNavigationPendingStart = true
        navigationFinishedReported = false
        navigationCancelled = false
        loadingState = .didStartProvisionalNavigation
        page.load(target)
    }

    func resetNativeBoostCSS() {
        navigation?.cancelElementPicker()
        if let observer = nativeBoostObserver {
            NotificationCenter.default.removeObserver(observer)
            nativeBoostObserver = nil
        }
        nativeBoostTask?.cancel()
        nativeBoostTask = nil
        nativeBoostDocument &+= 1
        nativeBoostPreview = nil
        nativeBoostCSS = nil
    }

    /// An editor lease belongs to one existing native document. It never
    /// creates a page or writes the draft to persisted Boost settings.
    public func beginNativeBoostPreview() -> UUID? {
        let document = nativeBoostDocument, previous = nativeBoostPreview?.id
        guard usesNativePageHost, let page = navigation, page.supportsUserCSS,
              !page.state.isLoading, !nativeIsEnding,
              let controller, !controller.isTerminating, controller.settings.boostsLoaded,
              profile?.id == page.profileID,
              let url = navigationDocumentURL ?? page.state.url,
              url.scheme == "http" || url.scheme == "https",
              navigation === page, nativeBoostDocument == document,
              nativeBoostPreview?.id == previous else { return nil }
        let id = UUID()
        page.cancelElementPicker()
        guard navigation === page, nativeBoostDocument == document, nativeBoostPreview?.id == previous else { return nil }
        nativeBoostPreview = (id, document, nil)
        // A replaced preview may already be applied with its acknowledgement pending.
        nativeBoostCSS = nil
        refreshNativeBoostCSS()
        return id
    }

    public func pickNativeBoostElement(token: UUID) async -> String? {
        guard let preview = nativeBoostPreview, preview.id == token,
              preview.document == nativeBoostDocument, !nativeIsEnding,
              let page = navigation, page.supportsElementPicker,
              !page.state.isLoading, profile?.id == page.profileID,
              nativeBoostPreview?.id == token, navigation === page else { return nil }
        let result = await page.pickElement()
        guard !Task.isCancelled, !nativeIsEnding, navigation === page,
              nativeBoostPreview?.id == token, nativeBoostDocument == preview.document,
              profile?.id == page.profileID, let result, result.utf8.count <= 2048 else { return nil }
        return result
    }
    public func cancelNativeBoostElementPicker(token: UUID) {
        guard nativeBoostPreview?.id == token else { return }
        navigation?.cancelElementPicker()
    }

    @discardableResult public func previewNativeBoost(_ draft: Boost, token: UUID) -> Bool {
        guard var preview = nativeBoostPreview, preview.id == token,
              preview.document == nativeBoostDocument, !nativeIsEnding,
              let page = navigation, !page.state.isLoading,
              profile?.id == page.profileID, navigation === page,
              preview.document == nativeBoostDocument,
              nativeBoostPreview?.id == token else { return false }
        preview.draft = draft
        nativeBoostPreview = preview
        refreshNativeBoostCSS()
        return true
    }

    public func endNativeBoostPreview(_ token: UUID) {
        guard let preview = nativeBoostPreview, preview.id == token else { return }
        nativeBoostPreview = nil
        navigation?.cancelElementPicker()
        guard preview.document == nativeBoostDocument else { return }
        // Force a saved-state reapply even if the last preview acknowledgement
        // has not arrived. Existing request/document guards reject late replies.
        nativeBoostCSS = nil
        refreshNativeBoostCSS()
    }

    /// Reuses global Boost matching; no script execution, frame walk or page creation.
    func refreshNativeBoostCSS() {
        guard usesNativePageHost, let page = navigation, page.supportsUserCSS,
              let controller, !controller.isTerminating, !nativeIsEnding else { return }
        let settings = controller.settings
        if nativeBoostObserver == nil {
            nativeBoostObserver = NotificationCenter.default.addObserver(
                forName: .boostsChanged, object: nil, queue: .main
            ) { [weak self, weak settings] notice in
                MainActor.assumeIsolated {
                    guard let self, let settings,
                          let source = notice.object as? NookSettingsService,
                          source === settings, self.controller?.settings === settings else { return }
                    self.refreshNativeBoostCSS()
                }
            }
        }
        guard let url = navigationDocumentURL ?? page.state.url,
              url.scheme == "http" || url.scheme == "https" else { return }
        nativeBoostTask?.cancel()
        let document = nativeBoostDocument
        nativeBoostTask = Task { @MainActor [weak self, weak page, weak controller] in
            await settings.waitForBoosts()
            guard !Task.isCancelled, let self, let page, let controller,
                  self.navigation === page, self.controller === controller,
                  !controller.isTerminating, !self.nativeIsEnding,
                  (controller.session(for: self.itemID) === self ||
                   (self.detachedProfile?.engine == .chromium && self.nativeResourceHost != nil)),
                  self.nativeBoostDocument == document,
                  (self.navigationDocumentURL ?? page.state.url) == url,
                  self.profile?.id == page.profileID else { return }
            var boosts = settings.boosts
            if let preview = self.nativeBoostPreview, preview.document == document,
               let draft = preview.draft {
                if let index = boosts.firstIndex(where: { $0.id == draft.id }) { boosts[index] = draft }
                else { boosts.append(draft) }
            }
            let css = Boost.css(for: url, in: boosts)
            guard self.nativeBoostCSS != css else { return }
            self.nativeBoostRequest &+= 1
            let request = self.nativeBoostRequest
            self.nativeBoostCSS = css
            let accepted = page.setUserCSS(css, for: url) { [weak self, weak page] applied in
                guard let self, let page, self.navigation === page,
                      self.nativeBoostDocument == document,
                      self.nativeBoostRequest == request else { return }
                if !applied { self.nativeBoostCSS = nil }
            }
            if !accepted, self.nativeBoostRequest == request {
                self.nativeBoostCSS = nil
            }
        }
    }

    private func applyNavigationState(_ state: PageNavigationState, applyingInitialMedia: Bool = false) {
        if faviconImage !== state.favicon { faviconImage = state.favicon }
        canGoBack = state.canGoBack
        canGoForward = state.canGoForward
        if let muted = state.isAudioMuted, isAudioMuted != muted { isAudioMuted = muted }
        if let audible = state.isAudible {
            if hasAudioContent != audible { hasAudioContent = audible }
            if hasPlayingAudio != audible { hasPlayingAudio = audible }
            if navigation != nil, !(navigation is WebKitPageNavigation), media.isAudible != audible {
                var observed = media; observed.isAudible = audible; media = observed
            }
        }
        if let video = state.hasVideoPictureInPicture, let document = state.hasDocumentPictureInPicture {
            if hasPiPActive != (video || document) { hasPiPActive = video || document }
        }
        if applyingInitialMedia { applyNativeMedia(state.media) }
        if let title = state.title, !title.isEmpty { updateTitle(title) }
        // A displayed pending URL is not a committed URL to persist. Only
        // lifecycle events notify the tree or append a history visit.
        if let url = state.url { self.url = url }
        loadProgress = state.isLoading ? state.loadProgress : nil
        if state.isLoading {
            if !loadingState.isLoading { loadingState = .didStartProvisionalNavigation }
        } else if loadingState.isLoading {
            loadingState = .didFinish
        }
        // A nonloading snapshot must not erase an explicit failure/cancellation.
    }

    private func applyNativeMedia(_ snapshot: PageMedia?) {
        guard navigation != nil, !(navigation is WebKitPageNavigation) else { return }
        let known = snapshot.flatMap { $0.isKnown ? $0 : nil }
        var observed = known ?? media
        if known == nil {
            // Retain presence/playback so a paused player's existing rank
            // survives transient unknown ownership. No stale track or commands.
            observed.isKnown = false; observed.canPlay = false; observed.canPause = false
            observed.handlesPreviousTrack = false; observed.handlesNextTrack = false
            observed.title = nil; observed.artist = nil; observed.album = nil
            observed.isAudible = hasAudioContent
        }
        if media != observed { media = observed }
        if let snapshot = known {
            if hasAudioContent != snapshot.isAudible { hasAudioContent = snapshot.isAudible }
            if hasPlayingAudio != snapshot.isAudible { hasPlayingAudio = snapshot.isAudible }
            if hasVideoContent != snapshot.hasVideo { hasVideoContent = snapshot.hasVideo }
            if hasPlayingVideo != snapshot.isPlayingVideo { hasPlayingVideo = snapshot.isPlayingVideo }
        }
        // Unknown clears stale controls/track metadata, but never declares old
        // audio/video protection inactive. Required native activity stays held.
    }

    private func clearNativeMediaForDocumentEnd() {
        guard navigation != nil, !(navigation is WebKitPageNavigation) else { return }
        let empty = PageMedia(isKnown: false, canPlay: false, canPause: false)
        if media != empty { media = empty }
    }

    @ObservationIgnored private var navigationPeekIntent: UInt64 = 0

    private func settleStagedNativeSearch() {
        guard let intent = nativeSearchIntent else { return }
        nativeNavigationPendingStart = true
        loadingState = .didStartProvisionalNavigation
        guard intent.serial == nil, let page = navigation, !page.state.isLoading else { return }
        Task { @MainActor [weak self, weak page] in
            guard let self, let page, self.navigation === page,
                  self.nativeSearchIntent?.id == intent.id else { return }
            self.performNativeSearch(intent, through: page)
        }
    }

    func navigationChanged(_ event: PageNavigationEvent) {
        defer { settleStagedNativeSearch() }
        switch event {
        case .started(let newURL):
            nativeVaultNotice = nil
            #if os(macOS)
            if usesNativePageHost { controller?.vault?.navigationStarted() }
            #endif
            if nativeSearchIntent?.serial != nil { nativeSearchIntent = nil }
            cancelNativePageTextCapture()
            navigationPeekIntent &+= 1
            if usesNativePageHost {
                nativeNavigationSerial &+= 1
                nativeNavigationPendingStart = false
                nativeNavigationFinishedWasReload = false
            }
            switcherSnapshot = nil
            navigationVisitRecorded = false
            navigationFinishedReported = false
            navigationCancelled = false
            loadingState = .didStartProvisionalNavigation
            blockedURL = nil
            certificateWarning = nil
            controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.loading])
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
            if usesNativePageHost { controller?.blocker.refreshNetworkPolicy(for: self, navigationStarted: true) }
        case .committed(let newURL, let sameDocument):
            cancelNativePageTextCapture()
            if !sameDocument { navigationPeekIntent &+= 1 }
            if sameDocument, usesNativePageHost {
                // Chromium emits no started/finished pair for same-document
                // navigation: its committed event is the terminal fact.
                nativeNavigationSerial &+= 1
                nativeNavigationPendingStart = false
                nativeNavigationFinishedWasReload = false
                navigationFinishedReported = true
                loadingState = .didFinish
            }
            if !sameDocument { resetTranslation(); clearNativeMediaForDocumentEnd(); resetNativeBoostCSS() }
            switcherSnapshot = nil
            if let newURL { navigationDocumentURL = newURL }
            if newURL != nil { navigationHasCommittedPage = true }
            refreshNativeBoostCSS()
            if !sameDocument {
                navigationVisitRecorded = false
                navigationFinishedReported = false
                navigationCancelled = false
                loadingState = .didCommit
                certificateWarning = nil
                controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.loading])
            }
            if let newURL {
                url = newURL
                let privateSearchCommit = usesNativePageHost && isPrivate && nativePrivatePendingSearch != nil &&
                    nativeSearchIntent == nil && newURL.absoluteString != "about:blank"
                // Detached private pages have no saved-item registration, but
                // an actual commit still settles their page-local cold query.
                if privateSearchCommit { nativePrivatePendingSearch = nil }
                controller?.pageCommitted(itemID: itemID, url: newURL, resolvingPrivateSearch: privateSearchCommit)
                controller?.webKitSessionDelegate?.navigateAcrossWindows(itemID, to: newURL)
                if !isDetached { controller?.webKitSessionDelegate?.shortcutDetectorDidNavigate(to: newURL) }
                controller?.webKitTabEvents?.grantAccess(to: newURL)
                controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.URL])
            }
            if sameDocument { scheduleNativePageTextCapture(sameDocument: true) }
        case .finished(let newURL, let finalTitle, let isReload):
            guard !navigationCancelled else { return }
            if usesNativePageHost { nativeNavigationFinishedWasReload = isReload }
            if let newURL { navigationDocumentURL = newURL }
            if newURL != nil { navigationHasCommittedPage = true }
            loadingState = .didFinish
            if !navigationFinishedReported {
                navigationFinishedReported = true
                scheduleNativePageTextCapture(sameDocument: false)
                if usesNativePageHost { offerTranslationIfNeeded() }
                controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.loading])
                if let newURL {
                    url = newURL
                    controller?.webKitTabEvents?.grantAccess(to: newURL)
                    controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.URL])
                    controller?.webKitTabEvents?.wakeBackgroundWorkers()
                    controller?.pageCommitted(itemID: itemID, url: newURL)
                    controller?.webKitSessionDelegate?.navigateAcrossWindows(itemID, to: newURL)
                }
                sampleNativeTopBarColor()
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
            cancelNativePageTextCapture()
            if !provisional { clearNativeMediaForDocumentEnd() }
            if let committedURL { navigationDocumentURL = committedURL }
            if let committedURL, committedURL != url {
                url = committedURL
                controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.URL])
                controller?.pageCommitted(itemID: itemID, url: committedURL)
            }
            loadingState = provisional ? .didFailProvisionalNavigation(error) : .didFail(error)
        case .cancelled(let committedURL):
            cancelNativePageTextCapture()
            if let committedURL { navigationDocumentURL = committedURL }
            refreshNativeBoostCSS()
            navigationCancelled = true
            navigationVisitRecorded = true
            typedVisitPending = false
            loadingState = .idle
            if let committedURL, committedURL != url {
                url = committedURL
                controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.URL])
                controller?.pageCommitted(itemID: itemID, url: committedURL)
            }
            controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.loading])
        case .nativeBlocked(let target):
            guard usesNativePageHost, !nativeIsEnding, !nativeNavigationPendingStart,
                  navigation?.profileID == profile?.id else { return }
            blockedURL = target
        case .continueNativeBlock(let target):
            guard usesNativePageHost, let navigation, let controller,
                  blockedURL == target, !nativeIsEnding, !nativeNavigationPendingStart else { return }
            let serial = nativeNavigationSerial
            let profileID = profile?.id
            Task { @MainActor [weak self, weak navigation, weak controller] in
                guard let self, let navigation, let controller,
                      self.navigation === navigation, self.controller === controller,
                      !controller.isTerminating, !self.nativeIsEnding,
                      !self.nativeNavigationPendingStart, self.nativeNavigationSerial == serial,
                      self.profile?.id == profileID, navigation.profileID == profileID,
                      self.blockedURL == target,
                      controller.session(for: self.itemID) === self ||
                        (self.isDetached && self.nativeResourceHost != nil) else { return }
                self.continueToBlockedPage()
            }
        case .peekRequested(let target):
            guard let navigation, !nativeIsEnding else { return }
            navigationPeekIntent &+= 1
            let intent = navigationPeekIntent
            // Leave the native observer stack before creating a page. A newer
            // request/document or terminal event invalidates this exact intent.
            Task { @MainActor [weak self, weak navigation] in
                guard let self, let navigation, self.navigation === navigation,
                      !self.nativeIsEnding, self.navigationPeekIntent == intent else { return }
                self.controller?.sessionDelegate?.presentPeek(url: target, from: self)
            }
        case .mediaChanged(let media):
            applyNativeMedia(media)
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
            resetNativeBoostCSS()
            ended?.invalidate()
            navigationHasCommittedPage = false
            loadingState = .idle
            onClose?()
            if !isDetached { controller?.close(itemID) }
            if !isPrivate && !isDetached { controller?.nativeSyncAdmissionChanged() }
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
        guard !usesNativePageHost, navigation is WebKitPageNavigation else { return false }
        return view === primaryWebView ||
            controller?.webViews?.allWebViews(for: itemID).contains(where: { $0 === view }) == true
    }

    /// The window that owns the primary web view; nil until a window displays the page.
    @ObservationIgnored var primaryWindowId: UUID?

    public var isUnloaded: Bool { navigation == nil }

    /// Console and network log while Developer Mode is on; nil otherwise.
    public internal(set) var devCapture: DevCapture?

    /// Drop cached history documents, preserving history and the current live page.
    /// Returns acceptance, not a cached-entry count or reclaimed-memory claim.
    @discardableResult public func clearPageCache() -> Bool {
        if usesNativePageHost {
            guard !nativeIsEnding, let navigation, let profile,
                  navigation.profileID == profile.id else { return false }
            return navigation.clearBackForwardCache()
        }
        return primaryWebView?.nookClearBackForwardCache() ?? false
    }

    /// The web view, created on first access.
    var activeWebView: WKWebView {
        if primaryWebView == nil {
            setupWebView()
        }
        return primaryWebView!
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
        self.runtimeEngine = controller?.profileEngine
        super.init()
    }

    deinit {
        nativePageTextTask?.cancel()
        nativeTopBarSample?.cancel()
        nativeBoostTask?.cancel()
        if let nativeBoostObserver { NotificationCenter.default.removeObserver(nativeBoostObserver) }
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
    }

    /// Makes `webView` the primary view, owned by the window that displays it first.
    func assignWebView(_ webView: WKWebView, toWindow windowId: UUID) {
        primaryWebView = webView
        primaryWindowId = windowId
    }

    private func setupWebView(initialLoad: Bool = true) {
        guard usesWebKitPageHost, navigation == nil else { return }
        let interval = BrowserPerformance.signposter.beginInterval("WebViewCreation")
        defer { BrowserPerformance.signposter.endInterval("WebViewCreation", interval) }
        let resolvedProfile = profile
        guard resolvedProfile?.engine != .chromium else { return }
        let configuration: WKWebViewConfiguration
        if let resolvedProfile {
            guard let webConfiguration = BrowserConfiguration.webViewConfiguration(for: resolvedProfile) else { return }
            configuration = webConfiguration
        } else {
            // Edge case: no profile yet. Delay creating WKWebView until one resolves.
            if profileAwaitCancellable == nil {
                profileAwaitCancellable = controller?.webKitSessionDelegate?
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
                  let extensionController = controller?.webKitTabEvents?.nativeController {
            configuration.webExtensionController = extensionController
        }

        // An agent page cannot take the person's screen for element full screen. Its own copy of
        // the preferences, so other pages keep full screen.
        if isAgentPage, let preferences = configuration.preferences.copy() as? WKPreferences {
            preferences.isElementFullscreenEnabled = false
            configuration.preferences = preferences
        }
        let created = controller?.webViews?.makeWebView(configuration: configuration)
        primaryWebView = created

        guard let webView = primaryWebView else {
            Self.log.error("No web view created for item \(self.itemID.uuidString, privacy: .public)")
            return
        }
        webView.navigationDelegate = webKitDelegate
        webView.uiDelegate = webKitDelegate
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        setupThemeColorObserver(for: webView)
        setupNavigationStateObservers(for: webView)
        configure(webView)

        // Inform extensions before loading so content scripts and messaging can resolve this
        // page during early document phases.
        if !didNotifyOpenToExtensions {
            controller?.webKitTabEvents?.tabOpened(self)
            if controller?.activeWindowSession === self {
                controller?.tabEvents?.tabActivated(new: self, previous: nil)
            }
            didNotifyOpenToExtensions = true
        }
        let history = savedHistory
        savedHistory = nil
        if initialLoad, let history {
            webView.interactionState = history
            // Restoring shows the cached copy, as Back does; reload revalidates it like a fresh load.
            if webView.reload() == nil { load(url) }
        } else if initialLoad {
            load(url)
        }
    }

    /// Handlers, user agent and preferences shared by primary, clone and popup views.
    /// The view's controller must belong to this view alone: handlers are keyed by name.
    private func configure(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        for name in messageHandlerNames {
            controller.removeScriptMessageHandler(forName: name)
            controller.add(webKitDelegate, name: name)
        }
        controller.removeScriptMessageHandler(forName: "pipStateChange", contentWorld: Self.pipStateWorld)
        controller.add(webKitDelegate, contentWorld: Self.pipStateWorld, name: "pipStateChange")
        controller.removeScriptMessageHandler(forName: Self.translateHandlerName, contentWorld: Self.translateWorld)
        controller.add(webKitDelegate, contentWorld: Self.translateWorld, name: Self.translateHandlerName)
        controller.addUserScript(WKUserScript(source: MediaScript.reporter(handler: "mediaStateChange_\(itemID.uuidString)"),
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: false))
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
        webView.navigationDelegate = webKitDelegate
        webView.uiDelegate = webKitDelegate
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        primaryWebView = webView
        configure(webView)
        setupThemeColorObserver(for: webView)
        setupNavigationStateObservers(for: webView)
        if !didNotifyOpenToExtensions, !isPrivate {
            controller?.webKitTabEvents?.tabOpened(self)
            didNotifyOpenToExtensions = true
        }
    }

    /// Updates the extension controller on the existing web view.
    func applyConfigurationOverride(_ configuration: WKWebViewConfiguration) {
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
        resetNativeBoostCSS()
        navigationHasCommittedPage = false
        let coordinator = controller?.webViews
        let primaryIsPooled = primary.map { view in
            coordinator?.allWebViews(for: itemID).contains(where: { $0 === view }) == true
        } ?? false
        coordinator?.releaseWebViews(for: self)
        if let primary, !primaryIsPooled { cleanupClone(primary) }
        primaryWebView = nil
        primaryWindowId = nil
        // The next view announces itself again (activation included).
        didNotifyOpenToExtensions = false
        stopNativeAudioMonitoring()
        profileAwaitCancellable?.cancel()
        profileAwaitCancellable = nil
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
    }

    /// Detaches a view from this session: handlers, observers, delegates, superview.
    private func cleanupClone(_ webView: WKWebView) {
        webView.stopLoading()
        // Stop playback through WebKit; releasing the view tears down its document.
        webView.pauseAllMediaPlayback(completionHandler: nil)

        let controller = webView.configuration.userContentController
        for handlerName in messageHandlerNames {
            controller.removeScriptMessageHandler(forName: handlerName)
        }
        controller.removeScriptMessageHandler(forName: "pipStateChange", contentWorld: Self.pipStateWorld)
        controller.removeScriptMessageHandler(forName: Self.translateHandlerName, contentWorld: Self.translateWorld)
        detachDevCaptureHandler(from: webView)
        controller.removeScriptMessageHandler(
            forName: AdvancedRulesEngine.messageHandlerName, contentWorld: .page)

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
    static func loadPage(_ url: URL, in webView: WKWebView) {
        WebKitPageNavigation.load(url, in: webView)
    }

    public func load(_ newURL: URL) {
        nativePrivatePendingSearch = nil
        controller?.storePendingSearch(nil, for: self)
        nativeSearchIntent = nil
        if usesNativePageHost {
            nativeAgentPreparationID = nil
            nativeAgentWaitID = nil
        }
        url = newURL
        // A new page on an unloaded session starts fresh instead of restoring, then leaving, the old one.
        savedHistory = nil
        loadingState = .didStartProvisionalNavigation

        // Grant extension access before loading so content scripts inject at document_start.
        controller?.webKitTabEvents?.grantAccess(to: newURL)

        // Reset audio tracking for the new page; the mute preference is preserved.
        hasAudioContent = false
        hasPlayingAudio = false

        if usesNativePageHost {
            if let navigation, navigation.profileID == profile?.id {
                loadNativeTarget(newURL, through: navigation)
            } else {
                nativeRequestedURL = newURL
                ensureNativePage()
            }
        } else {
            if navigation == nil { setupWebView(initialLoad: false) }
            navigation?.load(newURL)
        }

        // Keep other windows displaying this page on the same URL.
        controller?.webKitSessionDelegate?.navigateAcrossWindows(itemID, to: newURL)
    }

    private func performNativeSearch(_ intent: (id: UUID, query: String, serial: UInt64?), through page: any PageNavigation) {
        guard let controller, let profileID = profile?.id else { return }
        // Cold factory documents settle through the same lifecycle events.
        // Do not weaken ownership to a URL match while metadata is loading.
        guard !page.state.isLoading, nativeSearchIntent?.id == intent.id,
              nativeSearchIntent?.serial == nil else { return }
        let serial = nativeNavigationSerial
        nativeSearchIntent?.serial = serial
        controller.profileSearchState(profileID: profileID, page: self, includeChoices: false) { [weak self, weak page] result in
            guard let self, let page, self.navigation === page,
                  self.nativeSearchIntent?.id == intent.id, !self.nativeIsEnding,
                  self.profile?.id == profileID, self.nativeNavigationSerial == serial else { return }
            self.nativeSearchIntent = nil
            self.nativeRequestedURL = nil
            if case .success(let effective) = result {
                self.nativeNavigationPendingStart = true
                self.navigationFinishedReported = false
                self.navigationCancelled = false
                self.loadingState = .didStartProvisionalNavigation
                let token = effective.kagiSession ? controller.settings.kagiSessionToken : nil
                if page.search(intent.query, kagiSessionToken: token) { return }
                guard self.navigation === page, !self.nativeIsEnding,
                      self.nativeSearchIntent == nil, self.profile?.id == profileID else { return }
            }
            self.nativeNavigationPendingStart = false
            self.loadingState = .didFailProvisionalNavigation(ProfileSearchError.refused)
        }
    }

    /// Stages the existing intent without requesting a native page. A regular
    /// cold tab survives quit; a private tab holds only this in-memory tuple.
    func stageNativeSearch(_ query: String, persist: Bool = true) {
        if isPrivate { nativePrivatePendingSearch = query }
        nativeSearchIntent = (UUID(), query, nil)
        nativeRequestedURL = URL(string: "about:blank")!
        if navigation != nil {
            nativeNavigationPendingStart = true
            loadingState = .didStartProvisionalNavigation
        }
        if persist { controller?.storePendingSearch(query, for: self) }
    }

    func resumeStagedNativeSearch() {
        guard let page = navigation, let intent = nativeSearchIntent else { return }
        performNativeSearch(intent, through: page)
    }

    var pendingNativeSearchQuery: String? {
        isPrivate ? nativePrivatePendingSearch : controller?.device.openPages[itemID]?.pendingSearch
    }

    func restorePendingNativeSearch() {
        guard usesNativePageHost, navigation == nil, nativeSearchIntent == nil,
              let query = pendingNativeSearchQuery else { return }
        stageNativeSearch(query, persist: false)
    }

    /// Navigates to typed input with search engine normalization.
    public func navigate(to input: String) {
        if usesNativePageHost && isSearchInput(input) {
            nativeAgentPreparationID = nil
            nativeAgentWaitID = nil
            navigation?.stop()
            stageNativeSearch(input)
            nativeNavigationPendingStart = true
            loadingState = .didStartProvisionalNavigation
            nativeRequestedURL = URL(string: "about:blank")!
            savedHistory = nil
            if let page = navigation, let intent = nativeSearchIntent {
                performNativeSearch(intent, through: page)
            } else {
                ensureNativePage()
            }
            return
        }
        if usesNativePageHost {
            if let target = URL(string: normalizeURL(input, queryTemplate: "nook-search:%@")) { load(target) }
            return
        }
        let template = controller.map { $0.searchTemplate(forSpace: $0.spaceID(of: itemID)) } ?? SearchProvider.google.queryTemplate
        guard let validURL = URL(string: normalizeURL(input, queryTemplate: template)) else { return }
        load(validURL)
    }

    /// Goes back on the live page or closes it to return to its opener when history is empty.
    public func goBack() {
        returnToOpenerIfNeeded(afterGoingBack: navigation?.goBack() ?? false)
    }

    func returnToOpenerIfNeeded(afterGoingBack wentBack: Bool) {
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
        nativePrivatePendingSearch = nil
        controller?.storePendingSearch(nil, for: self)
        nativeSearchIntent = nil
        navigation?.stop()
        if usesNativePageHost { nativeNavigationPendingStart = false; navigationCancelled = true }
        loadingState = .idle
    }

    /// Loads the page the ad blocker stopped, unblocked until this page moves to another host.
    public func continueToBlockedPage() {
        guard let blockedURL, let controller,
              controller.blocker.continueToBlockedPage(blockedURL, in: self) else { return }
        self.blockedURL = nil
        load(blockedURL)
    }

    /// Asks the person to confirm, then loads the page under the certificate warning on its certificate.
    public func visitDespiteCertificateWarning() {
        guard let certificateWarning, certificateWarning.allowsVisit else { return }
        controller?.webKitSessionDelegate?.confirmVisit(despite: certificateWarning, in: self)
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
        controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.title])
    }

    // MARK: - Observation

    private func setupNavigationStateObservers(for webView: WKWebView) {
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
            let applied = webView === primaryWebView && audible != nil
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

    // MARK: - Equality

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PageSession else { return false }
        return itemID == other.itemID
    }

    public override var hash: Int { itemID.hashValue }
}

private extension WKWebView {
    /// `_clearBackForwardCache`, private on both platforms.
    func nookClearBackForwardCache() -> Bool {
        let selector = NSSelectorFromString("_clearBackForwardCache")
        guard responds(to: selector) else { return false }
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method(for: selector), to: Call.self)(self, selector)
        return true
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
        resetNativeBoostCSS()
        nativeResourceHost = nil
        if media != PageMedia() { media = PageMedia() }
        if hasAudioContent { hasAudioContent = false }
        if hasPlayingAudio { hasPlayingAudio = false }
        if hasVideoContent { hasVideoContent = false }
        if hasPlayingVideo { hasPlayingVideo = false }
        hasPiPActive = false
        ended?.invalidate()
        navigationHasCommittedPage = false
        loadingState = .idle
        for completion in release?.completions ?? [] { completion(.ownerEnded) }
        // Reentrant completion callbacks cannot revive a request into the ending owner.
        controller?.cancelNativeSelection(for: self)
        nativePreparationWindow = nil
        cancelNativeCreation()
        nativeIsEnding = false
        if !isPrivate && !isDetached { controller?.nativeSyncAdmissionChanged() }
    }
}
