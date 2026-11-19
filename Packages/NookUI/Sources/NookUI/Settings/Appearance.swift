// Licensed under GPL-3.0. See LICENSE.
//
//  Appearance.swift
//  Nook
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import NookSettings
import SwiftUI

public struct SettingsAppearanceTab: View {
    @Environment(NookSettingsService.self) var nookSettings

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

            #if os(macOS)
            Section("Layout") {
                Toggle("Show Toolbar", isOn: $settings.topBarAddressView)
                Toggle("Show previews when hovering favorites", isOn: $settings.favoritePreviews)
                Toggle("Show unread mail on favorites", isOn: $settings.favoriteMeetingsAndMail)
                Toggle("Translucent space themes", isOn: $settings.themeTranslucency)
            }
            #endif
        }
        .formStyle(.grouped)
    }
}
