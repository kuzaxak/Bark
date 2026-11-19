// Licensed under GPL-3.0. See LICENSE.
//
//  Profiles.swift
//  Nook
//
//  Profiles, as Arc lays them out: the list beside the chosen profile's search engine, site settings and browsing data. Which profile a space uses is set in Spaces.
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

    private let openPawlSettings: (() -> Void)?

    public init(openPawlSettings: (() -> Void)? = nil) {
        self.openPawlSettings = openPawlSettings
    }

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
            Text("Each profile keeps its own cookies and history. Several spaces can share a profile.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, NookDesign.Spacing.xxl)
                .padding(.top, NookDesign.Spacing.xxl)
            HStack(alignment: .top, spacing: 0) {
                profileList
                    .frame(width: NookDesign.Size.profileList)
                    .padding(.leading, NookDesign.Spacing.xxl)
                    .padding(.vertical, NookDesign.Spacing.xxl)
                if let profile = selected {
                    ProfileDetailForm(profile: profile, openPawlSettings: openPawlSettings,
                                      profilePageError: $profilePageError)
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
        tabs.deleteProfile(profile.id, surviving: heir.id) { result in
            switch result {
            case .success: selection = heir.id
            case .failure(.cancelled): break
            case .failure(let error): deletionError = error
            }
        }
    }
}

/// One profile's settings.
struct ProfileDetailForm: View {
    let profile: ProfileSummary
    let openPawlSettings: (() -> Void)?
    @Environment(TabsController.self) private var tabs
    @Environment(NookSettingsService.self) private var nookSettings
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
                } else {
                    Text(searchError ?? "Loading search preferences…")
                }
            } footer: {
                Text("Uses this profile’s search preference. Choose Open Profile Settings to edit custom search engines.")
                    .settingsFooter()
            }

            Section {
                ForEach(ProfilePageDestination.allCases, id: \.self) { destination in
                    if destination == .passwords, passwordControl == .pawl, openPawlSettings == nil {
                        Text("Manage passwords in Pawl Vault.")
                    } else if destination == .passwords {
                        Button(passwordControl.label) {
                            passwordControl.open(
                                profileID: profile.id, pawlSettings: { openPawlSettings?() }
                            ) { profileID in
                                openProfileControls(.passwords, profileID: profileID)
                            }
                        }
                    } else {
                        Button(destination.profileSettingsLabel) {
                            openProfileControls(destination, profileID: profile.id)
                        }
                    }
                }
            } header: {
                Text("Profile Controls")
            } footer: {
                Text(passwordControl == .pawl
                     ? "Opens controls for “\(profile.name)”. Pawl Vault uses the same unlocked vault across profiles."
                     : "Opens controls for “\(profile.name)”.")
            }

            Section("Website Data") {
                Text("Use Clear Browsing Data above to remove this profile’s cookies, cached files and other selected data.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: profile.id) { refreshSearch() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshSearch() }
        #endif
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshSearch() } }
    }

    private func refreshSearch(selecting: String? = nil) {
        let request = UUID(); searchRequestID = request
        tabs.profileSearchState(profileID: profile.id, selecting: selecting) { result in
            guard searchRequestID == request else { return }
            switch result {
            case .success(let state): nativeSearch = state; searchError = nil
            case .failure: searchError = "Search preferences are unavailable."; nativeSearch = nil
            }
        }
    }

    private var passwordControl: ProfilePasswordControl {
        #if os(macOS)
        ProfilePasswordControl(pawlEnabled: nookSettings.pawlVaultEnabled,
                               effectivePawlEnabled: tabs.vault?.isEnabled)
        #else
        .chromium
        #endif
    }

    private func openProfileControls(_ destination: ProfilePageDestination, profileID: UUID) {
        tabs.openProfilePage(profileID: profileID, destination: destination) { result in
            if case .failure(let error) = result { profilePageError = error }
        }
    }
}

private extension ProfilePageDestination {
    var profileSettingsLabel: String {
        switch self {
        case .settings: "Open Profile Settings"
        case .extensions: "Extensions"
        case .privacy: "Privacy and Security"
        case .secureConnections: "Secure Connections"
        case .siteSettings: "Site Settings"
        case .clearData: "Clear Browsing Data"
        case .downloads: "Downloads"
        case .passwords: ProfilePasswordControl.chromium.label
        }
    }
}
