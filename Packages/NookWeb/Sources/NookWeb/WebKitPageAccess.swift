// Licensed under GPL-3.0. See LICENSE.
import WebKit

/// Exposes an already created WebKit view to callers of WebKit-specific APIs.
@MainActor
public enum WebKitPageAccess {
    /// Returns the primary view without allocating a view or website data store.
    public static func existingView(for session: PageSession) -> WKWebView? {
        guard !session.usesNativePageHost, session.navigation is WebKitPageNavigation else { return nil }
        return session.primaryWebView
    }

    /// Returns the primary view only while it is assigned to a window.
    public static func assignedView(for session: PageSession) -> WKWebView? {
        guard session.primaryWindowId != nil else { return nil }
        return existingView(for: session)
    }

    /// Finds the owner of an existing primary or cloned WebKit view.
    public static func session(for view: WKWebView, in tabs: TabsController) -> PageSession? {
        tabs.sessions.first { $0.acceptsNavigationCallbacks(from: view) }
    }

    /// Returns the existing WebContent process ID when this WebKit supports it.
    public static func processID(for session: PageSession) -> Int32? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard let view = existingView(for: session), view.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        let pid = unsafeBitCast(view.method(for: selector), to: Getter.self)(view, selector)
        return pid > 0 ? pid : nil
    }
}
