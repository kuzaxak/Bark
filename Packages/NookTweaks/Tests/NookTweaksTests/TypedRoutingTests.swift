import Foundation
import Testing
import NookSettings
@testable import NookTweaks

private struct NoTokens: KagiTokenStore { func load() -> String? { nil }; func save(_ token: String?) {} }

@Suite @MainActor struct TypedRoutingTests {
    @Test func aTypedNavigationThatLeavesTheSiteFollowsTheRule() async throws {
        let name = "typed-routing-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: dir) }
        let settings = NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: dir.appendingPathComponent("Boosts.json")))
        let work = UUID(), personal = UUID()
        settings.siteRoutingRules = [SiteRoutingRule(domain: "slack.test", targetSpaceId: work),
                                     SiteRoutingRule(domain: "news.test", targetSpaceId: personal)]
        let routing = SiteRoutingManager(settings: settings)
        var routed: [UUID] = []
        func open(_ space: UUID) -> Bool {
            routed.append(space)
            return true
        }
        let slack = URL(string: "https://app.slack.test/messages")!

        #expect(routing.applyRoute(navigating: URL(string: "https://www.news.test/a")!, to: slack, openInSpace: open))
        #expect(routed == [work], "leaving a site for one a rule names opens it in the rule's space")
        #expect(!routing.applyRoute(navigating: URL(string: "https://app.slack.test/other")!, to: slack, openInSpace: open),
                "on the same host the page loads in place")
        #expect(!routing.applyRoute(navigating: URL(string: "https://news.test/")!, to: URL(string: "https://www.news.test/b")!, openInSpace: open),
                "www. is the same site, though a rule names it")
        #expect(!routing.applyRoute(navigating: URL(string: "about:blank")!, to: slack, openInSpace: open), "a page with no site has none to leave")
        #expect(!routing.applyRoute(navigating: URL(string: "https://news.test/")!, to: URL(string: "https://other.test/")!, openInSpace: open),
                "no rule, no route")
        #expect(!routing.applyRoute(navigating: URL(string: "https://news.test/")!, to: URL(string: "https://accounts.slack.test/o/oauth2/auth?client_id=x")!, openInSpace: open),
                "a sign-in stays where it started")
        #expect(routed.count == 1)
    }
}
