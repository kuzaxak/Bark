// Licensed under GPL-3.0. See LICENSE.
// Shipped helper/facade bodies, real DevPickerScript and DevHandoff; narrow
// model/transport fakes. No server, browser, credentials or profile construction.
import Foundation
@MainActor final class ChromiumPageNavigation {
    enum ScriptMode {case asyncBody};enum ScriptWorld {case isolated, page}
    struct Result {var isString=true;var text="- main\n  - button \"Save\"";var json=""}
    var nativeWindowID:Int32=10,nativeTabID:Int32=20
    var profileID:UUID?=UUID();var isClosed=false
    var result=Result();var calls:[String]=[];var hook:(()->Void)?
    var worlds: [ScriptWorld] = []
    var screenshotWidths:[Double]=[]
    var screenshotHook:(()->Void)?
    var screenshotFailure=false
    var lastDeveloperPick: (window: UUID, owner: Int32, profile: UUID?, document: UInt64, pick: DevPick)?
    var pickerStarts = 0
    var pickerHook: (() -> Void)?
    func pickElement() async -> String? {
        pickerStarts += 1
        pickerHook?()
        return "#save"
    }
    func captureScreenshot(maxWidth:Double) async throws -> Data {
        screenshotWidths.append(maxWidth);screenshotHook?()
        if screenshotFailure {throw CancellationError()}
        return Data([255,216,255,217])
    }
    func evaluateScript(_ source:String,mode:ScriptMode,world:ScriptWorld) async throws -> Result {
        calls.append(source);worlds.append(world);hook?();return result
    }
}
@MainActor final class PageSession {
    let itemID=UUID();var navigation:AnyObject?=ChromiumPageNavigation()
    var nativeNavigationSerial:UInt64=1
    var nativeAgentNavigationIsPending=false
    struct Controller { var settings = BrowserManager.Settings() }
    var controller: Controller? = Controller()
    var usesNativePageHost=true,nativeIsEnding=false
    var isAgentPage = false
    var waitHook:(()->Void)?
    func waitForNativeAgentNavigation(in window:BrowserWindowState,reload:Bool,while current:@MainActor()->Bool) async -> Bool {
        precondition(!reload);guard current() else{return false};waitHook?();nativeAgentNavigationIsPending=false;return current()
    }
}
@MainActor final class FixtureWindow { var attachedSheet: FixtureWindow? }
@MainActor enum NSApp { static var keyWindow: FixtureWindow? }
@MainActor final class BrowserWindowState {
    let id=UUID();let selected=UUID();let space=UUID()
    var window: FixtureWindow? = FixtureWindow()
    var isIncognito = false
    var privateTree: Int? { isIncognito ? 1 : nil }
}
@MainActor final class Registry {
    var windows:[UUID:BrowserWindowState]=[:]
    var activeWindow: BrowserWindowState?
}
@MainActor final class Tabs {
    var page=PageSession(),available=true
    var regularWindows: [BrowserWindowState] = []
    var nativePageHost: Tabs? { self }
    func isNativeSelection(_ navigation: ChromiumPageNavigation, in window: BrowserWindowState) -> Bool {
        available && navigation === page.navigation
    }
    func prepareNativeAgentPage(in window:BrowserWindowState) async -> PageSession? {available ? page:nil}
    func existingNativeAgentPage(in window:BrowserWindowState)->PageSession? {available && !page.nativeIsEnding ? page:nil}
}
@MainActor final class BrowserManager {
    enum Engine { case chromium }
    struct Settings { var developerModeEnabled = true }
    let tabs=Tabs();var windowRegistry:Registry?=Registry()
    let engine = Engine.chromium
    var nookSettings: Settings? = Settings()
    var handedOff: [DevPick] = []
    func frontPage(in window: BrowserWindowState) -> PageSession? { tabs.page }
    func handOff(_ pick: DevPick) { handedOff.append(pick) }
    func showDevToast(_ text: String) {}
}
@main struct Main {
    @MainActor static func main() async throws {
        let manager=BrowserManager(),window=BrowserWindowState(),server=SnapshotFixture()
        manager.windowRegistry!.windows[window.id]=window
        let page=manager.tabs.page,navigation=page.navigation as! ChromiumPageNavigation
        let first=try await server.nativeSnapshot([:],browserManager:manager,window:window)
        precondition(first["text"] as? String==navigation.result.text && server.cacheCount==1)
        let same=try await server.nativeSnapshot([:],browserManager:manager,window:window)
        precondition(same["text"] as? String=="No change since the last snapshot.")
        let prior=navigation.result.text
        navigation.result.text="- main\n  - button \"Changed\""
        let changed=try await server.nativeSnapshot([:],browserManager:manager,window:window)
        precondition(changed["text"] as? String==DevHandoff.snapshotDiff(old:prior,new:navigation.result.text))
        let full=try await server.nativeSnapshot(["full":true],browserManager:manager,window:window)
        precondition(full["text"] as? String==navigation.result.text)
        let selector="button[data-x=\"quote\\line\"]"
        _=try await server.nativeSnapshot(["selector":selector,"maxDepth":100,"maxNodes":9_999],browserManager:manager,window:window)
        let literal=String(decoding:try JSONSerialization.data(withJSONObject:selector,options:.fragmentsAllowed),as:UTF8.self)
        precondition(navigation.calls.last!.hasSuffix("snapshot(\(literal), 40, 2000);"))
        precondition(!navigation.calls.last!.contains(".__nookDevPicker.start("))
        let count=navigation.calls.count
        page.controller?.settings.developerModeEnabled=false
        let disabled=try await server.nativeSnapshot([:],browserManager:manager,window:window)
        precondition(disabled["isError"] as? Bool==true)
        precondition(navigation.calls.count==count)
        page.controller?.settings.developerModeEnabled=true;server.isPermitted=false
        _=try await server.nativeSnapshot([:],browserManager:manager,window:window)
        precondition(navigation.calls.count==count)
        server.isPermitted=true;navigation.result.isString=false;navigation.result.json="null"
        let missing=try await server.nativeSnapshot(["selector":"#missing"],browserManager:manager,window:window)
        precondition(missing["text"] as? String=="Nothing matches #missing.")
        navigation.result.isString=true;navigation.result.json=""
        for action in ["document","owner","profile","binding","window","ending","shutdown"] {
            server.reset();page.navigation=navigation;page.nativeIsEnding=false
            navigation.nativeWindowID=10;navigation.profileID=UUID()
            manager.windowRegistry!.windows[window.id]=window
            navigation.hook={
                switch action {
                case "document":page.nativeNavigationSerial+=1
                case "owner":navigation.nativeWindowID=11
                case "profile":navigation.profileID=UUID()
                case "binding":page.navigation=ChromiumPageNavigation()
                case "window":manager.windowRegistry!.windows.removeValue(forKey:window.id)
                case "ending":page.nativeIsEnding=true
                default:server.reset()
                }
            }
            let stale=try await server.nativeSnapshot([:],browserManager:manager,window:window)
            precondition(stale["isError"] as? Bool==true && server.cacheCount==0,action)
        }
        navigation.hook=nil;page.navigation=navigation;page.nativeIsEnding=false
        manager.windowRegistry!.windows[window.id]=window;server.reset()
        for _ in 0..<20 {
            page.nativeNavigationSerial+=1
            let fresh=try await server.nativeSnapshot([:],browserManager:manager,window:window)
            precondition(fresh["text"] as? String==navigation.result.text && server.cacheCount==1)
        }
        server.reset();page.navigation=navigation;page.nativeIsEnding=false
        navigation.screenshotHook=nil;navigation.nativeWindowID=10
        manager.windowRegistry!.windows[window.id]=window
        let originalSelection=window.selected,originalSpace=window.space
        let image=try await server.nativeScreenshot([:],browserManager:manager,window:window)
        let content=image["content"] as! [[String:Any]]
        precondition((content[0]["text"] as! String).contains("Last rendered viewport"))
        precondition(content[1]["mimeType"] as? String=="image/jpeg")
        precondition(Data(base64Encoded:content[1]["data"] as! String)==Data([255,216,255,217]))
        precondition(navigation.screenshotWidths == [1200])
        precondition(window.selected==originalSelection && window.space==originalSpace)
        for value:Any in [0,-1,4097,1.5,Double.nan,Double.infinity,true,"1200"] {
            let result=try await server.nativeScreenshot(["maxWidth":value],browserManager:manager,window:window)
            precondition(result["isError"] as? Bool==true)
        }
        precondition(navigation.screenshotWidths == [1200])
        server.isPermitted=false
        _=try await server.nativeScreenshot([:],browserManager:manager,window:window)
        precondition(navigation.screenshotWidths.count==1)
        server.isPermitted=true
        page.nativeAgentNavigationIsPending=true
        page.waitHook={page.nativeNavigationSerial+=1}
        _=try await server.nativeScreenshot(["maxWidth":2048],browserManager:manager,window:window)
        precondition(navigation.screenshotWidths.last==2048 && !page.nativeAgentNavigationIsPending)
        page.waitHook=nil
        for action in ["document","owner","profile","binding","window","ending","shutdown","permission"] {
            server.reset();page.navigation=navigation;page.nativeIsEnding=false
            navigation.nativeWindowID=10;navigation.profileID=UUID()
            manager.windowRegistry!.windows[window.id]=window
            navigation.screenshotHook={
                switch action {
                case "document":page.nativeNavigationSerial+=1
                case "owner":navigation.nativeWindowID=11
                case "profile":navigation.profileID=UUID()
                case "binding":page.navigation=ChromiumPageNavigation()
                case "window":manager.windowRegistry!.windows.removeValue(forKey:window.id)
                case "ending":page.nativeIsEnding=true
                case "permission":server.isPermitted=false
                default:server.reset()
                }
            }
            let stale=try await server.nativeScreenshot([:],browserManager:manager,window:window)
            precondition(stale["isError"] as? Bool==true,action)
        }
        server.reset();server.isPermitted=true;page.navigation=navigation;page.nativeIsEnding=false
        manager.windowRegistry!.windows[window.id]=window
        navigation.screenshotHook=nil;navigation.screenshotFailure=true
        let unavailable=try await server.nativeScreenshot([:],browserManager:manager,window:window)
        precondition(unavailable["isError"] as? Bool==true && (unavailable["text"] as! String).contains("Screenshot unavailable") &&
            (unavailable["text"] as! String).contains("unsupported output dimensions"))
        precondition(window.selected==originalSelection && window.space==originalSpace)
        print("Native screenshot helper: JPEG/last-rendered label,1200 default,bounds,Agent wait,authorization and stale ownership passed")
        print("Native snapshot: isolated dormant source, caps/diff, permission gates, exact ownership/stale cache and bounded navigation slots passed")
        await checkNativePicker()
    }

    @MainActor static func checkNativePicker() async {
        let manager = BrowserManager(), window = BrowserWindowState(), server = SnapshotFixture()
        manager.windowRegistry!.windows[window.id] = window
        manager.windowRegistry!.activeWindow = window
        NSApp.keyWindow = window.window
        server.humanWindow = window
        server.browserManager = manager
        let page = manager.tabs.page, navigation = page.navigation as! ChromiumPageNavigation
        navigation.result.json = ##"{"url":"https://design.test","selector":"#save","tag":"button","rect":{}}"##
        let passed = await server.callTool("pick", [:])
        precondition(passed["isError"] as? Bool == false && (passed["text"] as? String)?.contains("#save") == true)
        precondition(navigation.worlds == [.isolated, .page])
        precondition(navigation.calls == [DevPickerScript.describeScript(selector: "#save"),
                                          DevPickerScript.hintsScript(selector: "#save")])
        precondition(manager.handedOff.count == 1)
        let selected = await server.callTool("selection", [:])
        precondition(selected["text"] as? String == passed["text"] as? String)

        page.nativeNavigationSerial += 1
        let expired = await server.callTool("selection", [:])
        precondition(expired["isError"] as? Bool == true)
        for state in ["disabled", "permission", "inactive", "private", "sheet"] {
            manager.nookSettings?.developerModeEnabled = state != "disabled"
            server.isPermitted = state != "permission"
            NSApp.keyWindow = state == "inactive" ? FixtureWindow() : window.window
            window.isIncognito = state == "private"
            window.window?.attachedSheet = state == "sheet" ? FixtureWindow() : nil
            let refused = await server.callTool("pick", [:])
            precondition(refused["isError"] as? Bool == true && navigation.pickerStarts == 1, state)
        }
        window.window?.attachedSheet = nil
        navigation.pickerHook = { page.nativeNavigationSerial += 1 }
        let stale = await server.callTool("pick", [:])
        precondition(stale["isError"] as? Bool == true && navigation.calls.count == 2)
        navigation.pickerHook = nil
        navigation.hook = { server.reset() }
        let stopped = await server.callTool("pick", [:])
        precondition(stopped["isError"] as? Bool == true && manager.handedOff.count == 1)
        navigation.hook = nil
        navigation.pickerHook = { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelled = await Task { await server.callTool("pick", [:]) }.value
        precondition(cancelled["isError"] as? Bool == true && manager.handedOff.count == 1)
        print("Dev MCP Chromium pick and selection passed active-page routing, policy and stale reply checks")
    }
}
