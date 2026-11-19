// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookBlocker

/// Binding seed and current capabilities. URL/loading lifecycle comes through
/// events after binding; snapshots never synthesize commits or history visits.
public struct PageNavigationState: Equatable {
    public var url: URL?
    public var title: String?
    public var isLoading: Bool
    /// A fraction supplied by the bound engine, or nil when progress is unknown.
    public var loadProgress: Double?
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// nil means this engine has not supplied authoritative audio state.
    public var isAudioMuted: Bool?
    public var isAudible: Bool?
    /// Separate native states; nil means the adapter has not supplied a snapshot.
    public var hasVideoPictureInPicture: Bool?
    public var hasDocumentPictureInPicture: Bool?
    /// Native controllable media-session state/metadata, not a page activity census.
    public var media: PageMedia?

    public init(url: URL? = nil, title: String? = nil, isLoading: Bool = false,
                canGoBack: Bool, canGoForward: Bool, isAudioMuted: Bool? = nil, isAudible: Bool? = nil,
                hasVideoPictureInPicture: Bool? = nil, hasDocumentPictureInPicture: Bool? = nil, media: PageMedia? = nil,
                loadProgress: Double? = nil) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.loadProgress = loadProgress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isAudioMuted = isAudioMuted
        self.isAudible = isAudible
        self.hasVideoPictureInPicture = hasVideoPictureInPicture
        self.hasDocumentPictureInPicture = hasDocumentPictureInPicture
        self.media = media
    }
}

/// A resource close completes only with an observed terminal outcome.
public enum PageCloseOutcome: Equatable, Sendable {
    case closed
    case cancelled
    /// The logical native owner ended; saved tab metadata must survive.
    case ownerEnded
}

/// Events from one engine page; media updates never imply navigation.
public enum PageNavigationEvent {
    case started(URL?)
    case committed(URL?, sameDocument: Bool = false)
    /// A missing title permits asynchronous title resolution. Supply the final
    /// title once to record the visit; repeated capability updates never do so.
    case finished(URL?, title: String?, isReload: Bool)
    case failed(Error, provisional: Bool, committedURL: URL? = nil)
    case cancelled(committedURL: URL?)
    case titleChanged(String)
    /// Explicit link action; the source page has not navigated.
    case peekRequested(URL)
    /// Proven native-filter navigation denial, distinct from extension errors.
    case nativeBlocked(URL)
    /// User action from the native block notice; leaves policy to this page.
    case continueNativeBlock(URL)
    /// Independent of URL/loading: nil means controllable media is unavailable.
    case mediaChanged(PageMedia?)
    /// Actual engine-admitted deletion, never a close request.
    case closed
    /// Owner teardown, distinct from an individual tab deletion.
    case ownerEnded
}

/// Fixed top-document translation operations; no arbitrary script or native bindings.
public struct PageTranslationNode: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}
public struct PageTranslationResult: Codable, Equatable, Sendable {
    public var text: String
    public var lang: String
    public var nodes: [PageTranslationNode]
    public init(text: String = "", lang: String = "", nodes: [PageTranslationNode] = []) {
        self.text = text; self.lang = lang; self.nodes = nodes
    }
}
public enum PageTranslationCommand: Sendable {
    case sample, start, apply([PageTranslationNode]), restore
}

/// A snapshot identity, resolved again against the live controller on selection.
public struct PageHistoryEntry: Codable, Equatable, Sendable {
    public let id: Int32
    public let title: String
    public let url: URL
    public init(id: Int32, title: String, url: URL) {
        self.id = id; self.title = title; self.url = url
    }
}

/// Commands for one existing live page. The profile identity is captured when
/// the page is attached, never inferred from the currently selected window.
@MainActor
public protocol PageNavigation: AnyObject {
    var profileID: UUID? { get }
    var state: PageNavigationState { get }
    var onStateChanged: ((PageNavigationState) -> Void)? { get set }
    /// Deliver on the main actor. Terminal events must belong to the current
    /// navigation; suppress superseded/cancelled callbacks after stop or reload.
    var onEvent: ((PageNavigationEvent) -> Void)? { get set }
    func load(_ url: URL)
    /// Uses the effective native provider, including POST data. Never a URL-only fallback.
    @discardableResult func search(_ query: String, kagiSessionToken: String?) -> Bool
    @discardableResult func goBack() -> Bool
    @discardableResult func goForward() -> Bool
    /// Nearest first, excluding the current entry. Reading never navigates.
    func historyEntries(forward: Bool) -> [PageHistoryEntry]
    /// Resolves the stable entry ID live; pruned entries refuse.
    @discardableResult func goToHistoryEntry(_ id: Int32) -> Bool
    @discardableResult func reload() -> Bool
    /// Drop cached history documents only. Never selects, reloads or creates a page.
    /// Returns dispatch acceptance, not an entry count or a memory measurement.
    @discardableResult func clearBackForwardCache() -> Bool
    func stop()
    @discardableResult func applyBlockingPolicy(_ policy: ContentBlockerManager.NetworkPagePolicy) -> Bool
    /// Return command acceptance. Actual mute state arrives through snapshots;
    /// an unsupported engine refuses without optimistic model changes.
    @discardableResult func setAudioMuted(_ muted: Bool) -> Bool
    /// Request dispatch only; active state must come from the engine.
    @discardableResult func requestPictureInPicture() -> Bool
    @discardableResult func setPlaybackPaused(_ paused: Bool) -> Bool
    @discardableResult func skipTrack(forward: Bool) -> Bool
    /// Requests a bounded PNG thumbnail of an already-presented page. False
    /// means unsupported/refused and no completion; never loads or shows a page.
    /// Accepted requests complete once, with nil on cancellation.
    @discardableResult func captureThumbnail(completion: @escaping @MainActor (Data?) -> Void) -> Bool
    /// Fixed, bounded document text for opt-in history indexing. Never creates,
    /// selects or reloads a page. nil means unavailable, busy or cancelled.
    func capturePageText() async -> (title: String, body: String)?
    var supportsTranslation: Bool { get }
    /// Mutation batches for the current translation; nil aborts and restores.
    var onTranslationNodes: (([PageTranslationNode]?) -> Void)? { get set }
    /// False means unsupported/refused with no callback. Accepted calls finish once.
    @discardableResult func translate(_ command: PageTranslationCommand,
        completion: @escaping @MainActor (PageTranslationResult?) -> Void) -> Bool
    var supportsElementPicker: Bool { get }
    /// Fixed isolated picker for this live document. Cancellation removes its DOM handlers.
    func pickElement() async -> String?
    func cancelElementPicker()
    var supportsUserCSS: Bool { get }
    /// CSS only, for the committed top document. Empty removes the owned sheet.
    /// Accepted requests complete once; false means unsupported/refused, no callback.
    @discardableResult func setUserCSS(_ css: String, for committedURL: URL,
        completion: @escaping @MainActor (Bool) -> Void) -> Bool
    /// Ends commands and observations. The owning session releases the surface.
    func invalidate()
}

extension PageNavigation {
    public func historyEntries(forward: Bool) -> [PageHistoryEntry] { [] }
    public func goToHistoryEntry(_ id: Int32) -> Bool { false }
    public func search(_ query: String, kagiSessionToken: String?) -> Bool { false }
    public func applyBlockingPolicy(_ policy: ContentBlockerManager.NetworkPagePolicy) -> Bool { false }
    public func clearBackForwardCache() -> Bool { false }
    public var supportsTranslation: Bool { false }
    public var onTranslationNodes: (([PageTranslationNode]?) -> Void)? { get { nil } set {} }
    public func translate(_ command: PageTranslationCommand,
        completion: @escaping @MainActor (PageTranslationResult?) -> Void) -> Bool { false }
    public var supportsElementPicker: Bool { false }
    public func pickElement() async -> String? { nil }
    public func cancelElementPicker() {}
    public var supportsUserCSS: Bool { false }
    public func setUserCSS(_ css: String, for committedURL: URL,
        completion: @escaping @MainActor (Bool) -> Void) -> Bool { false }
    public func setAudioMuted(_ muted: Bool) -> Bool { false }
    public func requestPictureInPicture() -> Bool { false }
    public func setPlaybackPaused(_ paused: Bool) -> Bool { false }
    public func skipTrack(forward: Bool) -> Bool { false }
    public func captureThumbnail(completion: @escaping @MainActor (Data?) -> Void) -> Bool { false }
    public func capturePageText() async -> (title: String, body: String)? { nil }
}
