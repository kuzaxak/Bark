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

    public init(url: URL? = nil, title: String? = nil, isLoading: Bool = false,
                canGoBack: Bool, canGoForward: Bool) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
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
    /// Ends commands and observations. The owning session releases the surface.
    func invalidate()
}
