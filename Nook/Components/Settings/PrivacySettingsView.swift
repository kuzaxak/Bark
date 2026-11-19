// Licensed under GPL-3.0. See LICENSE.
//
//  PrivacySettingsView.swift
//  Nook
//
//  Created by Jonathan Caudill on 15/08/2025.
//

import SwiftUI
import NookDesign
import NookSettings
import NookWeb

/// The sections both engines share. Only WebKit pages read fingerprinting, link cleaning and the HTTP warning.
private struct PrivacyPreferenceSections: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(\.nookSettings) var nookSettings
    @State private var showVaultOpenFailure = false

    var body: some View {
        @Bindable var settings = nookSettings

        if browserManager.engine == .webKit {
            Section("Tracking") {
                scopePicker(
                    "Enhanced fingerprinting protection",
                    detail: "Makes it harder for websites to recognize your Mac and follow you around the web. If a site breaks, turn it off in Site Controls until you leave that site.",
                    selection: $settings.enhancedFingerprintingProtection
                )
                scopePicker(
                    "Remove tracking from links",
                    detail: "Removes tracking added to links, so advertisers can't see which link brought you to a site.",
                    selection: $settings.removeTrackingFromLinks
                )
                .onChange(of: nookSettings.removeTrackingFromLinks) {
                    browserManager.contentBlockerManager.prepareLinkCleaning()
                }
            }
        }

        if browserManager.engine == .webKit {
            Section("Security") {
                settingToggle(
                    "Warn before opening a site over HTTP",
                    detail: "\(ProductDisplayName.current) always tries HTTPS first. Ask before opening a site that only works over HTTP.",
                    isOn: $settings.warnBeforeHTTP
                )
                settingToggle(
                    "Security keys (USB)",
                    detail: "Sign in and create passkeys with a hardware key, such as a YubiKey, plugged into this Mac.",
                    isOn: $settings.securityKeysEnabled
                )
            }
        }

        Section("Passwords") {
            let vault = browserManager.tabs.vault
            let launchProvider = vault?.pawlEnabledAtLaunch
            settingToggle(
                "Use Pawl Vault for passwords and passkeys",
                detail: launchProvider != nil
                    ? "Quit and reopen Bark to change password providers."
                    : "Fill and save passwords and sign in with passkeys when Pawl Vault is connected.",
                isOn: $settings.pawlVaultEnabled
            )
            if let launchProvider, launchProvider != nookSettings.pawlVaultEnabled {
                Text(launchProvider
                     ? "Pawl Vault is the current provider until you reopen Bark."
                     : "Chromium’s password manager is the current provider until you reopen Bark.")
                    .foregroundStyle(.secondary)
            } else if launchProvider == nil && browserManager.engine == .chromium {
                Text("In this version of Bark, Pawl Vault works alongside Chromium’s password manager.")
                    .foregroundStyle(.secondary)
            }
            if let vault, vault.isEnabled {
                LabeledContent("Status") {
                    vaultStatus(vault.status)
                }
                // While this pane shows, follow the vault: unlocking happens there.
                .task {
                    while !Task.isCancelled {
                        await vault.refresh()
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
                Button("Open Pawl Vault") {
                    showVaultOpenFailure = !vault.openPawlVault()
                }
                .alert("Open Pawl Vault from Applications", isPresented: $showVaultOpenFailure) {
                    Button("OK") {}
                } message: {
                    Text("Bark couldn’t open a verified copy of Pawl Vault. Open the edition that holds your database, then return here to check its status.")
                }
            }
        }

        Section("History") {
            settingToggle(
                "Search page text in history",
                detail: "Turning this off erases saved page text.",
                isOn: $settings.searchPageTextInHistory
            )
            .onChange(of: nookSettings.searchPageTextInHistory) { _, enabled in
                if !enabled { browserManager.historyManager.erasePageText() }
            }
            Picker(selection: $settings.historyHalfLifeDays) {
                ForEach(Set(NookSettingsService.historyHalfLifeDaysChoices + [nookSettings.historyHalfLifeDays]).sorted(), id: \.self) { days in
                    Text(days == 7 ? "1 week" : days == 14 ? "2 weeks" : days == 30 ? "1 month" : days == 60 ? "2 months" : "\(days) days").tag(days)
                }
            } label: {
                VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                    Text("Rank recent visits higher")
                    Text("A visit counts half as much in command bar results after this long.")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: nookSettings.historyHalfLifeDays) { _, days in
                browserManager.historyManager.setHalfLife(days: days)
            }
        }
    }

    private func vaultStatus(_ status: VaultStatus?) -> some View {
        let (text, color): (String, Color) = switch status {
        case nil: ("Checking…", .secondary)
        case .connected: ("Connected", .green)
        case .locked: ("Vault locked", .orange)
        case .notTeamSigned: ("Pawl Vault refused this browser. Use a signed build of \(ProductDisplayName.current) and a compatible version of Pawl Vault.", .red)
        case .notRunning: ("Pawl Vault is unavailable. Open Pawl Vault and try again.", .secondary)
        case .notPawlVault: ("\(ProductDisplayName.current) could not verify Pawl Vault’s signature.", .red)
        }
        return HStack(spacing: NookDesign.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: NookDesign.Size.statusDot, height: NookDesign.Size.statusDot)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private func settingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            settingLabel(title, detail: detail)
        }
    }

    private func scopePicker(_ title: String, detail: String, selection: Binding<ProtectionScope>) -> some View {
        LabeledContent {
            // Hidden copies hold the widest option's width, so the text beside it doesn't reflow.
            ZStack(alignment: .trailing) {
                ForEach(ProtectionScope.allCases) { scope in
                    scopeMenu(title, selection: .constant(scope))
                        .hidden()
                }
                scopeMenu(title, selection: selection)
            }
            .fixedSize()
        } label: {
            settingLabel(title, detail: detail)
        }
    }

    private func scopeMenu(_ title: String, selection: Binding<ProtectionScope>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ProtectionScope.allCases) { scope in
                Text(scope.displayName).tag(scope)
            }
        }
        .labelsHidden()
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
            Text(title)
            Text(detail)
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Chromium keeps cookies and cache per profile, so they are cleared from the Profiles tab.
struct ChromiumPrivacySettingsView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @State private var pageError: ProfilePageOpenError?

    var body: some View {
        let profile = browserManager.tabs.displayedHistoryProfile(browserManager.historyManager)
        Form {
            PrivacyPreferenceSections()

            Section {
                LabeledContent("Browsing history") {
                    if let profile {
                        Text(profile.name)
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear History") { clearHistory(profileID: profile?.id) }
                        .disabled(profile == nil)
                }
                LabeledContent("Cookies and cache") {
                    Button("Open Profiles") { SettingsNavigation.shared.currentSettingsTab = .profiles }
                }
            } header: {
                Text("Website Data")
            } footer: {
                Text("Clear History opens Chromium’s Delete Browsing Data for the profile shown here. After the controls open, Bark clears that profile’s sidebar and command bar history.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .alert("Delete Browsing Data", isPresented: Binding(get: { pageError != nil }, set: { if !$0 { pageError = nil } })) {
            Button("OK") { pageError = nil }
        } message: {
            Text(pageError?.localizedDescription ?? "")
        }
    }

    private func clearHistory(profileID: UUID?) {
        browserManager.tabs.clearDisplayedProfileHistory(profileID, history: browserManager.historyManager) { result in
            if case .failure(let error) = result { pageError = error }
        }
    }
}
