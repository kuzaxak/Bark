import Foundation
@MainActor final class BrowserWindowState { var selected = UUID(); var profile = UUID() }
@MainActor final class ChromiumPageNavigation {
    var isPrivateSession = false
    var resourceDiagnostics: (inWindow: Bool?, pid: Int32?, visibility: String?) = (nil, nil, nil)
}
typealias TabsController = BrowserManager.Tabs
@MainActor final class PageSession {
    let itemID = UUID()
    let profile: UUID
    var url = URL(string: "https://agent.test/path")!
    var isOAuthFlow = false
    var isUnloaded = false
    var navigation: AnyObject?
    var acceptsFlush = true
    var flushes = 0
    func clearPageCache() -> Bool { flushes += 1; return acceptsFlush }
    init(profile: UUID) { self.profile = profile }
}
@MainActor final class BrowserManager {
    let tabs = Tabs()
    let contentBlockerManager = Blocker()
    @MainActor final class Tabs {
        var regularDiagnosticSessions: [PageSession] = []
        var displayed: UUID?
        func isOnScreen(_ id: UUID) -> Bool { id == displayed }
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
        let engine = Matcher()
        final class Matcher {
            func matches(url: String, sourceURL: String, type: String) -> Bool {
                url.contains("advert") && sourceURL.contains("agent.test") && type == "script"
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
        let shown = PageSession(profile: profile)
        let parked = PageSession(profile: profile)
        let unloaded = PageSession(profile: profile)
        unloaded.isUnloaded = true
        let current = ChromiumPageNavigation(), older = ChromiumPageNavigation()
        current.resourceDiagnostics = (true, 123, "visible")
        older.resourceDiagnostics = (false, nil, nil)
        shown.navigation = current
        parked.navigation = older
        parked.acceptsFlush = false
        let privatePage = PageSession(profile: UUID()), privateOwner = ChromiumPageNavigation()
        privateOwner.isPrivateSession = true
        privatePage.navigation = privateOwner
        manager.tabs.regularDiagnosticSessions = [shown, parked, unloaded, privatePage]
        manager.tabs.displayed = shown.itemID
        func replyText(_ name: String, _ args: [String: Any] = [:]) throws -> String {
            let result = try server.dispatch(name, args, browserManager: manager, window: window)
            precondition(result["isError"] as? Bool == false)
            return (result["content"] as! [[String: String]])[0]["text"]!
        }
        let data = Data(try replyText("pages").utf8)
        let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        precondition(rows.count == 3 && rows[0]["onScreen"] as? Bool == true &&
                     rows[0]["pid"] as? Int == 123 && rows[0]["visibility"] as? String == "visible")
        precondition(rows[1]["inWindow"] as? Bool == false && rows[1]["pid"] == nil && rows[1]["visibility"] == nil)
        precondition(rows[2]["loaded"] as? Bool == false && rows[2]["inWindow"] == nil)
        let background = try replyText("clear_page_cache")
        precondition(background.contains("0 of 1") && shown.flushes == 0 && parked.flushes == 1)
        let all = try replyText("clear_page_cache", ["all": true])
        precondition(all.contains("1 of 2") && shown.flushes == 1 && parked.flushes == 2 && unloaded.flushes == 0)
        precondition(privatePage.flushes == 0)
        for name in ["perf", "blocker_log", "console", "network", "user_scripts"] {
            let reply = try server.dispatch(name, [:], browserManager: manager, window: window)
            precondition(reply["isError"] as? Bool == true)
            let content = reply["content"] as! [[String: String]]
            precondition(content[0]["text"] == "\(name) failed: This tool is not available for Chromium pages yet")
        }
        print("Unsupported diagnostic calls keep their Chromium error response")
        print("Regular page diagnostics and cache requests preserve foreground selection and cold pages")
        print("PASS: three blocker dispatches do not prepare a page; exact page/profile refusal; no window selection change; policy/readiness labels")
    }
}
