// Licensed under GPL-3.0. See LICENSE.
// The shipped approval/capture/dispatch methods are compiled verbatim by check.py.
// Native transport and model lifetimes are independently tested in their real modules.
import Foundation
struct AIToolCall { let id = "fixture"; let name: String; let arguments: [String: Any] }
struct AIToolResult { let toolCallId: String; let toolName: String; let content: String; var isError = false }
struct Log { func warning(_ text: String) {} ; func error(_ text: String) {} }
@MainActor final class ChromiumPageNavigation {
    enum Mode { case expression }; enum World { case page }
    struct State { var isLoading = false }
    struct Reply { let browserToolText = "42" }
    var state = State(), isClosed = false
    var nativeWindowID: Int32 = 10, nativeTabID: Int32 = 20
    var profileID: UUID? = UUID()
    var calls = 0
    func evaluateScript(_ source: String, mode: Mode, world: World) async throws -> Reply { calls += 1; return Reply() }
}
@MainActor final class PageSession {
    var navigation: AnyObject? = ChromiumPageNavigation()
    var nativeNavigationSerial: UInt64 = 1
    var isLoading = false, nativeAgentNavigationIsPending = false
}
@MainActor final class BrowserWindowState { let id = UUID() }
@MainActor final class Registry { var windows: [UUID: BrowserWindowState] = [:] }
@MainActor final class Tabs {
    var page = PageSession()
    func existingNativeAgentPage(in window: BrowserWindowState) -> PageSession? { page }
    func controllableSession(in window: BrowserWindowState) -> PageSession? { page }
}
@MainActor final class BrowserManager {
    let tabs = Tabs()
    var windowRegistry: Registry? = Registry()
}
@main struct Main {
    @MainActor static func main() async throws {
        for change in ["none", "denied", "missing", "start", "commitWhilePending", "sameDocument", "profile", "owner", "binding", "selection", "window"] {
            let manager = BrowserManager(), window = BrowserWindowState()
            manager.windowRegistry!.windows[window.id] = window
            let page = manager.tabs.page
            let navigation = page.navigation as! ChromiumPageNavigation
            if change == "commitWhilePending" { page.isLoading = true; navigation.state.isLoading = true }
            let executor = BrowserToolExecutor()
            executor.browserManager = manager; executor.windowState = window
            executor.agentSpace = UUID() // Exact hidden Agent route.
            if change != "missing" {
                executor.confirmationHandler = { _,_ in
                    switch change {
                    case "start", "sameDocument": page.nativeNavigationSerial += 1
                    case "commitWhilePending": page.isLoading = false; navigation.state.isLoading = false
                    case "profile": navigation.profileID = UUID()
                    case "owner": navigation.nativeWindowID = 11
                    case "binding": page.navigation = ChromiumPageNavigation()
                    case "selection": manager.tabs.page = PageSession()
                    case "window": manager.windowRegistry!.windows[window.id] = BrowserWindowState()
                    default: break
                    }
                    await Task.yield()
                    return change != "denied"
                }
            }
            let result = try await executor.execute(AIToolCall(name: "executeJavaScript", arguments: ["code":"40+2"]))
            precondition(navigation.calls == (change == "none" ? 1 : 0), change)
            precondition(result.isError == (change != "none"), change)
            if change == "none" { precondition(result.content == "42") }
        }
        print("AI script approval: exact captured target, pending commit, and denial passed")
    }
}
