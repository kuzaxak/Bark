// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped decision verbatim, without the window.
import Foundation

@main @MainActor enum Check {
    static func main() {
        let data = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: data)
        let tabs = data.appendingPathComponent("App/Tabs", isDirectory: true)
        precondition(!ChromiumOnboarding.hasTabs(in: tabs), "a data directory that has never run holds no tabs")
        try! FileManager.default.createDirectory(at: tabs, withIntermediateDirectories: true)
        precondition(!ChromiumOnboarding.hasTabs(in: tabs), "nor does an empty tabs folder")

        var finished = false
        precondition(ChromiumOnboarding.isNeeded(didFinish: &finished, hadTabs: false) && !finished, "a fresh data directory shows onboarding")
        finished = true
        precondition(!ChromiumOnboarding.isNeeded(didFinish: &finished, hadTabs: false), "a person who finished it does not see it again")

        try! Data("{}".utf8).write(to: tabs.appendingPathComponent("structure.json"))
        precondition(ChromiumOnboarding.hasTabs(in: tabs), "an earlier launch or a conversion leaves tabs")
        finished = false
        precondition(!ChromiumOnboarding.isNeeded(didFinish: &finished, hadTabs: true) && finished,
                     "a data directory with tabs is a returning person's: no onboarding, and it counts as finished")
        print("Onboarding: shown on a fresh data directory only; a returning or converted one counts as finished")
    }
}
