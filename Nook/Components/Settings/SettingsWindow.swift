// Licensed under GPL-3.0. See LICENSE.
//
//  SettingsWindow.swift
//  Nook
//
//  Created by Bain Gurley on 26/03/2026.
//

import SwiftUI
import NookDesign
import NookUI

struct SettingsWindow: View {
    var updater: ChromiumAppUpdater?
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var gradientColorManager: GradientColorManager
    @Environment(\.nookSettings) var nookSettings

    private let windowSize = CGSize(width: 780, height: 540)
    @State private var query = ""

    @State private var back: [SettingsTabs] = []
    @State private var forward: [SettingsTabs] = []
    @State private var restoring = false

    var body: some View {
        @Bindable var navigation = SettingsNavigation.shared
        let tab = navigation.currentSettingsTab
        // A fixed sidebar beside the page, not a NavigationSplitView, whose sidebar is glass.
        HStack(spacing: 0) {
            SettingsSidebar(selection: $navigation.currentSettingsTab, query: $query)
            Divider()
            SettingsDetailPane(
                tab: tab,
                updater: updater,
                history: HistoryToolbar(
                    canGoBack: !back.isEmpty,
                    canGoForward: !forward.isEmpty,
                    goBack: { go(from: &back, to: &forward) },
                    goForward: { go(from: &forward, to: &back) }
                )
            )
            .environmentObject(browserManager)
            .environmentObject(gradientColorManager)
            // Rebuilds the pane per tab so each opens scrolled to the top.
            .id(tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: tab) { old, _ in
            if restoring { restoring = false; return }
            // A fresh move abandons the forward history, like a browser.
            back.append(old)
            forward.removeAll()
        }
        // System Settings is resizable and remembers its size; a fixed frame is not.
        .frame(minWidth: windowSize.width, minHeight: windowSize.height)
        .toggleStyle(SettingsSwitch())
        .background(UnifiedToolbarWindow())
    }

    private func go(from stack: inout [SettingsTabs], to other: inout [SettingsTabs]) {
        guard let target = stack.popLast() else { return }
        other.append(SettingsNavigation.shared.currentSettingsTab)
        restoring = true
        SettingsNavigation.shared.currentSettingsTab = target
    }
}

/// System Settings' switches measure 44x20, which is `.small`; a grouped Form's default
/// renders them at the mini size. Scoped to switches so buttons and pickers stay regular.
private struct SettingsSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// Both buttons always show, disabled when there is nowhere to go, as standalone icon buttons
/// with the toolbar's glass backing hidden.
private struct HistoryToolbar: ViewModifier {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        // Branch at the View level: ToolbarContentBuilder's availability erasure fails
        // to link in optimized builds with the Xcode 26.3 SDK.
        if #available(macOS 26, *) {
            content.toolbar { buttons.sharedBackgroundVisibility(.hidden) }
        } else {
            content.toolbar { buttons }
        }
    }

    private var buttons: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: NookDesign.Spacing.xxs) {
                Button("Back", systemImage: "chevron.backward", action: goBack)
                    .accessibilityLabel("Back")
                    .disabled(!canGoBack)
                Button("Forward", systemImage: "chevron.forward", action: goForward)
                    .accessibilityLabel("Forward")
                    .disabled(!canGoForward)
            }
            .nookIconButtons()
            // Keep each control's label when AppKit hosts this group as a toolbar item.
            .accessibilityElement(children: .contain)
        }
    }
}

/// The Settings scene ignores `.windowToolbarStyle` and lays its toolbar out in the old two-row
/// preference style. System Settings' single row (back button, then the title inline, traffic
/// lights 26pt in from the corner) needs the style set on the window itself.
private struct UnifiedToolbarWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI installs the toolbar after the view lands, so wait one turn.
            guard let window else { return }
            DispatchQueue.main.async { window.toolbarStyle = .unified }
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsTabs
    @Binding var query: String

    private let sidebarWidth: CGFloat = 230

    var body: some View {
        VStack(spacing: NookDesign.Spacing.md) {
            SidebarMenuSearchField(prompt: "Search", text: $query)
            ScrollView {
                VStack(alignment: .leading, spacing: NookDesign.Spacing.rowGap) {
                    ForEach(Array(SettingsTabs.sidebarGroups.enumerated()), id: \.offset) { _, group in
                        let tabs = group.tabs.filter { $0.matches(query) }
                        if !tabs.isEmpty {
                            // A group header reads as a filter label while searching, so it goes.
                            if let title = group.title, query.isEmpty {
                                Text(title)
                                    .font(NookDesign.Font.captionStrong)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, NookDesign.Spacing.rowPadding)
                                    .padding(.top, NookDesign.Spacing.sectionGap)
                            }
                            ForEach(tabs, id: \.self) { tab in
                                SettingsSidebarRow(tab: tab, isSelected: selection == tab) {
                                    selection = tab
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(NookDesign.Spacing.sidebarInset)
        .frame(width: sidebarWidth)
    }
}

/// A settings tab in the sidebar, drawn like a sidebar tab row.
private struct SettingsSidebarRow: View {
    let tab: SettingsTabs
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookDesign.Spacing.md) {
                Image(systemName: tab.icon)
                    .imageScale(.small)
                    .foregroundStyle(.white)
                    .frame(width: NookDesign.Size.settingsChip, height: NookDesign.Size.settingsChip)
                    .background(NookDesign.Radius.shape(NookDesign.Radius.sm).fill(tab.iconColor.gradient))
                Text(tab.name)
                    .font(NookDesign.Font.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NookDesign.Spacing.rowPadding)
            .frame(height: NookDesign.Size.row)
            .contentShape(NookDesign.Radius.shape(NookDesign.Radius.md))
            .background(!isSelected && isHovering ? NookDesign.Surface.fill : .clear, in: NookDesign.Radius.shape(NookDesign.Radius.md))
            .nookRowSelection(isSelected)
            .nookElevation(isSelected ? .raised : .flat)
        }
        .buttonStyle(.plain)
        .animation(NookDesign.Motion.quick, value: isHovering)
        .onHoverTracking { isHovering = $0 }
    }
}

// MARK: - Detail Pane

private struct SettingsDetailPane: View {
    let tab: SettingsTabs
    let updater: ChromiumAppUpdater?
    let history: HistoryToolbar

    var body: some View {
        NavigationStack {
            tabPage
                .navigationTitle(tab.name)
                .modifier(history)
        }
    }

    @ViewBuilder
    private var tabPage: some View {
        switch tab {
        case .general:
            SettingsGeneralTab {
                updater?.automaticUpdateControls
            }
        case .appearance:
            SettingsAppearanceTab()
        case .ai:
            SettingsAITab()
        case .privacy:
            ChromiumPrivacySettingsView()
        case .adBlocker:
            SettingsAdBlockerTab()
        case .tweaks:
            SettingsTweaksTab()
        case .airTrafficControl:
            AirTrafficControlSettingsView()
        case .spaces:
            SpacesSettingsView()
        case .profiles:
            ProfilesSettingsView {
                SettingsNavigation.shared.currentSettingsTab = .privacy
            }
        case .shortcuts:
            ShortcutsSettingsView()
        case .developer:
            SettingsDeveloperTab()
        }
    }
}
