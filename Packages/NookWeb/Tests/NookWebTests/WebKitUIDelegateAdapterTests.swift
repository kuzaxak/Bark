// Licensed under GPL-3.0. See LICENSE.

import Foundation
import Testing
import WebKit
@testable import NookWeb

@MainActor
struct WebKitUIDelegateAdapterTests {
    @Test func closeOnlyForTheInstalledWebKitView() throws {
        let session = PageSession(itemID: UUID(), url: try #require(URL(string: "about:blank")),
                                  title: "Popup", isPrivate: true, controller: nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        session.installPopupWebView(view)
        defer { session.unload() }
        let adapter = session.webKitDelegate
        #expect(view.uiDelegate === adapter)
        var closes = 0
        session.onClose = { closes += 1 }

        let foreignView = WKWebView(frame: .zero, configuration: configuration)
        foreignView.uiDelegate = adapter
        adapter.webViewDidClose(foreignView)
        #expect(closes == 0)

        adapter.webViewDidClose(view)
        #expect(closes == 1)

        view.uiDelegate = nil
        adapter.webViewDidClose(view)
        #expect(closes == 1)
    }

    #if os(macOS)
    @Test func preservesWebKitPrivateUISelectorsAndUnownedCompletion() throws {
        let session = PageSession(itemID: UUID(), url: try #require(URL(string: "about:blank")),
                                  title: "Popup", isPrivate: true, controller: nil)
        let adapter = session.webKitDelegate
        for selector in [
            "webViewDidClose:",
            "_webView:getWindowFrameWithCompletionHandler:",
            "_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:",
            "_webViewFullscreenMayReturnToInline:",
            "_webView:didNotHandleWheelEvent:",
            "_webView:printFrame:pdfFirstPageSize:completionHandler:",
        ] {
            #expect(adapter.responds(to: NSSelectorFromString(selector)), "Missing \(selector)")
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 240),
                             configuration: configuration)
        var sizes: [CGRect] = []
        adapter.webView(view, getWindowFrameWithCompletionHandler: { sizes.append($0) })
        #expect(sizes == [view.bounds])

        var printCompletions = 0
        adapter.webView(view, printFrame: NSObject(), pdfFirstPageSize: .zero) { printCompletions += 1 }
        #expect(printCompletions == 1)
    }
    #endif
}
