// Licensed under GPL-3.0. See LICENSE.
// Exercise the profile password control's actual provider selection and route.
import Foundation

@main struct Main {
    static func main() {
        let selected = UUID()
        for (preferred, effective, usePawl): (Bool, Bool?, Bool) in [
            (true, nil, true), (false, nil, false), (false, true, true), (true, false, false),
        ] {
            let control = ProfilePasswordControl(pawlEnabled: preferred, effectivePawlEnabled: effective)
            precondition(control.label == (usePawl ? "Pawl Vault Settings" : "Password Manager"))
            var openedPrivacy = false
            var openedChromium: [UUID] = []
            control.open(profileID: selected, pawlSettings: { openedPrivacy = true },
                         chromiumPasswords: { openedChromium.append($0) })
            precondition(openedPrivacy == usePawl)
            precondition(openedChromium == (usePawl ? [] : [selected]))
        }
        print("Settings: effective and preferred password providers open the correct profile settings route")
    }
}
