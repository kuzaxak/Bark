// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+ActivePage.swift
//  Nook
//

import AppKit
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

    /// Runs `command` on the active window's page in front.
    func perform(_ command: PageCommand) {
        guard let window = windowRegistry?.activeWindow, let page = frontPage(in: window) else { return }
        performNativePageCommand(command, in: window, page: page)
    }

    /// The engine can refuse a zoom step at its bounds (including a reset at
    /// default zoom). Still report the authoritative level of the same page.
    func zoomFromKeyboard(_ command: PageCommand, in window: BrowserWindowState, page: PageSession) {
        guard command.isZoomCommand,
              let native = page.navigation as? ChromiumPageNavigation,
              let host = tabs.nativePageHost as? ChromiumNativePageHost else { return }
        let tab = native.nativeTabID, owner = native.nativeWindowID, document = page.nativeNavigationSerial
        func currentRoot() -> ChromiumWindowRoot? {
            guard windowRegistry?.windows[window.id] === window,
                  windowRegistry?.activeWindow === window, let keyWindow = CommandWindow.key,
                  window.window === keyWindow, frontPage(in: window) === page,
                  page.navigation === native, page.nativeNavigationSerial == document,
                  native.nativeTabID == tab, native.nativeWindowID == owner else { return nil }
            return host.zoomFeedbackRoot(for: native, in: window)
        }
        guard let root = currentRoot() else { return }
        _ = native.performNativePageCommand(command)
        guard currentRoot() === root, let percent = native.nativeZoomPercent else { return }
        root.showZoomPercent(percent, tab: tab, of: owner)
    }

    /// Product page commands never fall through to a lazy WebKit surface.
    @discardableResult
    func performNativePageCommand(_ command: PageCommand, in window: BrowserWindowState,
                                  page: PageSession) -> Bool {
        guard windowRegistry?.windows[window.id] === window,
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
        guard tabs.nativePageHost?.isNativeSelection(native, in: window) == true ||
              peekManager.isNativeSelection(page, in: window) else { return false }
        if command == .boost { openBoostPanel(in: window); return true }
        if command == .developerMode {
            guard page.url.host != nil else { return false }
            toggleDeveloperSite(of: page, in: window)
            return true
        }
        if command == .pickElement, native.supportsElementPicker {
            withDeveloperCapture { [weak self, weak page, weak native, weak window] in
                guard let self, let page, let native, let window else { return }
                Task { await self.pickNativeElement(on: page, navigation: native, in: window) }
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
            return !Task.isCancelled &&
                self.windowRegistry?.windows[window.id] === window &&
                self.windowRegistry?.activeWindow === window &&
                window.window != nil && window.window === CommandWindow.key &&
                self.frontPage(in: window) === page && page.navigation === native &&
                page.nativeNavigationSerial == serial && !native.isClosed &&
                native.nativeWindowID == owner && native.nativeTabID == tab && native.profileID == profile &&
                (self.tabs.nativePageHost?.isNativeSelection(native, in: window) == true ||
                 self.peekManager.isNativeSelection(page, in: window))
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

    /// A tooltip with the action's shortcut, as Arc's show it: "Copy URL (⇧⌘C)".
    func help(_ title: String, shortcut action: ShortcutAction) -> String {
        guard let shortcut = keyboardShortcutManager?.shortcut(for: action), shortcut.isEnabled,
              !shortcut.keyCombination.key.isEmpty else { return title }
        return "\(title) (\(shortcut.keyCombination.displayString))"
    }
}
