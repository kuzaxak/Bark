// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+DevPick.swift
//  Nook
//
//  Element handoff: the Markdown on the clipboard, the
//  selection DevMCP serves, and the toast.
//

import AppKit
import NookWeb

extension BrowserManager {
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
}
