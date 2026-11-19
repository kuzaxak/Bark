// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+UIDelegate.swift
//  Nook
//
//  JavaScript panels, file upload and full screen for a PageSession.
//

import SwiftUI
import WebKit
import NookBlocker
import NookSettings
import NookTweaks
extension PageSession {
    // MARK: - Peek Detection

    /// A click on a link the page opens in a new tab (target=_blank), or any link clicked with
    /// Shift, shows in Peek when its setting is on, as in Arc. Command and the middle button
    /// still open a background tab.
    func peeksNewTabLink(_ action: WKNavigationAction) -> Bool {
        guard !isAgentPage, action.navigationType == .linkActivated,
              !action.modifierFlags.contains(.command), !action.isMiddleClick,
              let settings = controller?.settings else { return false }
        return action.modifierFlags.contains(.shift) ? settings.peekOnShiftClick : settings.openNewTabLinksInPeek
    }

    /// Option always peeks. Otherwise only a favorite or pinned tab peeks, for a link to another
    /// site, so the page it keeps in the sidebar stays put; a regular tab opens a new tab.
    func shouldRedirectToPeek(url: URL) -> Bool {
        if isAgentPage { return false }
        if isOptionKeyDown { return true }
        guard controller?.settings.peekLinksToOtherSites == true,
              controller?.isSynced(itemID) == true, let from = self.url.host, let to = Self.destinationHost(of: url)
        else { return false }
        return !Self.isSameSite(from, to)
    }

    /// Where a link really goes. A site's own redirector (l.facebook.com/l.php?u=,
    /// youtube.com/redirect?q=) carries the destination in its query; judge the link by that.
    /// ponytail: the u, q and url parameters only; add a redirector's own name if one is missed.
    static func destinationHost(of url: URL) -> String? {
        let carried = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { ["u", "q", "url"].contains($0.name) }?.value
            .flatMap(URL.init(string:))
        guard let carried, carried.scheme == "http" || carried.scheme == "https" else { return url.host }
        return carried.host
    }

    // No public suffix list: hosts match when one equals or contains the other, so a page on a
    // bare shared suffix (github.io) would match its subdomains, and sibling subdomains
    // (mail.google.com, docs.google.com) count as different sites. Use a PSL if that proves wrong.
    public static func isSameSite(_ lhs: String?, _ rhs: String?) -> Bool {
        func bare(_ host: String?) -> String {
            let host = host?.lowercased() ?? ""
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let a = bare(lhs), b = bare(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasSuffix(".\(b)") || b.hasSuffix(".\(a)")
    }
}

// MARK: - WKUIDelegate
extension WebKitPageDelegateAdapter: WKUIDelegate {
    func uiOwner(of view: WKWebView) -> PageSession? {
        guard let session, view.uiDelegate === self,
              session.acceptsNavigationCallbacks(from: view) else { return nil }
        return session
    }

    /// Counts a dialog. From the second one since the last main-frame commit the presenter offers
    /// to stop them, so `while(1) alert()` cannot hold the window.
    private func nextDialogSuppressor(for session: PageSession) -> (() -> Void)? {
        session.jsDialogCount += 1
        guard session.jsDialogCount > 1 else { return nil }
        return { [weak session] in session?.jsDialogsSuppressed = true }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        // An agent page's dialogs answer at once: a sheet would cover the person's window and
        // hold the agent's next call until it times out.
        guard let session = uiOwner(of: webView), !session.jsDialogsSuppressed, !session.isAgentPage,
              let alerts = session.controller?.webKitAlertPresenter else { return completionHandler() }
        alerts.presentAlert(
            message: message, host: frame.securityOrigin.host, over: webView,
            onSuppress: nextDialogSuppressor(for: session), completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let session = uiOwner(of: webView), !session.jsDialogsSuppressed, !session.isAgentPage,
              let alerts = session.controller?.webKitAlertPresenter else { return completionHandler(false) }
        alerts.presentConfirm(
            message: message, host: frame.securityOrigin.host, over: webView,
            onSuppress: nextDialogSuppressor(for: session), completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard let session = uiOwner(of: webView), !session.jsDialogsSuppressed, !session.isAgentPage,
              let alerts = session.controller?.webKitAlertPresenter else { return completionHandler(nil) }
        alerts.presentPrompt(
            prompt: prompt, defaultText: defaultText, host: frame.securityOrigin.host, over: webView,
            onSuppress: nextDialogSuppressor(for: session), completion: completionHandler)
    }

    /// A popup that finished (a sign-in window) closes itself; only detached pages act on it.
    func webViewDidClose(_ webView: WKWebView) {
        uiOwner(of: webView)?.onClose?()
    }

    // MARK: - File Upload Support
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {

        guard let session = uiOwner(of: webView), !session.isAgentPage, let alerts = session.controller?.webKitAlertPresenter else { return completionHandler(nil) }
        alerts.presentOpenPanel(
            allowsMultipleSelection: parameters.allowsMultipleSelection,
            allowsDirectories: parameters.allowsDirectories,
            over: webView,
            completion: completionHandler)
    }

    // MARK: - Full-Screen Video Support
    func webView(
        _ webView: WKWebView,
        enterFullScreenForVideoWith completionHandler: @escaping (Bool, Error?) -> Void
    ) {

        guard let session = uiOwner(of: webView), !session.isAgentPage, session.controller?.webKitSessionDelegate?.toggleFullScreen(for: webView) == true else {
            completionHandler(
                false,
                NSError(
                    domain: "PageSession", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No window available for full-screen"]))
            return
        }
        // Call completion handler immediately - WebKit will handle the actual full-screen transition
        completionHandler(true, nil)
    }

    func webView(
        _ webView: WKWebView,
        exitFullScreenWith completionHandler: @escaping (Bool, Error?) -> Void
    ) {

        guard uiOwner(of: webView)?.controller?.webKitSessionDelegate?.toggleFullScreen(for: webView) == true else {
            completionHandler(
                false,
                NSError(
                    domain: "PageSession", code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No window available for exiting full-screen"
                    ]))
            return
        }
        // Call completion handler immediately - WebKit will handle the actual full-screen transition
        completionHandler(true, nil)
    }

    // MARK: - Media Capture Authorization

    /// Handle requests for camera/microphone capture authorization
    func webView(
        _ webView: WKWebView,
        requestMediaCaptureAuthorization type: WKMediaCaptureType,
        for origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {

        // A stored answer for this host short-circuits the prompt; otherwise WebKit asks, and a
        // page never gets capture on its own say-so.
        let needed: [SitePermission]
        switch type {
        case .camera: needed = [.camera]
        case .microphone: needed = [.microphone]
        case .cameraAndMicrophone: needed = [.camera, .microphone]
        @unknown default: needed = [.camera, .microphone]
        }
        guard let session = uiOwner(of: webView) else {
            decisionHandler(.deny)
            return
        }
        guard let settings = session.controller?.settings else {
            decisionHandler(.prompt)
            return
        }
        let policies = needed.map { settings.permission($0, for: origin.host) }
        // A combined request needs every part allowed, and one block denies the whole thing.
        // No capture prompt for an agent page: nobody may be watching it.
        if policies.contains(.block) || (session.isAgentPage && !policies.allSatisfy({ $0 == .allow })) {
            decisionHandler(.deny)
        } else if policies.allSatisfy({ $0 == .allow }) {
            decisionHandler(.grant)
        } else {
            decisionHandler(.prompt)
        }
    }
}

private extension WKNavigationAction {
    var isMiddleClick: Bool {
        buttonNumber == 2
    }
}
