// Licensed under GPL-3.0. See LICENSE.
//
//  DeveloperBar.swift
//  Nook
//
//  Arc's Developer Mode bar: the page's full address in monospace above the page, and the
//  developer tools a click away. Shown for sites with Developer Mode on (the site panel's
//  Settings section); the tools themselves are the ones Settings > Developer turns on.
//

import AppKit
import SwiftUI
import NookDesign
import NookWeb
import NookUI

extension BrowserManager {
    /// Whether the window's page is on a site with Developer Mode on.
    func showsDeveloperBar(in windowState: BrowserWindowState) -> Bool {
        guard !windowState.isIncognito, let settings = nookSettings,
              let host = frontPage(in: windowState)?.url.host else { return false }
        return settings.isDeveloperSite(host)
    }

    /// Turns Developer Mode on or off for `host`, asked from `window`; a private window saves none.
    /// Off, every window whose bar goes with it closes a right column that shows a developer tool.
    @discardableResult func setDeveloperSite(_ host: String, on: Bool, in window: BrowserWindowState) -> Bool {
        guard !window.isIncognito, let settings = nookSettings else { return false }
        let barred = windowRegistry?.allWindows.filter { showsDeveloperBar(in: $0) } ?? []
        settings.setDeveloperSite(host, on: on)
        closeDeveloperTools(in: barred.filter { !showsDeveloperBar(in: $0) }, developerMode: settings.developerModeEnabled)
        return true
    }

    /// The key and the command bar's Toggle Developer Mode for Site, with a toast saying what happened.
    func toggleDeveloperSite(of page: PageSession, in window: BrowserWindowState) {
        guard let settings = nookSettings, let host = page.url.host else { return }
        let on = !settings.isDeveloperSite(host)
        guard setDeveloperSite(host, on: on, in: window) else {
            showWindowToast("Developer Mode isn’t available in private windows", in: window)
            return
        }
        showWindowToast("Developer Mode \(on ? "on" : "off") for \(host)", in: window)
    }

    /// Developer Mode going off beside these windows' pages: a right column that shows a developer
    /// tool closes, one on the Agent tab stays. `developerMode` is the Settings one it showed under.
    func closeDeveloperTools(in windows: [BrowserWindowState], developerMode: Bool) {
        let agent = nookSettings?.showAIAssistant == true
        withAnimation(NookDesign.Motion.standard) {
            for window in windows {
                let tab = DevPanelTab.shown(window.devPanelTab, developerMode: developerMode, agent: agent)
                let open = DevPanelTab.staysOpen(window.isSidebarAIChatVisible, showing: tab)
                if open != window.isSidebarAIChatVisible { window.isSidebarAIChatVisible = open }
            }
        }
    }

    /// Chromium keeps the selected address placement when the developer tools are visible.
    func showsTopBar(in windowState: BrowserWindowState) -> Bool {
        nookSettings?.topBarAddressView == true
    }

    func withDeveloperCapture(_ action: () -> Void) {
        guard nookSettings != nil else { return }
        action()
    }

    func togglePortraitCapture(in windowState: BrowserWindowState) {
        withAnimation(NookDesign.Motion.spring) { windowState.isPortraitCaptureVisible.toggle() }
    }

    /// The copy toast with any message, for the developer tools.
    func showWindowToast(_ text: String, in windowState: BrowserWindowState) {
        windowState.copyToastText = text
        windowState.isShowingCopyURLToast = true
        Task { [weak windowState] in
            try? await Task.sleep(for: .seconds(2))
            windowState?.isShowingCopyURLToast = false
            windowState?.copyToastText = nil
        }
    }
}

struct DeveloperBar: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.chromiumSiteControlsAnchor) private var siteControlsAnchor
    let session: PageSession
    var showsAddress = true

    @State private var copied = false

    static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: NookDesign.Spacing.md) {
            if showsAddress {
                Button {
                    siteControlsAnchor?.source = .developer
                    withAnimation(.interpolatingSpring(Spring(response: 0.3, dampingRatio: 0.86))) {
                        windowState.isExtensionLibraryVisible = true
                    }
                } label: {
                    Image(systemName: session.url.scheme == "https" ? "lock.fill" : "lock.open.fill")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: NookDesign.Size.rowButton, height: NookDesign.Size.rowButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Site Controls")
                .background {
                    if let siteControlsAnchor {
                        ChromiumSiteControlsButtonProbe(anchor: siteControlsAnchor, source: .developer)
                    }
                }

                Text(session.url.absoluteString)
                    .font(NookDesign.Font.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: NookDesign.Spacing.lg)

            HStack(spacing: NookDesign.Spacing.xxs) {
                tool(copied ? "checkmark" : "link", "Copy Link", shortcut: .copyCurrentURL) {
                    guard nativeCurrent else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.url.absoluteString, forType: .string)
                    withAnimation(NookDesign.Motion.quick) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation(NookDesign.Motion.quick) { copied = false }
                    }
                }
                separator
                tool("photo.on.rectangle.angled", "Capture in Portrait Mode", shortcut: .capturePortrait,
                     isOn: windowState.isPortraitCaptureVisible) { if nativeCurrent { browserManager.togglePortraitCapture(in: windowState) } }
                tool("camera", "Copy Screenshot", shortcut: .copyScreenshot) { perform(.copyScreenshot) }
                separator
                tool("terminal", "Console", shortcut: .openDevPanel) { perform(.developerConsole) }
                tool("network", "Network", shortcut: .openNetworkPanel) { perform(.developerNetwork) }
                tool("scope", "Pick Element", shortcut: .pickElement) { perform(.pickElement) }
                    .disabled(browserManager.nookSettings?.developerModeEnabled != true ||
                              session.navigation?.supportsElementPicker != true)
                separator
                tool("hammer", "Web Inspector", shortcut: .openDevTools) { perform(.webInspector) }
                tool("gauge.with.needle", "Performance", shortcut: .openPerformancePanel) { perform(.developerPerformance) }
            }
        }
        .padding(.horizontal, NookDesign.Spacing.lg)
        .frame(height: Self.height)
        .background(NookDesign.Surface.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(NookDesign.Surface.hairline).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var separator: some View {
        Rectangle()
            .fill(NookDesign.Surface.hairline)
            .frame(width: 1, height: NookDesign.Spacing.xl)
            .padding(.horizontal, NookDesign.Spacing.xs)
    }

    private var nativeCurrent: Bool {
        browserManager.windowRegistry?.windows[windowState.id] === windowState &&
            browserManager.windowRegistry?.activeWindow === windowState &&
            windowState.window != nil && windowState.window === NSApp.keyWindow &&
            browserManager.frontPage(in: windowState) === session &&
            (session.navigation.map { browserManager.tabs.nativePageHost?.isNativeSelection($0, in: windowState) == true } ?? false)
    }

    private func perform(_ command: PageCommand) {
        _ = browserManager.performNativePageCommand(command, in: windowState, page: session)
    }

    private func tool(_ symbol: String, _ help: String, shortcut: ShortcutAction, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(help, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .contentTransition(.symbolEffect(.replace))
            .buttonStyle(NookIconButtonStyle())
            .background(isOn ? NookDesign.Surface.fillPressed : .clear, in: NookDesign.Radius.shape(NookDesign.Radius.md))
            .help(browserManager.help(help, shortcut: shortcut))
    }
}
