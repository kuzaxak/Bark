// Licensed under GPL-3.0. See LICENSE.

import Combine
import WebKit

/// Optional host operations for sessions backed by a WKWebView.
@MainActor
public protocol WebKitPageSessionDelegate: PageSessionDelegate {
    /// Fires when a session waiting for a website data store can build its view.
    var currentProfilePublisher: AnyPublisher<Profile?, Never> { get }

    /// Keeps WebKit clones of the same page on the same URL.
    func navigateAcrossWindows(_ itemID: UUID, to url: URL)

    // MARK: Downloads and panels

    func addDownload(_ download: WKDownload, originalURL: URL, suggestedFilename: String)
    /// Enters or leaves full screen for the window showing `webView`. Returns false when
    /// `webView` has no window, so the caller can fail its completion handler.
    func toggleFullScreen(for webView: WKWebView) -> Bool

    // MARK: Sign-in

    func handleAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        for session: PageSession,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool

    // MARK: Certificates

    /// The certificates the person chose to visit sites with although they failed the check.
    var certificateExceptions: CertificateExceptions { get }
    /// Asks the person before visiting the page under `warning` anyway; on yes, remembers its
    /// certificate for that host and port and loads the page again.
    func confirmVisit(despite warning: CertificateWarning, in session: PageSession)

    // MARK: Per-page chrome

    func loadZoom(for itemID: UUID)
    func requestPictureInPicture(for session: PageSession, webView: WKWebView?)

    // MARK: Website keyboard shortcuts

    func configureShortcutDetection(in webView: WKWebView)
    func shortcutDetectorDidNavigate(to url: URL)
    func updateDetectedShortcuts(for url: String, shortcuts: Set<String>)

    // MARK: Chrome Web Store

    /// Installs the "Add to Nook" handler and script on a store page. Returns the handler to
    /// retain for the life of the page, or nil when the URL is not a store page.
    func installWebStoreScript(in webView: WKWebView) -> AnyObject?
    func removeWebStoreHandler(from controller: WKUserContentController)
}
