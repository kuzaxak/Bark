// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// Retained by a WebKit page and its script handlers. A view can outlive the
/// page that installed it, so callbacks resolve the session weakly.
@MainActor
final class WebKitPageDelegateAdapter: NSObject {
    private(set) weak var session: PageSession?

    init(session: PageSession) {
        self.session = session
    }
}
