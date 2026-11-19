// Licensed under GPL-3.0. See LICENSE.
import Testing
import WebKit
@testable import NookWeb

@MainActor
struct WebKitScriptMessageAdapterTests {
    @Test func scriptMessagesFollowCurrentEngineOwnership() async throws {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        session.installPopupWebView(view)
        defer { session.detachedProfile = nil; session.unload() }

        var received: [String] = []
        session.onLinkHover = { if let value = $0 { received.append(value) } }
        let controller = view.configuration.userContentController
        controller.addScriptMessageHandler(Fence(), contentWorld: .page, name: "fence")
        defer { controller.removeScriptMessageHandler(forName: "fence", contentWorld: .page) }

        func post(_ text: String) async throws {
            _ = try await view.callAsyncJavaScript("""
                window.webkit.messageHandlers.linkHover.postMessage(value);
                return await window.webkit.messageHandlers.fence.postMessage(null);
                """, arguments: ["value": text], in: nil, contentWorld: .page)
        }
        try await post("owned")
        session.detachedProfile = Profile(id: UUID(), engine: .chromium)
        try await post("retired")
        #expect(received == ["owned"])
    }

    /// A reply behind the hover message confirms WebKit has dispatched both callbacks.
    private final class Fence: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            replyHandler(true, nil)
        }
    }
}
