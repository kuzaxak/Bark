// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// Binding seed and current capabilities. URL/loading lifecycle comes through
/// events after binding; snapshots never synthesize commits or history visits.
public struct PageNavigationState: Equatable {
    public var url: URL?
    public var title: String?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// nil means this engine has not supplied authoritative audio state.
    public var isAudioMuted: Bool?
    public var isAudible: Bool?

    public init(url: URL? = nil, title: String? = nil, isLoading: Bool = false,
                canGoBack: Bool, canGoForward: Bool, isAudioMuted: Bool? = nil, isAudible: Bool? = nil) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isAudioMuted = isAudioMuted
        self.isAudible = isAudible
    }
}

/// A resource close completes only with an observed terminal outcome.
public enum PageCloseOutcome: Equatable, Sendable {
    case closed
    case cancelled
    /// The logical native owner ended; saved tab metadata must survive.
    case ownerEnded
}

/// Lifecycle from the engine's document, independent of its native surface.
public enum PageNavigationEvent {
    case started(URL?)
    case committed(URL?, sameDocument: Bool = false)
    /// A missing title permits asynchronous title resolution. Supply the final
    /// title once to record the visit; repeated capability updates never do so.
    case finished(URL?, title: String?, isReload: Bool)
    case failed(Error, provisional: Bool, committedURL: URL? = nil)
    case cancelled(committedURL: URL?)
    case titleChanged(String)
    /// Actual engine-admitted deletion, never a close request.
    case closed
    /// Owner teardown, distinct from an individual tab deletion.
    case ownerEnded
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
    @discardableResult func goBack() -> Bool
    @discardableResult func goForward() -> Bool
    @discardableResult func reload() -> Bool
    func stop()
    /// Return command acceptance. Actual mute state arrives through snapshots;
    /// an unsupported engine refuses without optimistic model changes.
    @discardableResult func setAudioMuted(_ muted: Bool) -> Bool
    /// Ends commands and observations. The owning session releases the surface.
    func invalidate()
}

extension PageNavigation {
    public func setAudioMuted(_ muted: Bool) -> Bool { false }
}
