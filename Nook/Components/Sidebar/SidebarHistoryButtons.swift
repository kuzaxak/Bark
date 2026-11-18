// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarHistoryButtons.swift
//  Nook
//
//  Created by Maciek Bagiński on 30/07/2025.
//
import AppKit
import SwiftUI
import WebKit
import NookDesign
import NookWeb
import NookUI

/// Back, forward and reload for the page, styled for either toolbar placement.
struct SidebarHistoryButtons: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    var atTop = false

    var body: some View {
        if atTop {
            buttons
                .labelStyle(.iconOnly)
                .buttonStyle(NookIconButtonStyle())
        } else {
            buttons.nookSidebarIconButtons(size: NookDesign.SidebarChrome.titleButton)
        }
    }

    private var buttons: some View {
        HStack(spacing: atTop ? 4 : NookDesign.SidebarChrome.gap) {
            Button("Go Back", systemImage: atTop ? "chevron.backward" : "arrow.left", action: goBack)
                .disabled(!canGoBack)
                .opacity(atTop && !canGoBack ? 0.4 : 1)
                .overlay(NavigationHistoryMenu(direction: .back, windowState: windowState))
            Button("Go Forward", systemImage: atTop ? "chevron.right" : "arrow.right", action: goForward)
                .disabled(!canGoForward)
                .opacity(atTop && !canGoForward ? 0.4 : 1)
                .overlay(NavigationHistoryMenu(direction: .forward, windowState: windowState))
            Button(action: reloadOrStop) {
                Image(systemName: session?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(session?.isLoading == true ? "Stop Loading" : "Reload")
            .disabled(browserManager.engine == .chromium && session == nil)
        }
    }

    /// Nil while another window holds the page: its controls stay inert until Move Here.
    private var session: PageSession? {
        browserManager.engine == .chromium
            ? browserManager.frontPage(in: windowState)
            : browserManager.tabs.controllableSession(in: windowState)
    }

    private var canGoBack: Bool { session?.canGoBackOrReturn ?? false }
    private var canGoForward: Bool { session?.canGoForward ?? false }

    /// This window's own view of the page, so a clone navigates in its window.
    private var windowWebView: WKWebView? {
        session.flatMap { browserManager.webViewCoordinator?.getWebView(for: $0.itemID, in: windowState.id) }
    }

    private func goBack() {
        if browserManager.engine == .chromium {
            if let session { _ = browserManager.performNativePageCommand(.goBack, in: windowState, page: session) }
        } else { session?.goBack(in: windowWebView) }
    }

    private func goForward() {
        if browserManager.engine == .chromium {
            if let session { _ = browserManager.performNativePageCommand(.goForward, in: windowState, page: session) }
        } else if let webView = windowWebView { webView.goForward() } else { session?.goForward() }
    }

    private func reloadOrStop() {
        guard let session else { return }
        if session.isLoading {
            if browserManager.engine == .chromium {
                guard let window = windowState.window, window === NSApp.keyWindow,
                      browserManager.windowRegistry?.activeWindow === windowState,
                      browserManager.windowRegistry?.windows[windowState.id] === windowState,
                      let navigation = session.navigation,
                      browserManager.tabs.nativePageHost?.isNativeSelection(navigation, in: windowState) == true else { return }
            }
            session.stop()
        } else if browserManager.engine == .chromium {
            _ = browserManager.performNativePageCommand(.reload, in: windowState, page: session)
        } else {
            session.refresh()
        }
    }
}
