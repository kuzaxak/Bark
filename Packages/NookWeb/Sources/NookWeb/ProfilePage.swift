// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore

/// Chromium-owned controls for an explicitly selected persistent profile.
public enum ProfilePageDestination: CaseIterable, Hashable, Sendable {
    case settings, extensions, privacy, siteSettings, clearData, downloads, passwords
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
        let spaceID: UUID?
        if let selected = window.selectedItemID {
            spaceID = tree.spaceID(of: selected)
        } else {
            spaceID = window.spaceID
        }
        guard let spaceID, let profileID = tree.dataStoreID(for: spaceID) else {
            completion(.failure(.profileUnavailable))
            return
        }
        openProfilePage(profileID: profileID, destination: .extensions, completion: completion)
    }

    public func openProfilePage(profileID: UUID, destination: ProfilePageDestination,
                                completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
        guard isProfileAvailable(profileID), let profile = profiles.first(where: { $0.id == profileID }) else {
            completion(.failure(.profileUnavailable))
            return
        }
        guard profileEngine == .chromium, let action = onOpenProfilePage else {
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
