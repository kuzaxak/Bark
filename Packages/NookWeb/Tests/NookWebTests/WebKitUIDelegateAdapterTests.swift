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
    @Test func retainsCloseAndPiPWithoutLegacyWindowGeometryOrSwipe() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Popup", isPrivate: true, controller: nil)
        let adapter = session.webKitDelegate
        #expect(adapter.responds(to: NSSelectorFromString("webViewDidClose:")))
        #expect(adapter.responds(to: NSSelectorFromString("_webViewFullscreenMayReturnToInline:")))
        #expect(!adapter.responds(to: NSSelectorFromString("_webView:getWindowFrameWithCompletionHandler:")))
        #expect(!adapter.responds(to: NSSelectorFromString("_webView:didNotHandleWheelEvent:")))
    }

    @Test func doesNotRegisterLegacyPrintOrPDFSaveSelectors() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "PDF", isPrivate: true, controller: nil)
        let adapter = session.webKitDelegate
        #expect(!adapter.responds(to: NSSelectorFromString(
            "_webView:printFrame:pdfFirstPageSize:completionHandler:")))
        #expect(!adapter.responds(to: NSSelectorFromString(
            "_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:")))
    }
    #endif
}
