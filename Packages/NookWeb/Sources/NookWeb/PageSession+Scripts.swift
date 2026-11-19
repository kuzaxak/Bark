// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+Scripts.swift
//  Nook
//
//  Script message handlers and injected page scripts for a PageSession.
//

import SwiftUI
import WebKit

extension PageSession {
    /// Script message handler names this session registers on each of its web views.
    var messageHandlerNames: [String] {
        ["linkHover", "commandHover",
         "mediaStateChange_\(itemID.uuidString)", "backgroundColor_\(itemID.uuidString)",
         "historyStateDidChange", "nookShortcutDetect"]
    }

    /// Per-document observers. Each script guards against a second install in the same document.
    func injectPageObservers(into webView: WKWebView) {
        injectLinkHoverJavaScript(to: webView)
        injectPiPStateListener(to: webView)
        injectHistoryStateObserver(into: webView)
        injectShortcutDetection(to: webView)
    }

    // MARK: - JavaScript Injection
    func injectLinkHoverJavaScript(to webView: WKWebView) {
        let linkHoverScript = """
            (function() {
                if (window.__nookLinkHoverInstalled) return;
                window.__nookLinkHoverInstalled = true;
                let currentHoveredLink = null;
                let isCommandPressed = false;
                let lastCommandLink = null;

                function reportHover(href, commandPressed) {
                    const commandLink = commandPressed ? href : null;
                    if (href !== currentHoveredLink) {
                        currentHoveredLink = href;
                        window.webkit?.messageHandlers?.linkHover?.postMessage(href);
                    }
                    if (commandLink !== lastCommandLink) {
                        lastCommandLink = commandLink;
                        window.webkit?.messageHandlers?.commandHover?.postMessage(commandLink);
                    }
                    isCommandPressed = commandPressed;
                }
                function linkAt(target) {
                    return target?.closest?.('a[href]')?.href || null;
                }
                // Capture delegation handles dynamic links without scanning the DOM.
                document.addEventListener('mouseover', e => {
                    const link = e.composedPath().find(node => node.matches?.('a[href]'));
                    reportHover(link?.href || null, e.metaKey);
                }, {capture: true, passive: true});
                document.addEventListener('mouseout', e => {
                    reportHover(linkAt(e.relatedTarget), e.metaKey);
                }, {capture: true, passive: true});
                document.addEventListener('keydown', e => reportHover(currentHoveredLink, e.metaKey));
                document.addEventListener('keyup', e => reportHover(currentHoveredLink, e.metaKey));
                window.addEventListener('blur', () => reportHover(null, false));
            })();
            """

        webView.evaluateJavaScript(linkHoverScript) { result, error in
            if let error = error {
            }
        }
    }

    func injectHistoryStateObserver(into webView: WKWebView) {
        let historyScript = """
            (function() {
                if (window.__nookHistorySyncInstalled) { return; }
                window.__nookHistorySyncInstalled = true;

                function notify() {
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.historyStateDidChange) {
                            window.webkit.messageHandlers.historyStateDidChange.postMessage(window.location.href);
                        }
                    } catch (err) {
                        console.error('historyStateDidChange failed', err);
                    }
                }

                var originalPushState = history.pushState;
                history.pushState = function() {
                    var result = originalPushState.apply(this, arguments);
                    setTimeout(notify, 0);
                    return result;
                };

                var originalReplaceState = history.replaceState;
                history.replaceState = function() {
                    var result = originalReplaceState.apply(this, arguments);
                    setTimeout(notify, 0);
                    return result;
                };

                window.addEventListener('popstate', notify);
                window.addEventListener('hashchange', notify);
                document.addEventListener('yt-navigate-finish', notify);

                notify();
            })();
            """

        webView.evaluateJavaScript(historyScript) { _, error in
            if let error = error {
            }
        }
    }

    /// The PiP state listener and its handler live here: the state decides unloading and auto
    /// PiP, so a page must not be able to post it.
    static let pipStateWorld = WKContentWorld.world(name: "NookPiPState")

    func injectPiPStateListener(to webView: WKWebView) {
        // Capture on the document sees every video, including ones added later, and reports the
        // page's state rather than one video's, so leaving on one cannot clear another.
        let pipStateScript = """
            (function() {
                if (window.__nookPiPState) return;
                window.__nookPiPState = true;
                function report() {
                    const active = !!document.pictureInPictureElement || [...document.querySelectorAll('video')]
                        .some(v => v.webkitPresentationMode === 'picture-in-picture');
                    window.webkit?.messageHandlers?.pipStateChange?.postMessage({ active: active });
                }
                for (const type of ['webkitpresentationmodechanged', 'enterpictureinpicture', 'leavepictureinpicture']) {
                    document.addEventListener(type, report, true);
                }
                // A new document is never in PiP; this clears a state the last one left behind.
                report();
            })();
            """

        webView.evaluateJavaScript(pipStateScript, in: nil, in: Self.pipStateWorld)
    }
    
    func injectShortcutDetection(to webView: WKWebView) {
        controller?.webKitSessionDelegate?.configureShortcutDetection(in: webView)
    }
}

extension WebKitPageDelegateAdapter: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let session, let view = message.webView,
              view.configuration.userContentController === controller,
              session.acceptsNavigationCallbacks(from: view) else { return }
        session.receiveScriptMessage(message, from: view)
    }
}

extension PageSession {
    fileprivate func receiveScriptMessage(_ message: WKScriptMessage, from view: WKWebView) {
        // These handlers live in the page world, so any frame can post to them. Every script
        // that feeds them runs in the main frame only; media state is the exception, since a
        // player can sit in a subframe.
        guard message.frameInfo.isMainFrame || message.name.hasPrefix("mediaStateChange_") else { return }

        switch message.name {
        case "linkHover":
            let href = message.body as? String
            self.onLinkHover?(href)

        case "commandHover":
            let href = message.body as? String
            self.onCommandHover?(href)

        case Self.translateHandlerName where message.world == Self.translateWorld:
            if let body = message.body as? [String: Any], let nodes = body["nodes"] as? [[String: Any]],
               case .terminated? = translationFeed?.yield(nodes) {
                translationBacklog += nodes
            }

        case "pipStateChange":
            if let dict = message.body as? [String: Any], let active = dict["active"] as? Bool {
                self.hasPiPActive = active
            }

        case let name where name.hasPrefix("mediaStateChange_"):
            if let body = message.body as? [String: Any] {
                receiveMediaReport(body, from: message.frameInfo)
            }

        case let name where name.hasPrefix("backgroundColor_"):
            if let dict = message.body as? [String: String],
                let colorHex = dict["backgroundColor"]
            {
                self.pageBackgroundColor = PlatformColor.fromHex(colorHex)
                if let webView = self.primaryWebView, let color = PlatformColor.fromHex(colorHex) {
                    webView.underPageBackgroundColor = color
                    // Update sampled domain after successful extraction
                    if let currentURL = webView.url,
                       let currentDomain = self.extractDomain(from: currentURL) {
                        self.lastSampledDomain = currentDomain
                    }
                }
            }

        case "historyStateDidChange":
            // The message is only a signal. The address comes from WebKit, never from the body:
            // a page could otherwise put any URL, lock icon included, in the URL bar. WebKit
            // has already updated webView.url for a same-document navigation by the time
            // the message arrives.
            if let url = view.url {
                if self.url.absoluteString != url.absoluteString {
                    self.url = url
                    // NOTE: Do NOT call syncTabAcrossWindows here. SPA navigations
                    // (pushState/replaceState/popstate) happen inside the webview — the
                    // content is already at the correct state. Calling syncTab would
                    // webView.load() every view of this item whose URL differs, a full
                    // page reload that breaks SPA
                    // back/forward (e.g., Facebook lightbox close via browser back).

                    // Fetch updated title after SPA navigation
                    view.evaluateJavaScript("document.title") { [weak self, weak view] result, _ in
                        guard let self, let view, self.acceptsNavigationCallbacks(from: view),
                              self.url == url, view.url == url,
                              let title = result as? String, !title.isEmpty else { return }
                        self.updateTitle(title)
                    }

                    // The store coalesces writes, so SPA URL changes report directly.
                    controller?.pageCommitted(itemID: itemID, url: url)
                    controller?.webKitTabEvents?.tabPropertiesChanged(self, properties: [.URL])
                    schedulePageTextCapture(in: view, sameDocument: true)
                }
            }

        case "nookShortcutDetect":
            handleShortcutDetection(message: message)

        default:
            break
        }
    }
    
    func handleShortcutDetection(message: WKScriptMessage) {
        // Handle detected shortcuts from JS injection
        guard let shortcutsString = message.body as? String else { return }
        
        // Use the frame's webView URL for correct attribution, fallback to primaryWebView
        let currentURL = message.frameInfo.webView?.url?.absoluteString ?? primaryWebView?.url?.absoluteString
        guard let url = currentURL else { return }
        
        // Parse the comma-separated shortcuts
        let shortcuts = Set(shortcutsString.split(separator: ",").map { String($0) })
        
        // Update the detector with detected shortcuts for this URL
        controller?.webKitSessionDelegate?.updateDetectedShortcuts(for: url, shortcuts: shortcuts)
    }
}
