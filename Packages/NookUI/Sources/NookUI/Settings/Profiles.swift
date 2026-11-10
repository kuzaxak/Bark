// Licensed under GPL-3.0. See LICENSE.
//
//  Profiles.swift
//  Nook
//
//  Profiles, as Arc lays them out: the list beside the chosen profile's search engine, download
//  location and website data. Which profile a space uses is set in Spaces.
//

import NookDesign
import NookSettings
import NookTabsCore
import NookWeb
import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct ProfilesSettingsView: View {
    @Environment(TabsController.self) private var tabs
    @State private var selection: UUID?
    @State private var pendingDelete: ProfileSummary?
    @State private var deletionError: ProfileDeletionError?
    @State private var profilePageError: ProfilePageOpenError?

    public init() {}

    private var selected: ProfileSummary? {
        tabs.profiles.first { $0.id == selection } ?? tabs.profiles.first
    }

    public var body: some View {
        content
            .alert("Couldn’t Delete Profile", isPresented: Binding(
                get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK") { deletionError = nil }
            } message: {
                if tabs.device.pendingProfileDeletion?.change?.kind == .reassignSpace {
                    Text("The profile change is incomplete. You can retry it.")
                } else if tabs.device.pendingProfileDeletion != nil {
                    Text("Deletion is incomplete. This profile is unavailable until cleanup succeeds. You can retry deletion.")
                } else {
                    Text("The profile could not be deleted. Its data has been kept.")
                }
            }
            .alert("Couldn’t Open Profile Controls", isPresented: Binding(
                get: { profilePageError != nil },
                set: { if !$0 { profilePageError = nil } }
            )) {
                Button("OK") { profilePageError = nil }
            } message: {
                Text(profilePageError?.localizedDescription ?? "")
            }
            .alert(
                "Delete the \u{201C}\(pendingDelete?.name ?? "")\u{201D} profile?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
            ) {
                Button("Delete Profile", role: .destructive) {
                    if let profile = pendingDelete { delete(profile) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if pendingDelete?.spaceIDs.isEmpty == true {
                    Text("No space uses it. Its logins, cookies and history are deleted.")
                } else {
                    Text("Its spaces move to \u{201C}\(heir(of: pendingDelete)?.name ?? "")\u{201D}. Its logins, cookies and history are deleted.")
                }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A profile keeps its own logins, cookies and history. Each space uses one profile, and several spaces can share it.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, NookDesign.Spacing.xxl)
                .padding(.top, NookDesign.Spacing.xxl)
            HStack(alignment: .top, spacing: 0) {
                profileList
                    .frame(width: NookDesign.Size.profileList)
                    .padding(.leading, NookDesign.Spacing.xxl)
                    .padding(.vertical, NookDesign.Spacing.xxl)
                if let profile = selected {
                    ProfileDetailForm(profile: profile, profilePageError: $profilePageError)
                        .id(profile.id)
                        .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private var profileList: some View {
        let shape = NookDesign.Radius.shape(NookDesign.Radius.md)
        return VStack(spacing: 0) {
            Text("Your Profiles")
                .font(NookDesign.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NookDesign.Spacing.lg)
                .padding(.vertical, NookDesign.Spacing.md)
            ScrollView {
                VStack(spacing: NookDesign.Spacing.rowGap) {
                    ForEach(tabs.profiles) { profile in
                        Button { selection = profile.id } label: {
                            HStack {
                                Text(profile.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(spaceCount(profile))
                                    .font(NookDesign.Font.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, NookDesign.Spacing.md)
                            .frame(height: NookDesign.Size.row)
                            .contentShape(Rectangle())
                            .nookRowSelection(profile.id == selected?.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, NookDesign.Spacing.sm)
            }
            Divider()
            HStack(spacing: 0) {
                Button(action: addProfile) {
                    Image(systemName: "plus")
                        .frame(width: NookDesign.Size.rowButton + NookDesign.Spacing.xs, height: NookDesign.Size.rowButton)
                }
                .help("New Profile")
                Divider()
                    .frame(height: NookDesign.Size.favicon)
                Button {
                    if tabs.device.pendingProfileDeletion?.change != nil,
                       tabs.device.pendingProfileDeletion?.target == selected?.id {
                        tabs.retryPendingProfileChange { result in
                            if case .failure(let error) = result, error != .cancelled { deletionError = error }
                        }
                    } else { pendingDelete = selected }
                } label: {
                    Image(systemName: tabs.device.pendingProfileDeletion?.change != nil &&
                          tabs.device.pendingProfileDeletion?.target == selected?.id ? "arrow.clockwise" : "minus")
                        .frame(width: NookDesign.Size.rowButton + NookDesign.Spacing.xs, height: NookDesign.Size.rowButton)
                }
                .help(tabs.device.pendingProfileDeletion?.change != nil ? "Retry Profile Change" : "Delete Profile…")
                .disabled(tabs.profiles.count < 2 ||
                          (tabs.device.pendingProfileDeletion != nil && tabs.device.pendingProfileDeletion?.target != selected?.id))
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(NookDesign.Spacing.xs)
        }
        .background(shape.fill(NookDesign.Surface.raised))
        .overlay(shape.strokeBorder(NookDesign.Surface.hairline, lineWidth: NookDesign.Size.hairlineWidth))
    }

    private func spaceCount(_ profile: ProfileSummary) -> String {
        switch profile.spaceIDs.count {
        case 0: "No Spaces"
        case 1: "1 Space"
        case let count: "\(count) Spaces"
        }
    }

    /// A profile lives on its spaces, so a new one comes with a space of its own.
    private func addProfile() {
        let name = "Profile \(tabs.profiles.count + 1)"
        guard let space = tabs.createSpace(name: name, icon: "", accentHex: SpaceAccent.defaultHex,
                                           after: tabs.orderedSpaces.last?.id, profileName: name) else { return }
        selection = tabs.profiles.first { $0.spaceIDs.contains(space) }?.id
    }

    private func heir(of profile: ProfileSummary?) -> ProfileSummary? {
        if let intent = tabs.device.pendingProfileDeletion, intent.target == profile?.id {
            return tabs.profiles.first { $0.id == intent.survivor }
        }
        return tabs.profiles.first { $0.id != profile?.id }
    }

    private func delete(_ profile: ProfileSummary) {
        guard let heir = heir(of: profile) else { return }
        if tabs.profileEngine == .chromium {
            tabs.deleteProfile(profile.id, surviving: heir.id) { result in
                switch result {
                case .success: selection = heir.id
                case .failure(.cancelled): break
                case .failure(let error): deletionError = error
                }
            }
            return
        }
        if profile.spaceIDs.isEmpty {
            tabs.deleteKeptProfile(profile.id)
        } else {
            for space in profile.spaceIDs { tabs.setProfile(space, to: heir.id) }
        }
        selection = heir.id
    }
}

/// One profile's settings.
struct ProfileDetailForm: View {
    let profile: ProfileSummary
    @Environment(TabsController.self) private var tabs
    @Environment(NookSettingsService.self) private var nookSettings
    @State private var dataSize: String?
    @State private var confirmingClear = false
    @State private var nativeSearch: ProfileSearchState?
    @State private var searchRequestID = UUID()
    @State private var searchError: String?
    @Environment(\.scenePhase) private var scenePhase
    @Binding var profilePageError: ProfilePageOpenError?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: Binding(
                    get: { profile.name },
                    set: { tabs.renameProfile(profile.id, to: $0) }
                ))
                LabeledContent("Spaces") {
                    Text(profile.spaceIDs.isEmpty ? "None" : profile.spaceIDs.compactMap { tabs.space($0)?.name }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Choose which profile a space uses in Spaces.")
                    .settingsFooter()
            }

            Section {
                if tabs.profileEngine == .chromium {
                    if let nativeSearch {
                        if nativeSearch.selected.isEmpty {
                            LabeledContent("Search engine", value: nativeSearch.name)
                        } else {
                        Picker("Search engine", selection: Binding(
                            get: { nativeSearch.selected },
                            set: { refreshSearch(selecting: $0) }
                        )) {
                            ForEach(nativeSearch.providers) { Text($0.name).tag($0.id) }
                        }
                        .disabled(nativeSearch.controlled)
                        }
                        if nativeSearch.controlled {
                            Text(nativeSearch.managed ? "Managed by your organization" : "Controlled by an extension")
                                .foregroundStyle(.secondary)
                        }
                    } else { Text(searchError ?? "Loading search preferences…") }
                } else { searchEnginePicker }
            } footer: {
                Text(tabs.profileEngine == .chromium
                     ? "Uses this profile’s Chromium search preference. Custom engines can also be edited in Chromium Settings."
                     : "Default follows the search engine in General.")
                    .settingsFooter()
            }

            #if os(macOS)
            if tabs.profileEngine == .webKit {
                Section {
                    downloadLocationPicker
                }
            }
            #endif

            if tabs.profileEngine == .chromium {
                Section {
                    ForEach(ProfilePageDestination.allCases, id: \.self) { destination in
                        Button(destination.profileSettingsLabel) {
                            tabs.openProfilePage(profileID: profile.id, destination: destination) { result in
                                if case .failure(let error) = result { profilePageError = error }
                            }
                        }
                    }
                } header: {
                    Text("Chromium Controls")
                } footer: {
                    Text("Opens controls for “\(profile.name)”.")
                }
            }

            Section("Website Data") {
                if tabs.profileEngine == .chromium {
                    Text("Managed in this profile’s Chromium settings. Use Clear Browsing Data above to remove cookies, cached files and other selected data.")
                        .foregroundStyle(.secondary)
                } else if supportsWebsiteData {
                    LabeledContent(dataSize ?? "Checking…") {
                        Button("Clear Website Data…") { confirmingClear = true }
                    }
                } else {
                    Text("Website data controls are unavailable in this build.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: profile.id) { refreshSearch() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshSearch() }
        #endif
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshSearch() } }
        .task(id: profile.spaceIDs) { await refreshDataSize() }
        .alert("Clear website data for \u{201C}\(profile.name)\u{201D}?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { Task { await clearData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its spaces are signed out of every site, and their cookies and cached files are deleted.")
        }
    }

    private func refreshSearch(selecting: String? = nil) {
        guard tabs.profileEngine == .chromium else { return }
        let request = UUID(); searchRequestID = request
        tabs.profileSearchState(profileID: profile.id, selecting: selecting) { result in
            guard searchRequestID == request else { return }
            switch result {
            case .success(let state): nativeSearch = state; searchError = nil
            case .failure: searchError = "Search preferences are unavailable."; nativeSearch = nil
            }
        }
    }

    private var searchEnginePicker: some View {
        let known = Set(SearchProvider.allCases.map(\.rawValue) + nookSettings.customSearchEngines.map(\.id.uuidString))
        return Picker("Search engine", selection: Binding<String?>(
            get: { profile.searchEngineId.flatMap { known.contains($0) ? $0 : nil } },
            set: { tabs.setSearchEngine($0, forProfile: profile.id) }
        )) {
            Text("Default (\(nookSettings.searchEngineName(for: nookSettings.searchEngineId)))").tag(String?.none)
            Divider()
            ForEach(SearchProvider.allCases) { provider in
                Text(provider.displayName).tag(String?.some(provider.rawValue))
            }
            ForEach(nookSettings.customSearchEngines) { engine in
                Text(engine.name).tag(String?.some(engine.id.uuidString))
            }
        }
    }

    #if os(macOS)
    private enum LocationChoice: Hashable { case downloads, folder, ask, other }

    private var downloadLocationPicker: some View {
        let downloads = nookSettings.downloads(forProfile: profile.id)
        return Picker("Download location", selection: Binding<LocationChoice>(
            get: {
                switch downloads.location {
                case .downloads: .downloads
                case .folder: .folder
                case .ask: .ask
                }
            },
            set: { choice in
                switch choice {
                case .downloads: setLocation(.downloads)
                case .ask: setLocation(.ask)
                // After the menu closes, not inside its tracking loop.
                case .other: DispatchQueue.main.async { chooseFolder() }
                case .folder: break
                }
            }
        )) {
            Label("Downloads", systemImage: "folder").tag(LocationChoice.downloads)
            if case .folder(let path) = downloads.location {
                Label(FileManager.default.displayName(atPath: path), systemImage: "folder").tag(LocationChoice.folder)
            }
            Text("Ask Every Time").tag(LocationChoice.ask)
            Divider()
            Text("Other…").tag(LocationChoice.other)
        }
    }

    private func setLocation(_ location: DownloadLocation) {
        var downloads = nookSettings.downloads(forProfile: profile.id)
        downloads.location = location
        nookSettings.setDownloads(downloads, forProfile: profile.id)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where downloads from \u{201C}\(profile.name)\u{201D} are saved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLocation(.folder(url.path))
    }
    #endif

    private var supportsWebsiteData: Bool {
        tabs.profile(forStore: profile.id)?.webKitDataStore != nil
    }

    private func refreshDataSize() async {
        guard let store = tabs.profile(forStore: profile.id), store.webKitDataStore != nil else { return }
        await store.refreshDataStoreStats()
        dataSize = store.estimatedDataSize
    }

    private func clearData() async {
        guard let store = tabs.profile(forStore: profile.id), store.webKitDataStore != nil else { return }
        await tabs.clearData(of: store)
        dataSize = store.estimatedDataSize
    }
}

private extension ProfilePageDestination {
    var profileSettingsLabel: String {
        switch self {
        case .settings: "Chromium Settings"
        case .extensions: "Extensions"
        case .privacy: "Privacy and Security"
        case .siteSettings: "Site Settings"
        case .clearData: "Clear Browsing Data"
        case .downloads: "Downloads"
        case .passwords: "Password Manager"
        }
    }
}
