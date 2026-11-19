// Licensed under GPL-3.0. See LICENSE.
import Foundation

enum ProfilePasswordControl {
    case pawl, chromium

    init(pawlEnabled: Bool, effectivePawlEnabled: Bool? = nil) {
        self = (effectivePawlEnabled ?? pawlEnabled) ? .pawl : .chromium
    }

    var label: String {
        switch self {
        case .pawl: "Pawl Vault Settings"
        case .chromium: "Password Manager"
        }
    }

    func open(profileID: UUID, pawlSettings: () -> Void, chromiumPasswords: (UUID) -> Void) {
        switch self {
        case .pawl: pawlSettings()
        case .chromium: chromiumPasswords(profileID)
        }
    }
}
