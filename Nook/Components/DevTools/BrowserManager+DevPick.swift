// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+DevPick.swift
//  Nook
//
//  Element handoff: the picked element's screenshot, the Markdown on the clipboard, the
//  selection DevMCP serves, and the toast.
//

import AppKit
import OSLog
import WebKit
import NookWeb

extension BrowserManager {
    private static let devLog = Logger(subsystem: "com.gstudios.nook", category: "DevTools")

    func installDevPickHandler() {
        tabs.onDevPick = { [weak self] session, element in
            Task { @MainActor in await self?.handleDevPick(session, element) }
        }
    }

    private func handleDevPick(_ session: PageSession, _ element: DevPickedElement) async {
        let imagePath = await snapshot(of: element, in: session)
        let context = session.devHandoffContext
        let markdown = DevHandoff.markdown(element: element, errors: context.errors,
                                           failed: context.failed, imagePath: imagePath)
        handOff(DevPick(markdown: markdown, imagePath: imagePath), from: session)
        showDevToast("Element copied")
    }

    func nativeDeveloperPage(in window: BrowserWindowState) -> (PageSession, ChromiumPageNavigation)? {
        guard nookSettings?.developerModeEnabled == true, !window.isIncognito,
              windowRegistry?.windows[window.id] === window, windowRegistry?.activeWindow === window,
              let owner = window.window, owner === NSApp.keyWindow, owner.attachedSheet == nil,
              let page = frontPage(in: window), !page.isAgentPage,
              let navigation = page.navigation as? ChromiumPageNavigation,
              tabs.nativePageHost?.isNativeSelection(navigation, in: window) == true else { return nil }
        return (page, navigation)
    }

    func currentNativeDeveloperPick(in window: BrowserWindowState) -> DevPick? {
        guard let (page, navigation) = nativeDeveloperPage(in: window),
              let selection = navigation.lastDeveloperPick, selection.window == window.id,
              selection.owner == navigation.nativeWindowID, selection.profile == navigation.profileID,
              selection.document == page.nativeNavigationSerial else {
            return nil
        }
        return selection.pick
    }

    /// Chromium supplies the selector from the user's click and reads its own document.
    @discardableResult
    func pickNativeElement(on page: PageSession, navigation: ChromiumPageNavigation,
                           in window: BrowserWindowState, while permitted: () -> Bool = { true }) async -> DevPick? {
        let serial = page.nativeNavigationSerial
        let owner = navigation.nativeWindowID, profile = navigation.profileID
        func current() -> Bool {
            guard !Task.isCancelled, permitted(), page.nativeNavigationSerial == serial,
                  navigation.nativeWindowID == owner, navigation.profileID == profile, !navigation.isClosed,
                  let (activePage, activeNavigation) = nativeDeveloperPage(in: window) else { return false }
            return activePage === page && activeNavigation === navigation
        }
        guard current(), let selector = await navigation.pickElement(), current(),
              let describe = page.nativeDevPickScript(selector),
              let described = try? await navigation.evaluateScript(describe, mode: .asyncBody, world: .isolated), current(),
              let body = try? JSONSerialization.jsonObject(with: Data(described.json.utf8)),
              var element = DevPickedElement(message: body) else { return nil }
        if element.source?.isEmpty == true { element.source = nil }
        if let hints = page.nativeDevHintsScript(selector),
           let read = try? await navigation.evaluateScript(hints, mode: .asyncBody, world: .page) {
            element.apply(hints: try? JSONSerialization.jsonObject(with: Data(read.json.utf8)))
        }
        guard current() else { return nil }
        let pick = DevPick(markdown: DevHandoff.markdown(element: element, errors: [], failed: [], imagePath: nil))
        navigation.lastDeveloperPick = (window.id, owner, profile, serial, pick)
        handOff(pick, from: page)
        showDevToast("Element copied")
        return pick
    }

    /// Clipboard, DevMCP `selection`, and the Agent tab's compose box.
    func handOff(_ pick: DevPick, from session: PageSession?) {
        session?.devCapture?.lastPick = pick
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pick.markdown, forType: .string)
        guard let windowState = windowRegistry?.activeWindow else { return }
        windowState.agentDraft = pick.markdown
        if windowState.isSidebarAIChatVisible { windowState.devPanelTab = .agent }
    }

    private func showDevToast(_ text: String) {
        guard let windowState = windowRegistry?.activeWindow else { return }
        windowState.copyToastText = text
        windowState.isShowingCopyURLToast = true
        Task { [weak windowState] in
            try? await Task.sleep(for: .seconds(2))
            windowState?.isShowingCopyURLToast = false
            windowState?.copyToastText = nil
        }
    }

    /// The element's on-screen part as a PNG in Caches/DevPicks; picks older than a day are deleted.
    private func snapshot(of element: DevPickedElement, in session: PageSession) async -> String? {
        guard let webView = session.webView else { return nil }
        let scale = webView.pageZoom * webView.magnification
        let topInset: CGFloat
        if #available(macOS 26, *) {
            topInset = webView.obscuredContentInsets.top
        } else {
            topInset = 0
        }
        let rect = CGRect(x: element.rect.minX * scale, y: element.rect.minY * scale + topInset,
                          width: element.rect.width * scale, height: element.rect.height * scale)
            .intersection(webView.bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        do {
            let image = try await webView.takeSnapshot(configuration: config)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            let dir = try Self.devPicksDirectory()
            let url = dir.appendingPathComponent("pick-\(Int(Date().timeIntervalSince1970 * 1000)).png")
            try png.write(to: url)
            return url.path
        } catch {
            Self.devLog.error("pick snapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func devPicksDirectory() throws -> URL {
        let fm = FileManager.default
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ee.qdo.nook")
            .appendingPathComponent("DevPicks")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-86_400)
        for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? fm.removeItem(at: file) }
        }
        return dir
    }
}
