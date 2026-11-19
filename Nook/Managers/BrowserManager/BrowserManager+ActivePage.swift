// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+ActivePage.swift
//  Nook
//

import AppKit
import SwiftUI
import WebKit
import NookWeb

extension BrowserManager {
    // MARK: - Page in Front

    /// The page shortcuts and menu commands act on in `window` (`FrontPage`). Nil when the window
    /// shows no page, or while another window holds its selected tab's page.
    func frontPage(in window: BrowserWindowState) -> PageSession? {
        guard !window.nativeSpaceSwitchIsUnresolved else { return nil }
        let peek = peekManager.page(in: window)
        switch FrontPage(peek: peek?.itemID, selectedTab: window.selectedItemID) {
        case .peek?: return peek
        case .tab?: return tabs.controllableSession(in: window)
        case nil: return nil
        }
    }

    /// The active window's page in front.
    var frontPage: PageSession? {
        windowRegistry?.activeWindow.flatMap { frontPage(in: $0) }
    }

    /// `window`'s own view of its page in front.
    func frontWebView(in window: BrowserWindowState) -> WKWebView? {
        guard let page = frontPage(in: window) else { return nil }
        return getWebView(for: page.itemID, in: window.id) ?? page.webView
    }

    /// Runs `command` on the active window's page in front.
    func perform(_ command: PageCommand) {
        guard let window = windowRegistry?.activeWindow, let page = frontPage(in: window) else { return }
        if tabs.profileEngine == .chromium {
            _ = performNativePageCommand(command, in: window, page: page)
            return
        }
        let webView = frontWebView(in: window)
        switch command {
        case .goBack:
            WebKitPageCommands.goBack(on: page, in: webView)
        case .goForward:
            if webView?.canGoForward == true { webView?.goForward() }
        case .reload:
            page.refresh()
        case .clearCookiesAndReload:
            clearCookies(of: page)
            page.refresh()
        case .hardReload:
            guard let host = page.url.host else { return }
            Task { @MainActor in
                await cacheManager?.clearCacheForDomainExcludingCookies(host)
                webView?.reloadFromOrigin()
            }
        case .reloadWithStandardProtection:
            page.reloadWithoutEnhancedFingerprintingProtection()
        case .find:
            if findManager.isFindBarVisible {
                findManager.hideFindBar()
            } else {
                findManager.showFindBar(for: page)
            }
        case .zoomIn:
            guard let webView else { return }
            zoomManager.zoomIn(for: webView, tabId: page.itemID)
            shouldShowZoomPopup = true
        case .zoomOut:
            guard let webView else { return }
            zoomManager.zoomOut(for: webView, tabId: page.itemID)
            shouldShowZoomPopup = true
        case .actualSize:
            guard let webView else { return }
            zoomManager.resetZoom(for: webView, tabId: page.itemID)
            shouldShowZoomPopup = true
        case .copyURL:
            copyURL(of: page, in: window)
        case .print:
            webView?.nookPrint()
        case .developerConsole: toggleDevPanel(.console)
        case .developerNetwork: toggleDevPanel(.network)
        case .developerPerformance: toggleDevPanel(.perf)
        case .webInspector:
            openWebInspector(on: page.activeWebView)
        case .pickElement:
            withDeveloperCapture { page.startDevPicker() }
        case .copyScreenshot:
            copyScreenshot(of: webView, in: window)
        case .developerMode:
            toggleDeveloperSite(of: page, in: window)
        case .pictureInPicture:
            page.requestPictureInPicture()
        case .mute:
            page.toggleMute()
        case .translate:
            page.toggleTranslation()
        case .clearSiteCookies:
            clearCookies(of: page)
        case .clearSiteCache:
            guard let host = page.url.host else { return }
            Task { await cacheManager?.clearCacheForDomain(host) }
        case .boost:
            openBoostPanel(in: window)
        }
    }

    /// Product page commands never fall through to a lazy WebKit surface.
    @discardableResult
    func performNativePageCommand(_ command: PageCommand, in window: BrowserWindowState,
                                  page: PageSession) -> Bool {
        guard tabs.profileEngine == .chromium, windowRegistry?.windows[window.id] === window,
              windowRegistry?.activeWindow === window, let keyWindow = CommandWindow.key,
              window.window === keyWindow,
              frontPage(in: window) === page,
              let native = page.navigation as? ChromiumPageNavigation else { return false }
        // Detached Peek pages are intentionally outside the saved-session host
        // map. frontPage above verifies their current product owner; translation
        // itself remains bound to this exact native document/profile.
        if command == .translate, page.isDetached {
            guard native.supportsTranslation, page.canTranslate || page.isTranslated else { return false }
            page.toggleTranslation(); return true
        }
        guard tabs.nativePageHost?.isNativeSelection(native, in: window) == true else { return false }
        if command == .boost { openBoostPanel(in: window); return true }
        if command == .developerMode {
            guard page.url.host != nil else { return false }
            toggleDeveloperSite(of: page, in: window)
            return true
        }
        if command == .pickElement, native.supportsElementPicker {
            withDeveloperCapture { [weak self, weak page, weak native] in
                guard let self, let page, let native else { return }
                Task { await self.pickNativeElement(on: page, navigation: native) }
            }
            return true
        }
        guard command.supportsNativePage else {
            showWindowToast("This action is not available yet", in: window)
            return false
        }
        // Back also owns the existing no-history return-to-opener behavior.
        if command == .goBack { page.goBack(); return true }
        if command == .copyURL { copyURL(of: page, in: window); return true }
        if command == .copyScreenshot {
            let serial = page.nativeNavigationSerial
            let owner = native.nativeWindowID, tab = native.nativeTabID
            Task { [weak self, weak page, weak window, weak native] in
                guard let self, let page, let window, let native,
                      page.navigation === native, page.nativeNavigationSerial == serial,
                      native.nativeWindowID == owner, native.nativeTabID == tab else { return }
                await self.copyNativeScreenshot(of: page, in: window)
            }
            return true
        }
        if command == .translate {
            guard native.supportsTranslation, page.canTranslate || page.isTranslated else { return false }
            page.toggleTranslation(); return true
        }
        return native.performNativePageCommand(command) { [weak self, weak window, weak page, weak native] outcome in
            guard case .failed = outcome, let self, let window, let page, let native,
                  self.windowRegistry?.windows[window.id] === window,
                  self.windowRegistry?.activeWindow === window,
                  self.frontPage(in: window) === page, page.navigation === native else { return }
            self.showWindowToast("Could not clear site data", in: window)
        }
    }

    /// Copy the requested document only while it still owns the front surface.
    /// A delayed screenshot must not replace a newer clipboard operation.
    func captureNativeScreenshot(of page: PageSession, in window: BrowserWindowState) async -> (image: NSImage, isCurrent: @MainActor () -> Bool)? {
        guard let native = page.navigation as? ChromiumPageNavigation else { return nil }
        let serial = page.nativeNavigationSerial
        let owner = native.nativeWindowID, tab = native.nativeTabID, profile = native.profileID
        let current: @MainActor () -> Bool = { [weak self, weak page, weak window, weak native] in
            guard let self, let page, let window, let native else { return false }
            return !Task.isCancelled && self.tabs.profileEngine == .chromium &&
                self.windowRegistry?.windows[window.id] === window &&
                self.windowRegistry?.activeWindow === window &&
                window.window != nil && window.window === CommandWindow.key &&
                self.frontPage(in: window) === page && page.navigation === native &&
                page.nativeNavigationSerial == serial && !native.isClosed &&
                native.nativeWindowID == owner && native.nativeTabID == tab && native.profileID == profile &&
                self.tabs.nativePageHost?.isNativeSelection(native, in: window) == true
        }
        guard current() else { return nil }
        let image: NSImage
        do {
            let bytes = try await native.captureScreenshot(maxWidth: 4096)
            guard current() else { return nil }
            guard let captured = NSImage(data: bytes) else { throw ChromiumNavigationError.screenshotUnavailable }
            image = captured
        } catch {
            if current() {
                showWindowToast("Screenshot unavailable", in: window)
            }
            return nil
        }
        return (image, current)
    }

    @discardableResult
    func copyNativeScreenshot(of page: PageSession, in window: BrowserWindowState) async -> Bool {
        let clipboard = NSPasteboard.general
        let clipboardVersion = clipboard.changeCount
        guard let capture = await captureNativeScreenshot(of: page, in: window),
              capture.isCurrent(), clipboard.changeCount == clipboardVersion else { return false }
        clipboard.clearContents()
        let copied = clipboard.writeObjects([capture.image])
        showWindowToast(copied ? "Screenshot copied" : "Could not copy screenshot", in: window)
        return copied
    }

    private func clearCookies(of page: PageSession) {
        guard let host = page.url.host else { return }
        Task { await cookieManager?.deleteCookiesForDomain(host) }
    }

    func copyURL(of page: PageSession, in window: BrowserWindowState) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(page.storableURL.absoluteString, forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
        window.isShowingCopyURLToast = true
        Task { [weak window] in
            try? await Task.sleep(for: .seconds(2))
            window?.isShowingCopyURLToast = false
        }
    }

    private func openWebInspector(on webView: WKWebView) {
        // `_inspector` is WebKit SPI with no public spelling; the alert covers a WebKit without it.
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector),
              let inspector = webView.perform(selector)?.takeUnretainedValue() as? NSObject else {
            showWebInspectorAlert()
            return
        }
        inspector.perform(NSSelectorFromString("show"))
        inspector.perform(NSSelectorFromString("attach"))
    }

    private func showWebInspectorAlert() {
        let alert = NSAlert()
        alert.messageText = "Open Web Inspector"
        alert.informativeText = "To open the Web Inspector:\n\n1. Right-click on the page and select 'Inspect Element'\n\nOr enable the Develop menu in Safari Settings → Advanced, then use Develop → [Your App]"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Cookie Management Methods

    func clearAllCookies() {
        Task {
            await cookieManager?.deleteAllCookies()
        }
    }

    func clearExpiredCookies() {
        Task {
            await cookieManager?.deleteExpiredCookies()
        }
    }

    // MARK: - Cache Management

    func clearStaleCache() {
        Task {
            await cacheManager?.clearStaleCache()
        }
    }

    func clearDiskCache() {
        Task {
            await cacheManager?.clearDiskCache()
        }
    }

    func clearMemoryCache() {
        Task {
            await cacheManager?.clearMemoryCache()
        }
    }

    func clearAllCache() {
        Task {
            await cacheManager?.clearAllCache()
        }
    }

    /// An Escape the page left alone (`EscapeKey`). Closes the innermost thing the window shows:
    /// a page's own full screen, then Peek. The window itself stays as it is.
    func escapePressed(in nsWindow: NSWindow) {
        guard let state = windowRegistry?.windows.values.first(where: { $0.window === nsWindow }) else { return }
        let peek = peekManager.page(in: state)
        let shown = [peek, tabs.selectedSession(in: state)]
            + (state.split?.itemIDs ?? []).map(tabs.session(for:))
        if let view = shown.compactMap({ $0?.webView }).first(where: { $0.fullscreenState != .notInFullscreen }) {
            view.evaluateJavaScript("document.exitFullscreen()")
        } else if peek != nil {
            peekManager.dismissPeek(in: state)
        }
    }

    /// A tooltip with the action's shortcut, as Arc's show it: "Copy URL (⇧⌘C)".
    func help(_ title: String, shortcut action: ShortcutAction) -> String {
        guard let shortcut = keyboardShortcutManager?.shortcut(for: action), shortcut.isEnabled,
              !shortcut.keyCombination.key.isEmpty else { return title }
        return "\(title) (\(shortcut.keyCombination.displayString))"
    }

    // MARK: - Zoom Management

    /// Reset zoom when a tab navigates, so a page never inherits the previous page's zoom.
    func loadZoomForTab(_ tabId: UUID) {
        // A background tab navigating must not move the readout off the tab being looked at.
        zoomManager.showZoomLevel(for: windowRegistry?.activeWindow?.selectedItemID)
    }

    /// Clean up zoom data when a tab is closed
    func cleanupZoomForTab(_ tabId: UUID) {
        zoomManager.removeTabZoomLevel(for: tabId)
    }

}
