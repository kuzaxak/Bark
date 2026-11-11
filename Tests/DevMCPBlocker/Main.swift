import Foundation
@MainActor final class BrowserWindowState { var selected = UUID(); var profile = UUID() }
@MainActor final class PageSession {
    let itemID = UUID()
    let profile: UUID
    var url = URL(string: "https://agent.test/path")!
    var isOAuthFlow = false
    init(profile: UUID) { self.profile = profile }
}
@MainActor final class BrowserManager {
    enum Engine { case chromium, webKit }
    var engine = Engine.chromium
    let tabs = Tabs()
    let contentBlockerManager = Blocker()
    func agentWebView() throws -> Never { throw WKPreparation.unexpected }
    enum WKPreparation: Error { case unexpected }
    @MainActor final class Tabs {
        var page: PageSession?
        var owner: BrowserWindowState?
        func existingNativeAgentPage(in window: BrowserWindowState) -> PageSession? {
            guard owner === window, page?.profile == window.profile else { return nil }
            return page
        }
    }
    @MainActor final class Blocker {
        var isEnabled = true, isCompiling = false, lastBuildSucceeded = true, networkBlockingRequested = true
        var networkRules: Int? = 1
        var allowed = Set<String>()
        let advancedRulesEngine = Advanced()
        @MainActor final class Advanced {
            let engine = Matcher()
            @MainActor final class Matcher {
                func matches(url: String, sourceURL: String, type: String) -> Bool { url.contains("advert") && sourceURL.contains("agent.test") && type == "script" }
            }
        }
        func isDomainAllowed(_ host: String?) -> Bool { host.map(allowed.contains) ?? false }
        func shouldApplyBlocking(to page: PageSession) -> Bool { isEnabled && !isDomainAllowed(page.url.host) }
        func isTemporarilyDisabled(tabId: UUID) -> Bool { false }
        @discardableResult func allowDomain(_ host: String, allowed value: Bool, from page: PageSession?) -> Bool {
            if value { allowed.insert(host) } else { allowed.remove(host) }
            return true
        }
    }
}
@main struct BlockerDispatchCheck {
    @MainActor static func main() throws {
        let manager = BrowserManager(), window = BrowserWindowState()
        manager.tabs.owner = window
        manager.tabs.page = PageSession(profile: window.profile)
        let server = DispatchFixture()
        let selected = window.selected, profile = window.profile
        func response(_ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
            let value = try server.dispatch(name, args, browserManager: manager, window: window)
            let content = value["content"] as! [[String: String]]
            return try JSONSerialization.jsonObject(with: Data(content[0]["text"]!.utf8)) as! [String: Any]
        }
        let status = try response("blocker_status")
        precondition(status["scope"] as? String == "modelPolicyAndBuildReadiness")
        precondition(status["nativeInstallation"] as? String == "notVerifiedByThisTool")
        precondition(status["host"] as? String == "agent.test")
        _ = try server.dispatch("set_blocking", ["enabled": false], browserManager: manager, window: window)
        precondition(manager.contentBlockerManager.allowed == ["agent.test"])
        let checks = try response("check_urls", ["urls": ["https://cdn.test/advert.js", "https://cdn.test/normal.js"]])
        precondition(checks["sourceURL"] as? String == "https://agent.test/path")
        precondition((checks["matches"] as? [String: Bool])?["https://cdn.test/advert.js"] == true)
        precondition(window.selected == selected && window.profile == profile)
        manager.tabs.page = PageSession(profile: UUID())
        let refused = try server.dispatch("set_blocking", ["enabled": true], browserManager: manager, window: window)
        precondition(refused["isError"] as? Bool == true)
        precondition(manager.contentBlockerManager.allowed == ["agent.test"])
        manager.tabs.page = nil
        let cold = try server.dispatch("blocker_status", [:], browserManager: manager, window: window)
        precondition(cold["isError"] as? Bool == true)
        print("PASS: three blocker dispatches bypass throwing WK preparation; exact page/profile refusal; no window selection change; policy/readiness labels")
    }
}
