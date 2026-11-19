// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+PiP+macOS.swift
//  NookWeb
//
//  The system picture-in-picture window's return button. WebKit puts the video back into its
//  page on its own; without this the page could be a hidden tab in a background window.
//

#if os(macOS)
import AppKit
import WebKit

extension WebKitPageDelegateAdapter {
    /// Element fullscreen sends this too, so only a page in picture-in-picture acts on it.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        guard let session = uiOwner(of: webView), session.hasPiPActive, !session.isDetached,
              let window = session.controller?.window(for: session) else { return }
        session.controller?.select(session.itemID, in: window)
        window.windowHandle?.bringToFront()
        NSApp.activate()
    }
}
#endif
