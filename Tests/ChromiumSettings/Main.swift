// Licensed under GPL-3.0. See LICENSE.
// Compiles the shipped gate. A part of Settings appears on Chromium only where its setting acts there.
import Foundation

@main struct Main {
    static func main() {
        let shown = Set(SettingsControl.allCases.filter { $0.isShown(chromium: true) })
        let expected: Set<SettingsControl> = [.quit, .iCloudSync, .tabs, .peekOnShiftClick, .performance, .search, .siteSearch, .urlShortcuts, .wordStops]
        precondition(shown == expected, "Chromium shows \(shown.subtracting(expected)) and hides \(expected.subtracting(shown))")
        precondition(SettingsControl.allCases.allSatisfy { $0.isShown(chromium: false) }, "WebKit keeps every part")
        let selected = UUID()
        var openedPrivacy = false
        var openedChromium: [UUID] = []
        for (preferred, effective, usePawl): (Bool, Bool?, Bool) in [
            (true, nil, true), (false, nil, false), (false, true, true), (true, false, false),
        ] {
            let control = ProfilePasswordControl(pawlEnabled: preferred, effectivePawlEnabled: effective)
            precondition(control.label == (usePawl ? "Pawl Vault Settings" : "Password Manager"))
            openedPrivacy = false
            openedChromium = []
            control.open(profileID: selected, pawlSettings: { openedPrivacy = true },
                         chromiumPasswords: { openedChromium.append($0) })
            precondition(openedPrivacy == usePawl)
            precondition(openedChromium == (usePawl ? [] : [selected]))
        }
        print("Settings: engine-specific controls and both profile password routes passed")
    }
}
