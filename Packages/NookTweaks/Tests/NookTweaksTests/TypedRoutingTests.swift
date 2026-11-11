import Foundation
import Testing
import NookSettings
@testable import NookTweaks

private struct NoTokens: KagiTokenStore { func load() -> String? { nil }; func save(_ token: String?) {} }

@MainActor private final class Host: SiteRoutingHost {
    var routed: [(URL, UUID)] = []
    func route(url: URL, toSpace spaceID: UUID, from page: AnyObject?) -> Bool { routed.append((url, spaceID)); return true }
    func liveSpaceIDs() -> Set<UUID> { [] }
}

/// A typed navigation of a page follows Air Traffic Control as WebKit's navigation policy does:
/// leaving the site for one a rule names opens it in the rule's space.
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
        let routing = SiteRoutingManager(settings: settings), host = Host(), page = NSObject()
        routing.host = host
        let slack = URL(string: "https://app.slack.test/messages")!

        #expect(routing.applyRoute(navigating: URL(string: "https://www.news.test/a")!, to: slack, page: page))
        #expect(host.routed.map(\.1) == [work], "leaving a site for one a rule names opens it in the rule's space")
        #expect(!routing.applyRoute(navigating: URL(string: "https://app.slack.test/other")!, to: slack, page: page),
                "on the same host the page loads in place")
        #expect(!routing.applyRoute(navigating: URL(string: "https://news.test/")!, to: URL(string: "https://www.news.test/b")!, page: page),
                "www. is the same site, though a rule names it")
        #expect(!routing.applyRoute(navigating: URL(string: "about:blank")!, to: slack, page: page), "a page with no site has none to leave")
        #expect(!routing.applyRoute(navigating: URL(string: "https://news.test/")!, to: URL(string: "https://other.test/")!, page: page),
                "no rule, no route")
        #expect(!routing.applyRoute(navigating: URL(string: "https://news.test/")!, to: URL(string: "https://accounts.slack.test/o/oauth2/auth?client_id=x")!, page: page),
                "a sign-in stays where it started")
        #expect(host.routed.count == 1)
    }
}
