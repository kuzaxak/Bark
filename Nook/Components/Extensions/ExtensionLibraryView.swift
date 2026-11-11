// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionLibraryView.swift
//  Nook
//

import AppKit
import os
import SwiftUI
import WebKit

import NookBlocker
import NookDesign
import NookSettings
import NookWeb
import NookUI

struct ExtensionLibraryView: View {
    let browserManager: BrowserManager
    let windowState: BrowserWindowState
    let settings: NookSettingsService
    let onDismiss: () -> Void
    let onShowMoreMenu: () -> Void


    private let logger = Logger(subsystem: "com.nook.browser", category: "ExtensionLibrary")

    private var isChromium: Bool { browserManager.engine == .chromium }

    private var currentTab: PageSession? {
        isChromium ? browserManager.frontPage(in: windowState) : browserManager.tabs.selectedSession(in: windowState)
    }

    private var currentHost: String? {
        currentTab?.url.host
    }

    /// Only web pages can be Boosted, and a private window saves none.
    private var boostHost: String? {
        guard !isPrivate, let url = currentTab?.url, url.scheme == "http" || url.scheme == "https" else { return nil }
        let host = Boost.normalizeHost(url.host ?? "")
        return host.isEmpty ? nil : host
    }

    static let width: CGFloat = 240
    private let columns = Array(repeating: GridItem(.flexible(), spacing: NookDesign.Spacing.sm), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.md + NookDesign.Spacing.xxs) {
            actionTiles
            extensionsSection
            settingsSection
            Rectangle().fill(NookDesign.Surface.hairline).frame(height: 1)
            footer
        }
        .padding(NookDesign.Spacing.md + NookDesign.Spacing.xxs)
        .frame(width: Self.width)
    }

    // MARK: - Actions

    /// Arc's top row: share, Boost, capture, sound.
    private var actionTiles: some View {
        HStack(spacing: NookDesign.Spacing.sm) {
            Menu {
                Button("Copy Link", systemImage: "link") {
                    guard let url = currentTab?.url.absoluteString else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    onDismiss()
                }
                if let url = currentTab?.url {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            } label: {
                ActionTileLabel(systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ActionTileStyle())
            .help("Share")
            .disabled(currentTab == nil)

            Button {
                browserManager.openBoostPanel(in: windowState)
                onDismiss()
            } label: {
                ActionTileLabel(systemImage: "paintbrush.pointed")
            }
            .buttonStyle(ActionTileStyle())
            .help(isPrivate ? "Boosts aren’t saved from private windows" : "Boost")
            .disabled(boostHost == nil)

            Button {
                onDismiss()
                withAnimation(NookDesign.Motion.spring) { windowState.isPortraitCaptureVisible = true }
            } label: {
                ActionTileLabel(systemImage: "camera")
            }
            .buttonStyle(ActionTileStyle())
            .help("Capture")
            .disabled(currentTab == nil)

            MuteButton(tab: currentTab)
        }
    }

    // MARK: - Extensions

    private var extensionsSection: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.sm) {
            Text("Extensions")
                .font(NookDesign.Font.label)

            let extensions = browserManager.extensionManager?.installedExtensions.filter { $0.isEnabled } ?? []
            LazyVGrid(columns: columns, spacing: NookDesign.Spacing.sm) {
                ForEach(extensions, id: \.id) { ext in
                    ExtensionGridItem(
                        ext: ext,
                        isPinned: settings.pinnedExtensionIDs.contains(ext.id),
                        browserManager: browserManager,
                        windowState: windowState,
                        settings: settings
                    )
                }
                Button(action: openWebStore) {
                    ActionTileLabel(systemImage: "plus", compact: true)
                }
                .buttonStyle(ActionTileStyle(raised: false))
                .help("Add Extension…")
            }
        }
    }

    // MARK: - Settings

    @State private var contentBlockerEnabled: Bool = true
    @State private var nativeZoomPercent: Int?

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.xs) {
            Text("Settings")
                .font(NookDesign.Font.label)
                .padding(.bottom, NookDesign.Spacing.xxs)

            if let host = currentHost {
                SiteSettingRow(
                    icon: "shield.lefthalf.filled",
                    title: "Content Blocker",
                    subtitle: (contentBlockerEnabled ? "On" : "Off for this site") + (isPrivate ? " · set in a regular window" : ""),
                    isOn: contentBlockerEnabled,
                    action: contentBlockerToggle(for: host)
                )
                .opacity(isPrivate ? NookDesign.Surface.unloadedOpacity : 1)
                .onAppear { contentBlockerEnabled = !browserManager.contentBlockerManager.isDomainAllowed(host) }
                .onChange(of: currentHost) { _, newHost in
                    if let newHost { contentBlockerEnabled = !browserManager.contentBlockerManager.isDomainAllowed(newHost) }
                }

                if !isChromium, let tab = currentTab, tab.enhancedFingerprintingProtectionApplies {
                    SiteSettingRow(
                        icon: "hand.raised.fill",
                        title: "Fingerprinting Protection",
                        subtitle: tab.usesEnhancedFingerprintingProtection ? "Enhanced" : "Standard until you leave this site",
                        isOn: tab.usesEnhancedFingerprintingProtection
                    ) {
                        if tab.usesEnhancedFingerprintingProtection {
                            tab.reloadWithoutEnhancedFingerprintingProtection()
                        } else {
                            tab.reloadWithEnhancedFingerprintingProtection()
                        }
                    }
                }

                let developer = !isPrivate && settings.isDeveloperSite(host)
                SiteSettingRow(
                    icon: "hammer.fill",
                    title: "Developer Mode",
                    subtitle: isPrivate ? "Not in private windows" : developer ? "On" : "Off",
                    isOn: developer,
                    action: developerModeToggle(for: host)
                )
                .opacity(isPrivate ? NookDesign.Surface.unloadedOpacity : 1)
            }

            if !isChromium {
                SiteSettingRow(
                    icon: "pip",
                    title: "Automatic Picture-in-Picture",
                    subtitle: settings.autoPictureInPicture ? "Allowed" : "Off",
                    isOn: settings.autoPictureInPicture
                ) {
                    settings.autoPictureInPicture.toggle()
                }
            }

            if currentTab != nil {
                let percent = isChromium ? nativeZoomPercent : browserManager.zoomManager.currentZoomPercentage
                SiteSettingRow(
                    icon: "plus.magnifyingglass",
                    title: "Zoom",
                    subtitle: percent.map { "\($0)%" } ?? "",
                    isOn: percent.map { $0 != 100 } ?? false,
                    action: nil
                ) {
                    HStack(spacing: NookDesign.Spacing.xxs) {
                        Button("Zoom Out", systemImage: "minus", action: zoomOut)
                        Button("Zoom In", systemImage: "plus", action: zoomIn)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.rowButton + NookDesign.Spacing.xs))
                }
                .task(id: currentTab?.itemID) { if isChromium { await refreshNativeZoom() } }
            }
        }
    }

    // MARK: - Site Toggles

    /// A private window leaves no record, and both lists below are saved for every profile.
    private var isPrivate: Bool { windowState.isIncognito }

    private func contentBlockerToggle(for host: String) -> (() -> Void)? {
        guard !isPrivate else { return nil }
        return {
            self.contentBlockerEnabled.toggle()
            self.browserManager.contentBlockerManager.allowDomain(host, allowed: !self.contentBlockerEnabled, from: self.currentTab)
        }
    }

    private func developerModeToggle(for host: String) -> (() -> Void)? {
        guard !isPrivate else { return nil }
        let developer = settings.isDeveloperSite(host)
        return { self.browserManager.setDeveloperSite(host, on: !developer, in: self.windowState) }
    }

    // MARK: - Footer

    private var footer: some View {
        let secure = currentTab?.url.scheme == "https"
        return HStack {
            Label(secure ? "Secure" : "Not Secure", systemImage: secure ? "lock.fill" : "lock.open.fill")
                .font(NookDesign.Font.body)
                .padding(.horizontal, NookDesign.Spacing.md)
                .frame(height: NookDesign.Size.row)
                .background(NookDesign.Surface.fillPressed, in: NookDesign.Radius.shape(NookDesign.Radius.md))
                .help(currentHost ?? "")

            Spacer()

            Menu {
                Button("Clear Cache") { clear(cache: true) }
                    .disabled(currentHost == nil)
                Button("Clear Cookies") { clear(cache: false) }
                    .disabled(currentHost == nil)
                Divider()
                Button("Manage Boosts…") {
                    browserManager.openBoostLibrary(in: windowState)
                    onDismiss()
                }
                .disabled(boostHost == nil)
                Button("New Boost…") {
                    browserManager.openBoostPanel(in: windowState)
                    onDismiss()
                }
                .disabled(boostHost == nil)
                Divider()
                Button("Manage Extensions…") {
                    browserManager.manageExtensions()
                    onDismiss()
                }
                Button("Add Extension…", action: openWebStore)
                if !isPrivate {
                    Divider()
                    Button("All Site Settings…", action: onShowMoreMenu)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: NookDesign.Size.spaceIcon, weight: .semibold))
                    .frame(width: NookDesign.Size.iconButton, height: NookDesign.Size.iconButton)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("More")
        }
    }

    /// Extensions come from the Chrome Web Store, whose pages get Nook's install button.
    private func openWebStore() {
        browserManager.tabs.open(url: Self.webStoreURL, in: windowState, placement: .newTab)
        onDismiss()
    }

    private static let webStoreURL = URL(string: "https://chromewebstore.google.com/category/extensions")!

    private func clear(cache: Bool) {
        guard let host = currentHost else { return }
        if isChromium {
            browserManager.perform(cache ? .clearSiteCache : .clearSiteCookies)
            onDismiss()
            return
        }
        Task {
            if cache {
                await browserManager.cacheManager?.clearCacheForDomain(host)
            } else {
                await browserManager.cookieManager?.deleteCookiesForDomain(host)
            }
        }
        onDismiss()
    }

    // MARK: - Zoom Helpers

    private func zoomIn() {
        if isChromium { browserManager.perform(.zoomIn); followNativeZoom(); return }
        guard let tab = currentTab, let webView = tab.webView else { return }
        browserManager.zoomManager.zoomIn(for: webView, tabId: tab.itemID)
    }

    private func zoomOut() {
        if isChromium { browserManager.perform(.zoomOut); followNativeZoom(); return }
        guard let tab = currentTab, let webView = tab.webView else { return }
        browserManager.zoomManager.zoomOut(for: webView, tabId: tab.itemID)
    }

    /// The renderer takes the new zoom a moment after the command.
    private func followNativeZoom() {
        Task { @MainActor in
            for delay in [100, 300] {
                try? await Task.sleep(for: .milliseconds(delay))
                await refreshNativeZoom()
            }
        }
    }

    /// The isolated world, so a page's own script cannot change what the row reads.
    private func refreshNativeZoom() async {
        guard let native = currentTab?.navigation as? ChromiumPageNavigation,
              let scale = windowState.window?.backingScaleFactor,
              let reply = try? await native.evaluateScript("devicePixelRatio", mode: .expression, world: .isolated),
              let ratio = Double(reply.json) else {
            nativeZoomPercent = nil
            return
        }
        nativeZoomPercent = ChromiumPageZoom.percent(devicePixelRatio: ratio, backingScale: Double(scale))
    }
}

// MARK: - Tiles

/// Arc's action tile: a raised key on the panel, pressing in a touch. The add tile sits flat.
private struct ActionTileStyle: ButtonStyle {
    var raised = true
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = NookDesign.Radius.shape(NookDesign.Radius.md)
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .background {
                if raised {
                    shape.fill(NookDesign.Surface.raised)
                        .overlay(shape.fill(configuration.isPressed || isHovering && isEnabled ? NookDesign.Surface.fill : .clear))
                        .overlay(shape.strokeBorder(NookDesign.Surface.hairline, lineWidth: NookDesign.Size.hairlineWidth))
                        .nookElevation(.raised)
                } else {
                    shape.fill(configuration.isPressed || isHovering && isEnabled ? NookDesign.Surface.fillPressed : NookDesign.Surface.fill)
                }
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(NookDesign.Motion.quick, value: configuration.isPressed)
            .animation(NookDesign.Motion.quick, value: isHovering)
            .onHoverTracking { isHovering = $0 }
    }
}

private struct ActionTileLabel: View {
    let systemImage: String
    var compact = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: compact ? NookDesign.Size.spaceIcon : NookDesign.Size.spaceIcon + 2, weight: .regular))
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity)
            .frame(height: NookDesign.Size.row)
    }
}

// MARK: - Mute Button (reactive to tab state)

private struct MuteButton: View {
    let tab: PageSession?

    var body: some View {
        let muted = tab?.isAudioMuted ?? false
        Button {
            tab?.toggleMute()
        } label: {
            ActionTileLabel(systemImage: muted ? "speaker.slash" : "speaker.wave.2")
        }
        .buttonStyle(ActionTileStyle())
        .help(muted ? "Unmute" : "Mute")
        .disabled(tab == nil)
    }
}

// MARK: - Extension Grid Item

private struct ExtensionGridItem: View {
    let ext: InstalledExtension
    let isPinned: Bool
    let browserManager: BrowserManager
    let windowState: BrowserWindowState
    let settings: NookSettingsService

    @State private var isHovering = false
    @State private var badgeText: String?

    private var currentTab: PageSession? {
        browserManager.tabs.selectedSession(in: windowState)
    }

    var body: some View {
        Button {
            triggerExtensionAction()
        } label: {
            Group {
                if let iconPath = ext.iconPath, let nsImage = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: NookDesign.Size.essentialsFavicon + 2, height: NookDesign.Size.essentialsFavicon + 2)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .font(NookDesign.Font.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: NookDesign.Size.essentialsTile)
            .overlay(alignment: .topTrailing) {
                if let badge = badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(NookDesign.Font.micro)
                        .foregroundStyle(.white)
                        .padding(.horizontal, NookDesign.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .padding(NookDesign.Spacing.xs)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(NookDesign.Font.micro)
                        .foregroundStyle(.secondary)
                        .padding(NookDesign.Spacing.xs)
                }
            }
        }
        .buttonStyle(ActionTileStyle())
        .help(ext.name)
        .onHoverTracking { isHovering = $0 }
        .onAppear { refreshBadge() }
        .contextMenu {
            if isPinned {
                Button("Unpin from URL Bar") {
                    settings.pinnedExtensionIDs.removeAll { $0 == ext.id }
                }
            } else {
                Button("Pin to URL Bar") {
                    settings.pinnedExtensionIDs.append(ext.id)
                }
            }
        }
        .accessibilityLabel(ext.name)
        .accessibilityHint("Extension. Double-tap to activate.")
        .accessibilityAddTraits(.isButton)
    }

    private func triggerExtensionAction() {
        guard let ctx = ExtensionManager.shared.getExtensionContext(for: ext.id) else { return }

        if ctx.webExtension.hasBackgroundContent {
            ctx.loadBackgroundContent { error in
                if let error { Logger(subsystem: "com.nook.browser", category: "ExtensionLibrary").error("Background wake failed: \(error.localizedDescription, privacy: .public)") }
            }
        }

        let adapter = ExtensionManager.shared.actionAdapter(in: windowState)
        ExtensionManager.shared.performAction(ctx, for: adapter)
    }

    private func refreshBadge() {
        guard let ctx = ExtensionManager.shared.getExtensionContext(for: ext.id) else {
            badgeText = nil
            return
        }
        let adapter = ExtensionManager.shared.actionAdapter(in: windowState)
        badgeText = ctx.action(for: adapter)?.badgeText
    }
}

// MARK: - Site Setting Row

/// Arc's settings row: a round icon, white when the setting is on, a title and its state.
/// Tapping the row flips it; a row with its own controls passes `action: nil`.
private struct SiteSettingRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool
    let action: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    @State private var isHovering = false
    private let iconSize: CGFloat = 32

    var body: some View {
        HStack(spacing: NookDesign.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: NookDesign.Size.spaceIcon, weight: .semibold))
                // Arc's round key: the glyph knocked out of the fill, which is darker when on.
                .foregroundStyle(NookDesign.Surface.windowBackground)
                .frame(width: iconSize, height: iconSize)
                .background(isOn ? Color.primary.opacity(0.8) : Color.primary.opacity(0.25), in: Circle())
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(NookDesign.Font.label)
                    .lineLimit(1)
                Text(subtitle)
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, NookDesign.Spacing.xs)
        .padding(.vertical, NookDesign.Spacing.xs)
        .background(isHovering && action != nil ? NookDesign.Surface.fill : .clear, in: NookDesign.Radius.shape(NookDesign.Radius.md))
        .contentShape(NookDesign.Radius.shape(NookDesign.Radius.md))
        .onHoverTracking { isHovering = $0 }
        .onTapGesture { withAnimation(NookDesign.Motion.quick) { action?() } }
        .animation(NookDesign.Motion.quick, value: isOn)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

extension SiteSettingRow where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String, isOn: Bool, action: (() -> Void)?) {
        self.init(icon: icon, title: title, subtitle: subtitle, isOn: isOn, action: action) { EmptyView() }
    }
}
