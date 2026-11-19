// Licensed under GPL-3.0. See LICENSE.
import Foundation
import WebKit

/// Exposes WebKit's delegate selectors while the model owns page state.
extension WebKitPageDelegateAdapter: WKNavigationDelegate {
    func navigationOwner(of view: WKWebView) -> PageSession? {
        guard let session, view.navigationDelegate === self,
              session.acceptsNavigationCallbacks(from: view) else { return nil }
        return session
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationOwner(of: webView)?.webView(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationOwner(of: webView)?.webView(webView, didCommit: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationOwner(of: webView)?.webView(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationOwner(of: webView)?.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationOwner(of: webView)?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationOwner(of: webView)?.webViewWebContentProcessDidTerminate(webView)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let session = navigationOwner(of: webView) else { completionHandler(.performDefaultHandling, nil); return }
        session.webView(webView, didReceive: challenge, completionHandler: completionHandler)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let session = navigationOwner(of: webView) else { decisionHandler(.cancel, preferences); return }
        session.webView(webView, decidePolicyFor: navigationAction, preferences: preferences,
                        decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let session = navigationOwner(of: webView) else { decisionHandler(.cancel); return }
        session.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let session = navigationOwner(of: webView) else { decisionHandler(.cancel); return }
        session.webView(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        navigationOwner(of: webView)?.webView(webView, navigationAction: navigationAction, didBecome: download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        navigationOwner(of: webView)?.webView(webView, navigationResponse: navigationResponse, didBecome: download)
    }

    /// WebKit's optional compiled content rule list action notification.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func contentRuleAction(_ webView: WKWebView, identifier _: String, performedAction action: NSObject, url: URL) {
        navigationOwner(of: webView)?.recordWebKitContentRuleAction(action, url: url)
    }
}
