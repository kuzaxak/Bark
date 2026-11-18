// Licensed under GPL-3.0. See LICENSE.
//
//  TopBarView.swift
//  Nook
//
//  Created by Reynold on 23/09/2025.
//

import AppKit
import SwiftUI
import NookDesign
import NookWeb
import NookUI

enum TopBarMetrics {
    static let height: CGFloat = 40
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 5
}

struct TopBarView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.nookSettings) var nookSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering: Bool = false
    @State private var previousTabId: UUID? = nil

    var body: some View {
        let cornerRadius: CGFloat = nookSettings.hideWebContentBorder ? 0 : NookDesign.Radius.page

        ZStack {
            // Main content
            ZStack {
                HStack(spacing: 8) {
                    if browserManager.engine == .chromium, !windowState.isSidebarVisible {
                        Button("Toggle Sidebar", systemImage: "sidebar.left") {
                            browserManager.toggleSidebar(for: windowState)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(NookIconButtonStyle())
                    }
                    SidebarHistoryButtons(atTop: true)

                    if browserManager.engine == .chromium {
                        URLBarView(isSidebarHovered: false, nativeTopBar: true)
                    } else {
                        urlBar
                    }

                    Spacer()

                    if browserManager.nookSettings?.showAIAssistant ?? false
                        && !windowState.isSidebarAIChatVisible
                    {
                        ChatButton()
                    }

                }

            }
            // Text and symbols follow the page colour behind them, not the app's appearance.
            .environment(\.colorScheme, pageColor.map { $0.isPerceivedDark ? .dark : .light } ?? colorScheme)
            .padding(.horizontal, TopBarMetrics.horizontalPadding)
            .padding(.vertical, TopBarMetrics.verticalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: TopBarMetrics.height)
            .background(topBarBackgroundColor)
            .animation(
                shouldAnimateColorChange ? NookDesign.Motion.standard : nil,
                value: topBarBackgroundColor
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: cornerRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: cornerRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .bottom) {
                // 1px bottom border - lighter when dark, darker when light
                Rectangle()
                    .fill(bottomBorderColor)
                    .frame(height: 1)
                    .animation(
                        shouldAnimateColorChange
                            ? NookDesign.Motion.standard : nil,
                        value: bottomBorderColor
                    )
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(
                        key: URLBarFramePreferenceKey.self,
                        value: geometry.frame(in: .named("WindowSpace"))
                    )
            }
        )
        .onAppear {
            // Initialize previousTabId to the selection so the first color change doesn't animate
            previousTabId = windowState.selectedItemID
        }
        .onChange(of: windowState.selectedItemID) { oldId, newId in
            previousTabId = oldId
            // Update previousTabId after a brief delay so the next color change within this page animates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                previousTabId = newId
            }
        }
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            if browserManager.tabs.selectedSession(in: windowState) != nil {
                // URL text area — tappable to open command palette
                // Two texts so a narrow bar cuts the path or title first and then the host's
                // head: `accounts.google.com.x.evil.tld` must keep `evil.tld`.
                HStack(spacing: 0) {
                    Text(displayURL.host)
                        .truncationMode(.head)
                        .layoutPriority(1)
                    Text(displayURL.rest)
                        .truncationMode(.tail)
                }
                    .font(NookDesign.Font.body)
                    .foregroundStyle(.primary)
                    .tracking(-0.1)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let currentTab = browserManager.tabs.selectedSession(in: windowState) {
                            commandPalette.openWithCurrentURL(currentTab.url)
                        } else {
                            commandPalette.open()
                        }
                    }

                Button("Copy URL", systemImage: "link") {
                    if let page = browserManager.tabs.controllableSession(in: windowState) { browserManager.copyURL(of: page, in: windowState) }
                }
                    .labelStyle(.iconOnly)
                    .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.iconButton, radius: NookDesign.Radius.sm))
                    .help(browserManager.help("Copy URL", shortcut: .copyCurrentURL))
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)

                // Pinned extension buttons + library button (not covered by tap gesture)
                if let extensionManager = browserManager.extensionManager {
                    let pinnedIDs = browserManager.nookSettings?.pinnedExtensionIDs ?? []
                    let pinnedExtensions = extensionManager.installedExtensions.filter { pinnedIDs.contains($0.id) }

                    if !pinnedExtensions.isEmpty {
                        ExtensionActionView(extensions: pinnedExtensions)
                            .environmentObject(browserManager)
                    }

                    ExtensionLibraryButton()
                        .environmentObject(browserManager)
                        .onAppear {
                            let installedIDs = extensionManager.installedExtensions
                                .filter { $0.isEnabled }
                                .map { $0.id }
                            browserManager.nookSettings?.migrateExtensionPinStateIfNeeded(installedExtensionIDs: installedIDs)
                        }
                }
            } else {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(urlBarBackgroundColor)
        .animation(
            shouldAnimateColorChange ? NookDesign.Motion.standard : nil,
            value: urlBarBackgroundColor
        )
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
        // SwiftUI's hover, not the tracking-area one: the bar lies under the window's unified
        // toolbar, where an NSTrackingArea loses the pointer partway across.
        .onHover { hovering in
            withAnimation(NookDesign.Motion.quick) {
                isHovering = hovering
            }
        }
    }

    // Determine if we should animate color changes (within same tab) or snap (tab switch)
    private var shouldAnimateColorChange: Bool {
        let selectedItemID = browserManager.tabs.selectedSession(in: windowState)?.id
        return selectedItemID == previousTabId
    }

    /// The colour the page reports for its top edge, else its background; nil before it loads.
    private var pageColor: NSColor? {
        let session = browserManager.engine == .chromium
            ? browserManager.frontPage(in: windowState)
            : browserManager.tabs.selectedSession(in: windowState)
        return session?.topBarBackgroundColor ?? session?.pageBackgroundColor
    }

    private var topBarBackgroundColor: Color {
        pageColor.map { Color(nsColor: $0) } ?? Color(nsColor: .windowBackgroundColor)
    }

    // URL bar background color - slightly adjusted for visual distinction
    private var urlBarBackgroundColor: Color {
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            let baseColor = Color(nsColor: topBarColor)
            if isHovering {
                // Slightly lighter/darker on hover
                return adjustColorBrightness(
                    baseColor,
                    factor: topBarColor.isPerceivedDark ? 1.15 : 0.95
                )
            } else {
                // Slightly darker/lighter for subtle distinction from top bar
                //                return adjustColorBrightness(baseColor, factor: topBarColor.isPerceivedDark ? 1.1 : 0.98)
                return .clear
            }
        }
        // Fallback to page background color
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            let baseColor = Color(nsColor: pageColor)
            if isHovering {
                // Slightly lighter/darker on hover
                return adjustColorBrightness(
                    baseColor,
                    factor: pageColor.isPerceivedDark ? 1.15 : 0.95
                )
            } else {
                // Slightly darker/lighter for subtle distinction from top bar
                return adjustColorBrightness(
                    baseColor,
                    factor: pageColor.isPerceivedDark ? 1.1 : 0.98
                )
            }
        }
        // Fallback to a surface token when no webview color available
        return isHovering ? NookDesign.Surface.fillPressed : NookDesign.Surface.fill
    }

    // Bottom border color - lighter when dark, darker when light
    private var bottomBorderColor: Color {
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            let baseColor = Color(nsColor: topBarColor)
            // Make lighter if dark, darker if light
            return adjustColorBrightness(
                baseColor,
                factor: topBarColor.isPerceivedDark ? 1.2 : 0.85
            )
        }
        // Fallback to page background color
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            let baseColor = Color(nsColor: pageColor)
            return adjustColorBrightness(
                baseColor,
                factor: pageColor.isPerceivedDark ? 1.2 : 0.85
            )
        }
        // Fallback to system separator color
        return Color(nsColor: .separatorColor)
    }

    // Helper to adjust color brightness
    private func adjustColorBrightness(_ color: Color, factor: CGFloat) -> Color
    {
        #if canImport(AppKit)
            guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else {
                return color
            }
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)

            // Clamp values between 0 and 1
            r = min(1.0, max(0.0, r * factor))
            g = min(1.0, max(0.0, g * factor))
            b = min(1.0, max(0.0, b * factor))

            return Color(
                nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            )
        #else
            return color
        #endif
    }

    private var displayURL: (host: AttributedString, rest: AttributedString) {
        guard let currentTab = browserManager.tabs.selectedSession(in: windowState)
        else {
            return ("", "")
        }

        return formatURL(
            currentTab.url,
            title: currentTab.title,
            isHovering: isHovering
        )
    }

    /// The host apart from what follows it, so each can truncate its own way.
    private func formatURL(_ url: URL, title: String?, isHovering: Bool)
        -> (host: AttributedString, rest: AttributedString)
    {
        if isHovering {
            guard let host = url.host else {
                return (AttributedString(url.absoluteString), "")
            }

            let cleanHost =
                host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

            let hostString = AttributedString(cleanHost)

            var pathString = AttributedString()

            if !url.path.isEmpty {
                pathString += AttributedString(url.path)
            }

            if let query = url.query {
                pathString += AttributedString("?" + query)
            }

            pathString.foregroundColor = .secondary

            return (hostString, pathString)
        }

        guard let host = url.host else {
            return (AttributedString(url.absoluteString), "")
        }

        let cleanHost =
            host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        if url.path.isEmpty || url.path == "/" {
            return (AttributedString(cleanHost), "")
        } else {
            let displayTitle = title ?? cleanHost
            var titlePart = AttributedString(" / " + displayTitle)
            titlePart.foregroundColor = .secondary
            return (AttributedString(cleanHost), titlePart)
        }
    }
}

struct ChatButton: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            browserManager.toggleAISidebar(for: windowState)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "message.fill")
                Text("Chat")
            }
            .font(NookDesign.Font.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(backgroundColor)
            .clipShape(
                NookDesign.Radius.shape(NookDesign.Radius.sm)
            )
            .contentShape(
                NookDesign.Radius.shape(NookDesign.Radius.sm)
            )
        }
        .buttonStyle(.plain)
        .onHoverTracking { state in
            isHovered = state
        }

    }
    
    private var backgroundColor: Color {
        let isDark = browserManager.tabs.selectedSession(in: windowState)?.topBarBackgroundColor?.isPerceivedDark == true
        if isHovered {
            return isDark ? .white.opacity(0.15) : .black.opacity(0.1)
        } else {
            return isDark ? .white.opacity(0.1) : .black.opacity(0.05)
        }
    }

}
