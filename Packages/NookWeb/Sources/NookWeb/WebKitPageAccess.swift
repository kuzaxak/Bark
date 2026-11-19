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
}
