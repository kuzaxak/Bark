// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+NookWeb.swift
//  Nook
//
//  AppKit host callbacks for the tab model and its live pages.
//

import AppKit
import WebKit
import NookWeb

// MARK: - PageSessionDelegate

extension BrowserManager: PageSessionDelegate {
    func presentPeek(url: URL, from session: PageSession) {
        peekManager.presentExternalURL(url, from: session)
    }

    func cleanupZoom(for itemID: UUID) { cleanupZoomForTab(itemID) }

    func setMuteState(_ muted: Bool, for itemID: UUID) {}
}

// MARK: - TabEventObserver

extension BrowserManager: TabEventObserver {
    func tabOpened(_ session: PageSession) {
        extensionManager?.notifyTabOpened(session)
    }

    func tabActivated(new session: PageSession, previous: PageSession?) {
        zoomManager.showZoomLevel(for: session.itemID)
        extensionManager?.notifyTabActivated(new: session, previous: previous)
        updateSidebarPiP(new: session, previous: previous)
        session.sampleNativeTopBarColor()
    }

    func tabClosed(itemID: UUID) {
        extensionManager?.notifyTabClosed(itemID: itemID)
        exitSidebarPiP(showing: itemID)
    }

    func tabMoved(itemID: UUID, from oldIndex: Int?, in oldWindow: BrowserWindowState?, pinnedChanged: Bool) {
        extensionManager?.notifyTabMoved(
            itemID: itemID, from: oldIndex, in: oldWindow, pinnedChanged: pinnedChanged)
    }

    func tabPropertiesChanged(_ session: PageSession, properties: WKWebExtension.TabChangedProperties) {
        extensionManager?.notifyTabPropertiesChanged(session, properties: properties)
    }

    func grantAccess(to url: URL) {
        extensionManager?.grantExtensionAccessToURL(url)
    }

    func wakeBackgroundWorkers() {
        extensionManager?.wakeBackgroundWorkers()
    }

    /// Leaving a playing video moves it into the sidebar panel; coming back puts it inline again.
    /// Runs before the compositor refreshes, so the outgoing web view is still mounted.
    private func updateSidebarPiP(new session: PageSession, previous: PageSession?) {
        guard engine == .webKit else { return }
        let windows = Array(windowRegistry?.windows.values ?? [:].values)
        // The window that made the selection: a script or background window is not the key one.
        let active = windowRegistry?.activeWindow
        guard let windowState = active?.selectedItemID == session.itemID ? active
            : windows.first(where: { $0.selectedItemID == session.itemID })
        else { return }
        // Coming back to a tab brings its video home, from any window's sidebar or from the
        // system window Nook opened for it.
        exitSidebarPiP(showing: session.itemID)
        PiPManager.shared.leaveAutomatic(session)

        guard nookSettings?.autoPictureInPicture == true,
            let previous, previous.hasPlayingVideo, previous.hasPlayingAudio,
            !previous.isPrivate, !previous.hasPiPActive,
            // Another window or the other split pane may still be showing it.
            !tabs.isVisibleInAnyWindow(previous.itemID),
            SidebarPiPController.allowsAutomatic(previous.url),
            // A video already in picture-in-picture keeps it, and so does one playing in its tab.
            !windows.contains(where: { $0.sidebarPiPController?.isShowing == true }),
            !tabs.sessions.contains(where: {
                $0 !== previous && $0 !== session && ($0.hasPiPActive || ($0.hasPlayingVideo && $0.hasPlayingAudio))
            })
        else { return }

        guard let webView = getWebView(for: previous.itemID, in: windowState.id) ?? previous.assignedWebView
        else { return }

        // No sidebar means nothing to anchor to, so fall back to the system PiP window.
        guard windowState.isSidebarVisible, let controller = windowState.sidebarPiPController else {
            PiPManager.shared.enterAutomatically(previous, webView: webView, screened: true)
            return
        }
        controller.enter(session: previous, webView: webView, automatic: true) {
            PiPManager.shared.enterAutomatically(previous, webView: webView, screened: true)
        }
    }

    /// Ends any window's sidebar picture-in-picture of `itemID`.
    func exitSidebarPiP(showing itemID: UUID) {
        guard engine == .webKit else { return }
        for window in windowRegistry?.windows.values ?? [:].values {
            window.sidebarPiPController?.exitIfShowing(itemID)
        }
    }

    /// A hidden sidebar has nowhere to dock, so a docked video carries on in the system window.
    func sidebarPiPSidebarHidden(in windowState: BrowserWindowState) {
        guard engine == .webKit else { return }
        guard let controller = windowState.sidebarPiPController, controller.isDocked,
            let session = controller.session, let webView = controller.webView
        else { return }
        controller.exit()
        PiPManager.shared.enterAutomatically(session, webView: webView, screened: false)
    }

    /// The video follows the focused window, docked or floating, so its drop zone is always here.
    func moveSidebarPiP(to windowState: BrowserWindowState) {
        guard engine == .webKit else { return }
        guard !windowState.isIncognito, let target = windowState.sidebarPiPController, !target.isShowing,
            let source = windowRegistry?.windows.values.compactMap(\.sidebarPiPController)
                .first(where: { $0 !== target && $0.isShowing }),
            source.session?.isPrivate == false, source.isReady,
            source.isFloating || windowState.isSidebarVisible
        else { return }
        target.adopt(from: source)
    }

    /// A closing window takes its pages' views with it, so no controller may keep showing one.
    func sidebarPiPWindowClosing(_ windowId: UUID) {
        for window in windowRegistry?.windows.values ?? [:].values {
            guard let controller = window.sidebarPiPController, let itemID = controller.itemID,
                window.id == windowId || getWebView(for: itemID, in: windowId) != nil
            else { continue }
            controller.exit()
        }
    }

    // Chromium owns its extension lifecycle; absence is explicit, never a
    // request to initialize the legacy singleton.
    var nativeController: WKWebExtensionController? {
        extensionManager?.nativeController
    }

    func diagnose(for webView: WKWebView, url: URL) {
        #if DEBUG
        extensionManager?.diagnoseExtensionState(for: webView, url: url)
        #endif
    }
}

// MARK: - AlertPresenter

extension BrowserManager: AlertPresenter {
    /// A page dialog named for the frame that asked, so an iframe cannot speak as the site
    /// around it. `suppressible` adds the checkbox that ends an endless run of them.
    private func pageDialog(host: String, fallbackTitle: String, message: String, suppressible: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = host.isEmpty ? fallbackTitle : "\(host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if suppressible {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't allow more dialogs from this page"
        }
        return alert
    }

    func presentAlert(
        message: String, host: String, over webView: WKWebView,
        onSuppress: (() -> Void)?, completion: @escaping () -> Void
    ) {
        let alert = pageDialog(
            host: host, fallbackTitle: "JavaScript Alert", message: message, suppressible: onSuppress != nil)
        guard let window = webView.window else { return completion() }
        alert.beginSheetModal(for: window) { _ in
            if alert.suppressionButton?.state == .on { onSuppress?() }
            completion()
        }
    }

    func presentConfirm(
        message: String, host: String, over webView: WKWebView,
        onSuppress: (() -> Void)?, completion: @escaping (Bool) -> Void
    ) {
        let alert = pageDialog(
            host: host, fallbackTitle: "JavaScript Confirm", message: message, suppressible: onSuppress != nil)
        alert.addButton(withTitle: "Cancel")
        guard let window = webView.window else { return completion(false) }
        alert.beginSheetModal(for: window) {
            if alert.suppressionButton?.state == .on { onSuppress?() }
            completion($0 == .alertFirstButtonReturn)
        }
    }

    func presentPrompt(
        prompt: String, defaultText: String?, host: String, over webView: WKWebView,
        onSuppress: (() -> Void)?, completion: @escaping (String?) -> Void
    ) {
        let alert = pageDialog(
            host: host, fallbackTitle: "JavaScript Prompt", message: prompt, suppressible: onSuppress != nil)
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = defaultText ?? ""
        alert.accessoryView = textField
        guard let window = webView.window else { return completion(nil) }
        alert.beginSheetModal(for: window) {
            if alert.suppressionButton?.state == .on { onSuppress?() }
            completion($0 == .alertFirstButtonReturn ? textField.stringValue : nil)
        }
    }

    func presentOpenPanel(
        allowsMultipleSelection: Bool, allowsDirectories: Bool, over webView: WKWebView,
        completion: @escaping ([URL]?) -> Void
    ) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = allowsMultipleSelection
        openPanel.canChooseDirectories = allowsDirectories
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = true
        openPanel.title = "Choose File"
        openPanel.prompt = "Choose"
        DispatchQueue.main.async {
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                completion(response == .OK ? openPanel.urls : nil)
            }
            if let window = webView.window {
                openPanel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                openPanel.begin(completionHandler: finish)
            }
        }
    }
}
