// Licensed under GPL-3.0. See LICENSE.
import Testing
import WebKit
@testable import NookWeb

/// The Quit dialog draws in a browser window. It must find one whenever one is open, including
/// right after launch, before any window has become active.
@MainActor
struct DialogWindowTests {
    final class Handle: WindowHandle {
        var frameString: String? { nil }
        func applyFrame(_ rectString: String) {}
        func bringToFront() {}
    }

    @Test func anOpenWindowHostsTheDialogBeforeAnyIsActive() {
        let registry = WindowRegistry()
        #expect(registry.dialogWindow == nil, "no window open: nothing to draw in")
        let handle = Handle()
        let opened = BrowserWindowState()
        opened.windowHandle = handle
        registry.register(opened)
        #expect(registry.activeWindow == nil)
        #expect(registry.dialogWindow === opened, "a window that has not become active yet still hosts the dialog")
    }

    @Test func theActiveWindowComesFirst() {
        let registry = WindowRegistry()
        let handles = [Handle(), Handle()]
        let first = BrowserWindowState(), second = BrowserWindowState()
        first.windowHandle = handles[0]
        second.windowHandle = handles[1]
        registry.register(first)
        registry.register(second)
        registry.setActive(second)
        #expect(registry.dialogWindow === second)
        registry.setActive(first)
        #expect(registry.dialogWindow === first)
    }

    @Test func aWindowWithoutItsPlatformWindowHostsNothing() {
        let registry = WindowRegistry()
        registry.register(BrowserWindowState())
        #expect(registry.dialogWindow == nil, "a registered state whose window is gone or not made yet cannot show it")
    }
}

@MainActor
struct WebKitPagePromptTests {
    @Test func chromiumDoesNotInstallAWebKitPromptPresenter() throws {
        let host = try Host(engine: .chromium)
        let prompts = RecordingWebKitPrompts()
        host.tabs.webKitAlertPresenter = prompts
        #expect(host.tabs.webKitAlertPresenter == nil)
    }

    @Test func legacyWebKitRoutesAConfirmAndDefaultsToCancellationWithoutPresenter() async throws {
        let host = try Host()
        let prompts = RecordingWebKitPrompts()
        host.tabs.webKitAlertPresenter = prompts
        let url = URL(string: "https://fixture.test/page")!
        let session = PageSession(itemID: UUID(), url: url, title: "Prompt fixture", isPrivate: true,
                                  controller: host.tabs)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        session.installPopupWebView(view)
        defer { session.unload() }

        let loaded = LoadObserver()
        view.navigationDelegate = loaded
        view.loadHTMLString("<title>Prompt fixture</title>", baseURL: url)
        for _ in 0..<200 where !loaded.finished {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(loaded.finished)

        let accepted = try await view.evaluateJavaScript("window.confirm('Continue?')") as? Bool
        #expect(accepted == true)
        #expect(prompts.confirms.count == 1)
        #expect(prompts.confirms.first?.host == "fixture.test")
        #expect(prompts.confirms.first?.view === view)

        host.tabs.webKitAlertPresenter = nil
        let refused = try await view.evaluateJavaScript("window.confirm('Continue?')") as? Bool
        #expect(refused == false && prompts.confirms.count == 1)
    }

    private final class LoadObserver: NSObject, WKNavigationDelegate {
        var finished = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }

    private final class RecordingWebKitPrompts: WebKitAlertPresenter {
        var confirms: [(host: String, view: WKWebView)] = []

        func presentAlert(message: String, host: String, over webView: WKWebView,
                          onSuppress: (() -> Void)?, completion: @escaping () -> Void) {
            completion()
        }

        func presentConfirm(message: String, host: String, over webView: WKWebView,
                            onSuppress: (() -> Void)?, completion: @escaping (Bool) -> Void) {
            confirms.append((host, webView))
            completion(true)
        }

        func presentPrompt(prompt: String, defaultText: String?, host: String, over webView: WKWebView,
                           onSuppress: (() -> Void)?, completion: @escaping (String?) -> Void) {
            completion(nil)
        }

        func presentOpenPanel(allowsMultipleSelection: Bool, allowsDirectories: Bool, over webView: WKWebView,
                              completion: @escaping ([URL]?) -> Void) {
            completion(nil)
        }
    }
}
