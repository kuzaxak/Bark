// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore

/// Chromium-owned controls for an explicitly selected persistent profile.
public enum ProfilePageDestination: CaseIterable, Hashable, Sendable {
    case settings, extensions, privacy, secureConnections, siteSettings, clearData, downloads, passwords

    var url: URL {
        let address = switch self {
        case .settings: "chrome://settings/"
        case .extensions: "chrome://extensions/"
        case .privacy: "chrome://settings/privacy"
        case .secureConnections: "chrome://settings/security"
        case .siteSettings: "chrome://settings/content"
        case .clearData: "chrome://settings/clearBrowserData"
        case .downloads: "chrome://settings/downloads"
        case .passwords: "chrome://password-manager/passwords"
        }
        return URL(string: address)!
    }

    var tabTitle: String {
        switch self {
        case .settings: "Profile Settings"
        case .extensions: "Extensions"
        case .privacy: "Privacy and Security"
        case .secureConnections: "Secure Connections"
        case .siteSettings: "Site Settings"
        case .clearData: "Clear Browsing Data"
        case .downloads: "Downloads"
        case .passwords: "Password Manager"
        }
    }
}

public enum ProfilePageOpenError: Error, Equatable, LocalizedError {
    case profileUnavailable, presentationUnavailable, presentationFailed

    public var errorDescription: String? {
        switch self {
        case .profileUnavailable: "This profile is no longer available."
        case .presentationUnavailable: "Profile controls are unavailable right now."
        case .presentationFailed: "The profile controls could not be opened."
        }
    }
}

/// Success means the destination is the selected tab in the requested window and space.
public typealias ProfilePageAction = @MainActor (
    ProfileSummary, ProfilePageDestination, BrowserWindowState, UUID,
    _ canPresent: @escaping @MainActor () -> Bool,
    _ completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void
) -> Void

extension TabsController {
    /// Resolve the space's profile without opening a page.
    public func extensionControlsProfileID(in window: BrowserWindowState) -> UUID? {
        window.spaceID.flatMap { tree.dataStoreID(for: $0) }
    }

    /// The menu manages the invoking space even if a split pane belongs elsewhere.
    public func openExtensionControls(in window: BrowserWindowState?,
                                      completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
        guard let window, windowRegistry.windows[window.id] === window,
              windowRegistry.activeWindow === window, !window.isIncognito,
              window.privateTree == nil else {
            completion(.failure(.presentationUnavailable))
            return
        }
        guard let spaceID = window.spaceID, let profileID = extensionControlsProfileID(in: window) else {
            completion(.failure(.profileUnavailable))
            return
        }
        openProfilePage(profileID: profileID, destination: .extensions, in: window,
                        spaceID: spaceID, completion: completion)
    }

    /// The regular profile actually shown by the browser and its app history.
    public func displayedHistoryProfile(_ history: HistoryManager) -> ProfileSummary? {
        guard let window = windowRegistry.activeWindow, !window.isIncognito, window.privateTree == nil,
              let spaceID = window.spaceID, let profileID = tree.dataStoreID(for: spaceID),
              history.currentProfileId == profileID, isProfileAvailable(profileID) else { return nil }
        return profiles.first { $0.id == profileID }
    }

    /// Clear the app history only after the exact profile's Chromium controls are admitted.
    public func clearDisplayedProfileHistory(_ displayedID: UUID?, history: HistoryManager,
                                             completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
        guard let displayedID, displayedHistoryProfile(history)?.id == displayedID else {
            completion(.failure(.profileUnavailable))
            return
        }
        openProfilePage(profileID: displayedID, destination: .clearData) { result in
            if case .success = result { history.clearHistory(profileId: displayedID) }
            completion(result)
        }
    }

    public func openProfilePage(profileID: UUID, destination: ProfilePageDestination,
                                completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
        guard isProfileAvailable(profileID) else { completion(.failure(.profileUnavailable)); return }
        guard let window = windowRegistry.activeWindow, !window.isIncognito, window.privateTree == nil else {
            completion(.failure(.presentationUnavailable)); return
        }
        let matches: (UUID) -> Bool = { [self] in tree.dataStoreID(for: $0) == profileID }
        let spaceID = window.spaceID.flatMap { matches($0) ? $0 : nil }
            ?? userSpaces(for: window).first(where: { matches($0.id) })?.id
        guard let spaceID else { completion(.failure(.presentationUnavailable)); return }
        openProfilePage(profileID: profileID, destination: destination, in: window, spaceID: spaceID,
                        completion: completion)
    }

    private func openProfilePage(profileID: UUID, destination: ProfilePageDestination,
                                 in window: BrowserWindowState, spaceID: UUID,
                                 completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
        guard isProfileAvailable(profileID), let profile = profiles.first(where: { $0.id == profileID }) else {
            completion(.failure(.profileUnavailable))
            return
        }
        guard let action = onOpenProfilePage else {
            completion(.failure(.presentationUnavailable))
            return
        }
        let canPresent: @MainActor () -> Bool = { [weak self, weak window] in
            guard let self, let window else { return false }
            return self.windowRegistry.windows[window.id] === window && !window.isIncognito && window.privateTree == nil &&
                self.isProfileAvailable(profileID) && self.tree.dataStoreID(for: spaceID) == profileID
        }
        var completed = false
        action(profile, destination, window, spaceID, canPresent) { [weak self] result in
            guard !completed else { return }
            completed = true
            guard let self else { completion(.failure(.presentationUnavailable)); return }
            if !self.isProfileAvailable(profileID) || self.tree.dataStoreID(for: spaceID) != profileID {
                completion(.failure(.profileUnavailable))
            } else {
                completion(canPresent() ? result : .failure(.presentationUnavailable))
            }
        }
    }

    /// The item is placed in its profile's space and selected by one definitive
    /// native transaction. The old space stays visible until Chromium admits it.
    public func presentProfilePageTab(_ destination: ProfilePageDestination, in window: BrowserWindowState,
                                      spaceID: UUID, canPresent: @escaping @MainActor () -> Bool,
                                      completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
        guard canPresent(), let host = nativePageHost as? any NativeSpaceSwitchHost else {
            completion(.failure(.presentationUnavailable)); return
        }
        let previous = window.nativeSelectionGeneration
        let parent = Parent.tabs(spaceID: spaceID)
        let id = UUID()
        guard perform(.main, "open profile controls", undoable: false, { tree in
            try tree.createTab(id: id, url: destination.url, title: destination.tabTitle, in: parent, after: nil)
        }) != nil else { completion(.failure(.presentationFailed)); return }

        let finish: @MainActor (Bool) -> Void = { [weak self] admitted in
            if admitted && canPresent() {
                completion(.success(()))
            } else {
                self?.discardUnselectedProfilePage(id, in: spaceID)
                completion(.failure(.presentationFailed))
            }
        }
        guard canPresent(), window.nativeSelectionGeneration == previous else { finish(false); return }
        switchNativeSpace(spaceID, itemID: id, in: window, through: host, onFinished: finish)
    }

    private func discardUnselectedProfilePage(_ id: UUID, in spaceID: UUID) {
        guard tree.item(id)?.parent == .tabs(spaceID: spaceID),
              !allWindows.contains(where: {
                  $0.selectedItemBySpace[spaceID] == id || $0.nativeSelectionSession?.itemID == id
              }) else { return }
        if releaseNativePagesBeforeMutation([id], then: { [weak self] in
            self?.discardUnselectedProfilePage(id, in: spaceID)
        }) { return }
        guard perform(.main, "dismiss unselected profile controls", undoable: false, {
            try $0.close(id, promotingChildren: true).change
        }) != nil else { return }
        endSession(id)
    }
}
