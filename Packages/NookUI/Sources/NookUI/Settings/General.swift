// Licensed under GPL-3.0. See LICENSE.
//
//  General.swift
//  Nook
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import SwiftUI
import NookDesign
import NookSettings
import NookWeb

public struct SettingsGeneralTab: View {
    @Environment(TabsController.self) private var tabs
    @State private var inactiveUnloadResult: InactiveUnloadResult?
    @Environment(NookSettingsService.self) var nookSettings
    @State private var showingAddSite = false
    @State private var showingAddEngine = false
    @State private var kagiSessionLink = ""
    @State private var newShortcutKeyword = ""
    @State private var newShortcutTemplate = ""
    private let updateControls: AnyView?

    public init() { updateControls = nil }

    public init<Content: View>(@ViewBuilder updateControls: () -> Content) {
        self.updateControls = AnyView(updateControls())
    }

    /// The provider list, shared by both platforms' spellings of the row.
    @ViewBuilder
    private func searchEnginePicker(_ settings: NookSettingsService) -> some View {
        @Bindable var settings = settings
        Picker("Initial search engine for new profiles", selection: $settings.searchEngineId) {
            ForEach(SearchProvider.allCases) { provider in
                Text(provider.displayName).tag(provider.rawValue)
            }
            ForEach(nookSettings.customSearchEngines) { engine in
                Text(engine.name).tag(engine.id.uuidString)
            }
        }
    }

    @ViewBuilder
    private var performanceSection: some View {
        @Bindable var settings = nookSettings
        Section {
            Picker("Tab Management", selection: $settings.tabManagementMode) {
                ForEach(TabManagementMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Picker("On Startup", selection: $settings.startupLoadMode) {
                ForEach(StartupLoadMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Button("Unload All Inactive Tabs") {
                inactiveUnloadResult = tabs.unloadAllHidden()
            }
            if let inactiveUnloadResult {
                Text(inactiveUnloadResult.presentationSummary)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("Selected tabs load first. On Startup permits background loading; Last Tab Only turns it off. Tab Management limits background loading without unloading tabs. Other tabs load when selected.")
                .settingsFooter()
        }
    }

    public var body: some View {
        @Bindable var settings = nookSettings
        Form {
            #if os(macOS)
            // Quitting and Sparkle updates are both macOS-only concepts.
            Section {
                DefaultBrowserRow()
                Toggle("Warn before quitting \(ProductDisplayName.current)", isOn: $settings.askBeforeQuit)
                if let updateControls { updateControls }
            }
            #endif

            Section {
                Toggle("Open new tabs ungrouped", isOn: $settings.newTabsAtTopLevel)
                Toggle("Nest link tabs under the page that opened them", isOn: $settings.nestLinkTabsUnderOpener)
                Picker("Archive tabs not seen for", selection: $settings.archiveTabsAfterHours) {
                    ForEach(NookSettingsService.archiveTabsAfterHoursChoices, id: \.self) { hours in
                        Text(hours < 24 ? "\(hours) hours" : hours == 24 ? "1 day" : "\(hours / 24) days").tag(hours)
                    }
                }
            } header: {
                Text("Tabs")
            } footer: {
                Text("Ungrouped tabs land below the selected tab's folder instead of inside it. Tabs opened from a pinned tab, a favorite or a folder always land in Tabs. Archived tabs can be reopened with Reopen Closed Tab; pinned tabs, favorites and tabs in folders are never archived.")
                    .settingsFooter()
            }

            Section {
                Toggle("Open a Peek window when clicking on links with Shift held", isOn: $settings.peekOnShiftClick)
            } header: {
                Text("Peek")
            } footer: {
                Text("Peek previews a link over the page without opening a new tab, for a quick look at a link from an email, an article or a post. Option-click always opens Peek.")
                    .settingsFooter()
            }

            performanceSection

            Section {
                LabeledContent("Initial search engine for new profiles") {
                    HStack(spacing: NookDesign.Spacing.md) {
                        searchEnginePicker(settings)
                            .labelsHidden()

                        Button {
                            showingAddEngine = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if nookSettings.kagiSessionToken != nil {
                    LabeledContent("Kagi Session Link") {
                        HStack(spacing: NookDesign.Spacing.md) {
                            Text("Saved in the Keychain")
                                .foregroundStyle(.secondary)
                            Button("Remove") { nookSettings.setKagiSession(nil) }
                        }
                    }
                } else {
                    LabeledContent("Kagi Session Link") {
                        HStack(spacing: NookDesign.Spacing.md) {
                            SecureField("https://kagi.com/search?token=…", text: $kagiSessionLink)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: NookDesign.Size.fieldWide)
                            Button("Save") {
                                nookSettings.setKagiSession(kagiSessionLink)
                                kagiSessionLink = ""
                            }
                            .disabled(KagiSession.token(fromPasted: kagiSessionLink) == nil)
                        }
                    }
                    Link("Find your Session Link in Kagi's account settings",
                         destination: URL(string: "https://kagi.com/settings/user_details")!)
                        .font(NookDesign.Font.caption)
                }

                if let selected = nookSettings.customSearchEngines.first(where: { $0.id.uuidString == nookSettings.searchEngineId }) {
                    LabeledContent {
                        Button("Remove") {
                            nookSettings.customSearchEngines.removeAll { $0.id == selected.id }
                            nookSettings.searchEngineId = SearchProvider.google.rawValue
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                    } label: {
                        Text(selected.name)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Search")
            }

            Section {
                ForEach(nookSettings.siteSearchEntries) { entry in
                    LabeledContent {
                        HStack(spacing: NookDesign.Spacing.md) {
                            Text(entry.domain)
                                .foregroundStyle(.secondary)
                            Button {
                                nookSettings.siteSearchEntries.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Label {
                            Text(entry.name)
                        } icon: {
                            Circle()
                                .fill(entry.color)
                                .frame(
                                    width: NookDesign.Size.statusDot,
                                    height: NookDesign.Size.statusDot
                                )
                        }
                    }
                }

                Button {
                    showingAddSite = true
                } label: {
                    Label("Add Site", systemImage: "plus")
                }

                Button("Reset to Defaults") {
                    nookSettings.siteSearchEntries = SiteSearchEntry.defaultSites
                }
            } header: {
                Text("Site Search")
            } footer: {
                Text("In the command palette, type the start of a site's name or domain, such as \u{201C}you\u{201D} for YouTube, and press Tab to search that site.")
                    .settingsFooter()
            }

            Section {
                ForEach(nookSettings.urlShortcuts) { shortcut in
                    LabeledContent(shortcut.keyword) {
                        HStack(spacing: NookDesign.Spacing.md) {
                            Text(shortcut.template)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                nookSettings.urlShortcuts.removeAll { $0.id == shortcut.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: NookDesign.Spacing.md) {
                    TextField("Keyword", text: $newShortcutKeyword)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: NookDesign.Size.fieldNarrow)
                    TextField("https://github.com/%@", text: $newShortcutTemplate)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        nookSettings.urlShortcuts.append(URLShortcut(
                            keyword: newShortcutKeyword.trimmingCharacters(in: .whitespaces),
                            template: newShortcutTemplate.trimmingCharacters(in: .whitespaces)))
                        newShortcutKeyword = ""
                        newShortcutTemplate = ""
                    }
                    .disabled(newShortcutKeyword.trimmingCharacters(in: .whitespaces).isEmpty
                              || newShortcutKeyword.contains(" ") || !newShortcutTemplate.contains("%@"))
                }
            } header: {
                Text("URL Shortcuts")
            } footer: {
                Text("Type a keyword, a space and the rest in the command palette, such as \"gh owner/repo\". %@ in the address stands for the rest.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Word stops") {
                    HStack(spacing: NookDesign.Spacing.md) {
                        TextField("Word stops", text: $settings.paletteWordStops)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                        Button("Reset") {
                            settings.paletteWordStops = NookSettingsService.defaultPaletteWordStops
                        }
                        .disabled(settings.paletteWordStops == NookSettingsService.defaultPaletteWordStops)
                    }
                }
            } header: {
                Text("Word Stops")
            } footer: {
                Text("In the command palette, \u{2325}\u{2192}, \u{2325}\u{232B} and Control-W move or delete up to these characters, and history search splits words at them. Letters, digits and spaces are ignored.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSite) {
            SiteSearchEntryEditor(entry: nil) { newEntry in
                nookSettings.siteSearchEntries.append(newEntry)
            }
        }
        .sheet(isPresented: $showingAddEngine) {
            CustomSearchEngineEditor { newEngine in
                nookSettings.customSearchEngines.append(newEngine)
            }
        }
    }
}

// MARK: - Custom Search Engine Editor

struct CustomSearchEngineEditor: View {
    let onSave: (CustomSearchEngine) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlTemplate: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.xl) {
            Text("Add Custom Search Engine")
                .font(NookDesign.Font.heading)

            Form {
                Section {
                    TextField("Name (e.g. Startpage)", text: $name)
                    TextField("URL Template (use %@ for query)", text: $urlTemplate)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    let engine = CustomSearchEngine(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        urlTemplate: urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onSave(engine)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || urlTemplate.isEmpty)
            }
        }
        .padding(NookDesign.Spacing.xxl)
        .frame(width: NookDesign.Size.sheetSmallWidth)
    }
}

#if os(macOS)
private struct DefaultBrowserRow: View {
    @State private var isNook = DefaultBrowser.isNook

    var body: some View {
        LabeledContent("Default browser") {
            if isNook {
                Label(ProductDisplayName.current, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button("Make \(ProductDisplayName.current) Default") { DefaultBrowser.makeNook { isNook = $0 } }
            }
        }
        // The default can change in System Settings while Nook is in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isNook = DefaultBrowser.isNook
        }
    }
}
#endif
