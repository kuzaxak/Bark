// Licensed under GPL-3.0. See LICENSE.

#if os(macOS)
import AppKit
import WebKit

extension WebKitPageDelegateAdapter {
    /// The native WebKit PDF toolbar's Save action stays in its original view and profile.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(_ webView: WKWebView, saveDataToFile data: Data, suggestedFilename: String, mimeType: String, originatingURL: URL) {
        uiOwner(of: webView)?.controller?.webKitSessionDelegate?.saveFile(data, suggestedFilename: suggestedFilename, originalURL: originatingURL, from: webView)
    }
}
#endif
