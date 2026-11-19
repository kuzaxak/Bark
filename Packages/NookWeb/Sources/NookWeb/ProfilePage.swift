// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore

/// Chromium-owned controls for an explicitly selected persistent profile.
public enum ProfilePageDestination: CaseIterable, Hashable, Sendable {
    case settings, extensions, privacy, secureConnections, siteSettings, clearData, downloads, passwords
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

/// The presenter must retain the requested identity, visibly identify the profile,
/// and check canPresent before dispatch and again immediately before admission.
/// A stale request must fail without opening another profile. Success means actual
/// presentation admission, not merely dispatch. No tab-tree item is created.
public typealias ProfilePageAction = @MainActor (
    ProfileSummary, ProfilePageDestination,
    _ canPresent: @escaping @MainActor () -> Bool,
    _ completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void
) -> Void

extension TabsController {
    /// Resolve the pane's saved profile without opening controls or creating a page.
    public func extensionControlsProfileID(in window: BrowserWindowState) -> UUID? {
        let space: UUID?
        if let selected = window.selectedItemID {
            space = tree.spaceID(of: selected)
        } else {
            space = window.spaceID
        }
        return space.flatMap { tree.dataStoreID(for: $0) }
    }

    /// Product commands capture the selected regular profile once. Its controls
    /// then remain independent of the source window's subsequent selection.
    public func openExtensionControls(in window: BrowserWindowState?,
                                      completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
        guard let window, windowRegistry.windows[window.id] === window,
              windowRegistry.activeWindow === window, !window.isIncognito,
              window.privateTree == nil else {
            completion(.failure(.presentationUnavailable))
            return
        }
        guard let profileID = extensionControlsProfileID(in: window) else {
            completion(.failure(.profileUnavailable))
            return
        }
        openProfilePage(profileID: profileID, destination: .extensions, completion: completion)
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
        guard isProfileAvailable(profileID), let profile = profiles.first(where: { $0.id == profileID }) else {
            completion(.failure(.profileUnavailable))
            return
        }
        guard let action = onOpenProfilePage else {
            completion(.failure(.presentationUnavailable))
            return
        }
        let canPresent: @MainActor () -> Bool = { [weak self] in
            self?.isProfileAvailable(profileID) == true
        }
        var completed = false
        action(profile, destination, canPresent) { result in
            guard !completed else { return }
            completed = true
            completion(canPresent() ? result : .failure(.profileUnavailable))
        }
    }
}
