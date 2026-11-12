// Licensed under GPL-3.0. See LICENSE.
//
//  Appearance.swift
//  Nook
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import NookSettings
import NookWeb
import SwiftUI

public struct SettingsAppearanceTab: View {
    @Environment(NookSettingsService.self) var nookSettings
    @Environment(TabsController.self) private var tabs

    public init() {}

    public var body: some View {
        @Bindable var settings = nookSettings
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            // Every row here is about the Mac window: a sidebar side, the
            // floating URL bar, and a hover preview. None has a touch meaning.
            #if os(macOS)
            Section("Layout") {
                if shows(.sidebarPosition) {
                    Picker("Sidebar Position", selection: $settings.sidebarPosition) {
                        ForEach(SidebarPosition.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                }
                Toggle("Show URL bar in the web view", isOn: $settings.topBarAddressView)
                if shows(.linkStatusPreview) {
                    Toggle("Preview link URL on hover", isOn: $settings.showLinkStatusBar)
                }
                Toggle("Show previews when hovering favorites", isOn: $settings.favoritePreviews)
                Toggle(tabs.profileEngine == .chromium ? "Show unread mail on favorites" : "Show meetings and mail on favorites",
                       isOn: $settings.favoriteMeetingsAndMail)
                Toggle("Translucent space themes", isOn: $settings.themeTranslucency)
                if shows(.hideBorder) {
                    Toggle("Hide border", isOn: $settings.hideWebContentBorder)
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }

    private func shows(_ control: SettingsControl) -> Bool {
        control.isShown(chromium: tabs.profileEngine == .chromium)
    }
}
