// Licensed under GPL-3.0. See LICENSE.
// Compiles the shipped resolver and appearance follower. The appearance check shows no window and
// activates nothing: NSApp is only the object Chromium's theme observes.
import AppKit
import Foundation
import NookSettings
import NookTabsCore

private final class MemoryTokens: KagiTokenStore, @unchecked Sendable {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

private final class AppearanceWatch: NSObject {
    var changes = 0
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changes += 1
    }
}

@MainActor private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

@MainActor private func checkResolver() {
    let space = UUID(), agent = UUID()
    let saved = SpaceTheme(points: [.init(hue: 200, saturation: 0.8)], mode: .dark)
    let draft = SpaceTheme(points: [.init(hue: 40, saturation: 0.8)], mode: .light)
    func chrome(incognito: Bool = false, draft: SpaceTheme? = nil, shows: UUID? = space) -> ChromiumSpaceChrome {
        ChromiumSpaceChrome(isIncognito: incognito, draftTheme: draft, spaceID: shows, agentSpaceID: agent, spaceTheme: saved, spaceAccentHex: "#112233")
    }
    let plain = chrome()
    precondition(plain.theme == saved && plain.accentHex == "#112233" && !plain.tintsPrivate && !plain.showsAgentGradient)
    precondition(chrome(draft: draft).theme == draft, "a theme being edited shows at once")
    let hidden = chrome(incognito: true, draft: draft)
    precondition(hidden.theme == nil && hidden.accentHex == nil && hidden.tintsPrivate && !hidden.showsAgentGradient, "private windows keep their own look")
    let agentChrome = chrome(shows: agent)
    precondition(agentChrome.theme == nil && agentChrome.showsAgentGradient, "the Agent space keeps its gradient")
    let drafting = chrome(draft: draft, shows: agent)
    precondition(drafting.theme == draft && !drafting.showsAgentGradient, "a draft replaces the Agent gradient")
    let none = ChromiumSpaceChrome(isIncognito: false, draftTheme: nil, spaceID: nil, agentSpaceID: nil, spaceTheme: nil, spaceAccentHex: nil)
    precondition(none.theme == nil && none.accentHex == nil && !none.showsAgentGradient, "no space is not the Agent space")
}

@MainActor private func checkAppearance() throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let suite = "chromium-space-chrome-check-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let boosts = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suite + "-boosts.json")
    defer { try? FileManager.default.removeItem(at: boosts) }
    defaults.set(AppearanceMode.dark.rawValue, forKey: "settings.appearanceMode")
    let settings = NookSettingsService(kagiTokenStore: MemoryTokens(), userDefaults: defaults, boostStore: BoostStore(fileURL: boosts))
    let watch = AppearanceWatch()
    application.addObserver(watch, forKeyPath: "effectiveAppearance", options: [], context: nil)
    defer { application.removeObserver(watch, forKeyPath: "effectiveAppearance") }

    let follower = ChromiumAppearance(settings: settings)
    defer { withExtendedLifetime(follower) {} }
    var heard = 0
    follower.onEffectiveChange = { heard += 1 }
    precondition(application.appearance?.name == .darkAqua, "the saved mode applies at startup")
    precondition(application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    let afterStart = watch.changes
    precondition(afterStart > 0, "Chromium's observer key changes")

    settings.appearanceMode = .light
    drain()
    precondition(application.appearance?.name == .aqua, "Light applies live")
    precondition(application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    precondition(watch.changes > afterStart, "Chromium hears the live change")
    precondition(heard > 0, "the app hears it too, for what depends on it")

    settings.appearanceMode = .dark
    drain()
    precondition(application.appearance?.name == .darkAqua, "Dark applies live")

    settings.appearanceMode = .system
    drain()
    precondition(application.appearance == nil, "System follows the Mac")
}

@main struct Main {
    @MainActor static func main() throws {
        checkResolver()
        try checkAppearance()
        print("Space chrome: theme, accent, private tint and Agent gradient resolved; appearance follows settings live")
    }
}
