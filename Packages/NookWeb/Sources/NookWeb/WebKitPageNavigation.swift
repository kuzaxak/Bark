// Licensed under GPL-3.0. See LICENSE.
import Foundation
import WebKit

/// Adapts the session's existing view; never creates or owns another page.
@MainActor
final class WebKitPageNavigation: PageNavigation {
    let profileID: UUID?
    private weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var activeNavigation: WKNavigation?
    private var requestedNavigation: WKNavigation?
    private var stopped = false
    var onStateChanged: ((PageNavigationState) -> Void)?
    var onEvent: ((PageNavigationEvent) -> Void)?

    init(webView: WKWebView, profileID: UUID?) {
        self.webView = webView
        self.profileID = profileID
        observations = [
                webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.publish() }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.publish() }
                },
                webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.publish()
                    }
                },
        ]
    }

    var state: PageNavigationState {
        PageNavigationState(url: webView?.url, title: webView?.title,
                            isLoading: webView?.isLoading ?? false,
                            canGoBack: webView?.canGoBack ?? false,
                            canGoForward: webView?.canGoForward ?? false)
    }

    private func publish() {
        guard webView != nil else { return }
        onStateChanged?(state)
    }

    @discardableResult
    func report(_ event: PageNavigationEvent, navigation: WKNavigation? = nil) -> Bool {
        guard webView != nil else { return false }
        if case .started = event {
            if let requestedNavigation, let navigation,
               requestedNavigation !== navigation { return false }
            requestedNavigation = nil
            activeNavigation = navigation
            stopped = false
        } else {
            guard !stopped else { return false }
            if let navigation, let activeNavigation,
               navigation !== activeNavigation { return false }
        }
        onEvent?(event)
        return true
    }

    func load(_ url: URL) {
        guard let webView else { return }
        stopped = false
        activeNavigation = Self.load(url, in: webView)
        requestedNavigation = activeNavigation
    }

    @discardableResult
    static func load(_ url: URL, in webView: WKWebView) -> WKNavigation? {
        if url.isFileURL {
            return webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            return webView.load(request)
        }
    }

    func goBack() -> Bool {
        guard let webView else { return false }
        guard webView.canGoBack else { return false }
        stopped = false
        activeNavigation = webView.goBack()
        requestedNavigation = activeNavigation
        return true
    }

    func goForward() -> Bool {
        guard let webView, webView.canGoForward else { return false }
        stopped = false
        activeNavigation = webView.goForward()
        requestedNavigation = activeNavigation
        return true
    }

    func reload() -> Bool {
        guard let webView else { return false }
        guard webView.backForwardList.currentItem != nil else { return false }
        stopped = false
        activeNavigation = webView.reload()
        requestedNavigation = activeNavigation
        return activeNavigation != nil
    }

    static func goBack(in webView: WKWebView) -> Bool {
        guard webView.canGoBack else { return false }
        webView.goBack()
        return true
    }

    static func reload(_ webView: WKWebView) -> Bool {
        guard webView.backForwardList.currentItem != nil else { return false }
        return webView.reload() != nil
    }

    func stop() {
        stopped = true
        webView?.stopLoading()
        onEvent?(.cancelled(committedURL: webView?.backForwardList.currentItem?.url))
    }

    func invalidate() {
        stopped = true
        activeNavigation = nil
        requestedNavigation = nil
        onStateChanged = nil
        onEvent = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView = nil
    }
}
