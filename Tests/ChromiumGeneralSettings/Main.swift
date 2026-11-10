// Licensed under GPL-3.0. See LICENSE.
// Compiles the shipped section list. A section appears on Chromium only where its settings act there.
import Foundation

@main struct Main {
    static func main() {
        let shown = Set(GeneralSettingsSection.allCases.filter { $0.isShown(chromium: true) })
        let expected: Set<GeneralSettingsSection> = [.quit, .tabs, .peekOnShiftClick, .performance, .search, .siteSearch, .urlShortcuts, .wordStops]
        precondition(shown == expected, "Chromium shows \(shown)")
        precondition(GeneralSettingsSection.allCases.allSatisfy { $0.isShown(chromium: false) }, "WebKit keeps every section")
        print("General settings: Chromium shows only sections that act there; WebKit keeps all")
    }
}
