// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Observation

/// The marker belongs to the renderer document identified by Chromium. Changes
/// also invalidate the action closure of a previously rendered notice.
@MainActor @Observable
final class ChromiumPasswordManagementLanding {
    private(set) var generation: UInt64 = 0
    private(set) var isAvailable = false

    func update(_ available: Bool) {
        guard isAvailable != available else { return }
        generation &+= 1
        isAvailable = available
    }

    func settingsAction(pawlEnabledAtLaunch: Bool?, ownerCurrent: @escaping () -> Bool,
                        openSettings: @escaping () -> Void) -> (() -> Void)? {
        guard pawlEnabledAtLaunch == true, isAvailable, ownerCurrent() else { return nil }
        let generation = generation
        return { [weak self] in
            guard let self, self.isAvailable, self.generation == generation, ownerCurrent() else { return }
            openSettings()
        }
    }
}

/// Handles explicit submissions from Bark's own address controls.
@MainActor
enum ChromiumPasswordManagementCommand {
    static func offersSettings(_ text: String, pawlEnabledAtLaunch: Bool?, regularNativeOwner: Bool,
                               hasSearchOrPlacementOverride: Bool) -> Bool {
        guard pawlEnabledAtLaunch == true, regularNativeOwner, !hasSearchOrPlacementOverride,
              let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.user == nil, url.password == nil, url.port == nil else { return false }

        switch url.scheme?.lowercased() {
        case "chrome":
            guard url.percentEncodedHost?.lowercased() == "password-manager" else { return false }
        case "about":
            let path = url.percentEncodedPath.lowercased()
            guard url.host == nil, path == "password-manager" || path.hasPrefix("password-manager/") else { return false }
        default:
            return false
        }

        return true
    }

    static func handle(_ text: String, pawlEnabledAtLaunch: Bool?, hasSearchOrPlacementOverride: Bool,
                       ownerCurrent: () -> Bool, dismissEditor: () -> Void, openPasswordSettings: () -> Void) -> Bool {
        guard offersSettings(text, pawlEnabledAtLaunch: pawlEnabledAtLaunch, regularNativeOwner: ownerCurrent(),
                             hasSearchOrPlacementOverride: hasSearchOrPlacementOverride) else { return false }
        dismissEditor()
        if ownerCurrent() { openPasswordSettings() }
        // A dismissed editor no longer owns the original navigation.
        return true
    }
}
