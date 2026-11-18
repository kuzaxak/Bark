// Licensed under GPL-3.0. See LICENSE.
//
//  Shortcuts.swift
//  Nook
//
//  Created by Maciek Bagiński on 03/08/2025.
//

import SwiftUI
import NookSettings
import NookDesign
import NookUI

struct ShortcutsSettingsView: View {
    @State private var searchText = ""
    @Environment(KeyboardShortcutManager.self) var keyboardShortcutManager

    private var shortcutsByCategory: [ShortcutCategory: [KeyboardShortcut]] {
        let chromium = keyboardShortcutManager.browserManager?.tabs.profileEngine == .chromium
        let matching = keyboardShortcutManager.shortcuts.filter {
            $0.action.isOffered(chromium: chromium, privateWindow: false) &&
                (searchText.isEmpty || $0.action.displayName.localizedCaseInsensitiveContains(searchText))
        }
        return Dictionary(grouping: matching, by: { $0.action.category })
    }

    private var detectsWebsiteShortcuts: Bool {
        SettingsControl.websiteShortcutDetection.isShown(chromium: keyboardShortcutManager.browserManager?.tabs.profileEngine == .chromium)
    }

    var body: some View {
        Form {
            Section {
                SidebarMenuSearchField(prompt: "Search shortcuts...", text: $searchText)

                if detectsWebsiteShortcuts {
                    Toggle("Detect Website Shortcuts", isOn: Binding(
                        get: { WebsiteShortcutProfile.isFeatureEnabled },
                        set: { WebsiteShortcutProfile.isFeatureEnabled = $0 }
                    ))
                }
            } footer: {
                if detectsWebsiteShortcuts {
                    Text("When a website uses the same shortcut, press once for the website, twice for \(ProductDisplayName.current).")
                        .settingsFooter()
                }
            }

            ForEach(ShortcutCategory.allCases, id: \.self) { category in
                if let categoryShortcuts = shortcutsByCategory[category], !categoryShortcuts.isEmpty {
                    Section(category.displayName) {
                        ForEach(categoryShortcuts, id: \.action) { shortcut in
                            ShortcutRowView(shortcut: shortcut)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        keyboardShortcutManager.resetToDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcut Row

private struct ShortcutRowView: View {
    let shortcut: KeyboardShortcut
    @Environment(KeyboardShortcutManager.self) var keyboardShortcutManager

    private var keys: KeyCombination? {
        shortcut.isEnabled && !shortcut.keyCombination.key.isEmpty && shortcut.action.showsKey(shortcut.keyCombination,
            chromium: keyboardShortcutManager.browserManager?.tabs.profileEngine == .chromium) ? shortcut.keyCombination : nil
    }

    var body: some View {
        HStack {
            Text(shortcut.action.displayName)
            Spacer()
            if shortcut.isCustomizable {
                ShortcutRecorderView(
                    keyCombination: keys,
                    action: shortcut.action,
                    shortcutManager: keyboardShortcutManager,
                    onRecord: { keyboardShortcutManager.updateShortcut(action: shortcut.action, keyCombination: $0) }
                )
            } else {
                Text(keys?.displayString ?? "(none)")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
