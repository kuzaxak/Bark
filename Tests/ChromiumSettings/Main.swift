// Licensed under GPL-3.0. See LICENSE.
// Compiles the shipped gate. A part of Settings appears on Chromium only where its setting acts there.
import Foundation

@main struct Main {
    static func main() {
        let shown = Set(SettingsControl.allCases.filter { $0.isShown(chromium: true) })
        let expected: Set<SettingsControl> = [.quit, .tabs, .peekOnShiftClick, .performance, .search, .siteSearch, .urlShortcuts, .wordStops]
        precondition(shown == expected, "Chromium shows \(shown.subtracting(expected)) and hides \(expected.subtracting(shown))")
        precondition(SettingsControl.allCases.allSatisfy { $0.isShown(chromium: false) }, "WebKit keeps every part")
        print("Settings: Chromium shows only parts that act there; WebKit keeps all")
    }
}
