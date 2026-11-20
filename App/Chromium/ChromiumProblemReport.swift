// Licensed under GPL-3.0. See LICENSE.
import AppKit

@MainActor
enum ChromiumProblemReport {
    static let url = URL(string: "https://github.com/kuzaxak/Bark/issues/new/choose")!

    static func open() {
        _ = NSWorkspace.shared.open(url)
    }
}
