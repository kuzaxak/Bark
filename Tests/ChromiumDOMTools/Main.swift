// Licensed under GPL-3.0. See LICENSE.
// Compiles the shipped fixed-tool/helper bodies verbatim; only app/transport
// surroundings are stubbed. The actual adapter/module has separate checks.
import Foundation
@MainActor final class ChromiumPageNavigation {
    enum ScriptMode { case expression, asyncBody }; enum ScriptWorld { case page }
    enum ScriptError: Error { case unavailable, cancelled, unserializable }
    struct ScriptResult { var isUndefined=false, isString=false; var text="",json="" }
    struct State { var isLoading=false }
    var state=State(),isClosed=false
    var nativeWindowID:Int32=10,nativeTabID:Int32=20
    var profileID:UUID?=UUID()
    var result=ScriptResult()
    var calls:[(String,ScriptMode,ScriptWorld)]=[]
    var fail=false
    var onReply: (() -> Void)?
    func evaluateScript(_ source:String,mode:ScriptMode,world:ScriptWorld) async throws -> ScriptResult {
        calls.append((source,mode,world));if fail { throw ScriptError.cancelled };onReply?();return result
    }
}
@MainActor final class PageSession {
    var navigation:AnyObject?=ChromiumPageNavigation()
    var nativeNavigationSerial:UInt64=1
    var isLoading=false,nativeAgentNavigationIsPending=false
    var waitHook:(()->Void)?
    func waitForNativeAgentNavigation(in window:BrowserWindowState,reload:Bool,while current:@MainActor()->Bool) async -> Bool {
        precondition(!reload);guard current() else {return false}
        waitHook?();nativeAgentNavigationIsPending=false;isLoading=false
        (navigation as? ChromiumPageNavigation)?.state.isLoading=false
        return current()
    }
}
@MainActor final class BrowserWindowState { let id=UUID();var selectedItemID:UUID?=UUID(),spaceID=UUID() }
@MainActor final class Registry {var windows:[UUID:BrowserWindowState]=[:]}
@MainActor final class Tabs {
    var page=PageSession();var available=true;var prepares=0
    func existingNativeAgentPage(in window:BrowserWindowState)->PageSession? {available ? page:nil}
    func controllableSession(in window:BrowserWindowState)->PageSession? {available ? page:nil}
    func prepareNativeAgentPage(in window:BrowserWindowState) async -> PageSession? {prepares+=1;return available ? page:nil}
}
@MainActor final class BrowserManager {
    let tabs=Tabs()
    var windowRegistry:Registry?=Registry()
}
enum AppleIntelligenceProvider {
    static let toolOutputTokens=400
    static func fitted(_ text:String,tokens:Int)->String {String(text.prefix(tokens))}
}
@main struct Main {
    @MainActor static func main() async throws {
        let manager=BrowserManager(),window=BrowserWindowState(),tools=ToolFixture()
        manager.windowRegistry!.windows[window.id]=window
        let native=manager.tabs.page.navigation as! ChromiumPageNavigation
        let selected=window.selectedItemID,space=window.spaceID
        native.result = .init(json:"{\"title\":\"Fixture\",\"url\":\"https://work.test/\",\"content\":\"Draft remains\"}")
        let read=try await tools.executeReadPageContent([:],browserManager:manager,windowState:window)
        precondition(read=="Title: Fixture\nURL: https://work.test/\n\nDraft remains")
        native.result = .init(isString:true,text:"Clicked element: Button")
        let click=try await tools.executeClickElement(["selector":"button[data-x=\"quoted\"]"],browserManager:manager,windowState:window)
        precondition(click=="Clicked element: Button")
        native.result = .init(isString:true,text:"[{\"selector\":\"button\"}]")
        let elements=try await tools.executeGetInteractiveElements([:],browserManager:manager,windowState:window)
        precondition(elements==native.result.text)
        native.result = .init(isString:true,text:"{\"description\":\"Fixture\"}")
        let extract=try await tools.executeExtractStructuredData(["type":"meta"],browserManager:manager,windowState:window)
        precondition(extract==native.result.text)
        native.result = .init(json:"{\"title\":\"Summary\",\"url\":\"https://work.test/\",\"content\":\"Summary text\"}")
        let summary=try await tools.executeSummarizePage(browserManager:manager,windowState:window)
        precondition(summary=="Title: Summary\nURL: https://work.test/\n\nSummary text")
        native.result = .init(isString:true,text:"{\"count\":1,\"matches\":[]}")
        let query="quote\"; throw Error('injected') //\nnext"
        let search=try await tools.executeSearchInPage(["query":query],browserManager:manager,windowState:window)
        precondition(search==native.result.text)
        let literal=String(decoding:try JSONSerialization.data(withJSONObject:query,options:.fragmentsAllowed),as:UTF8.self)
        precondition(native.calls.last!.0.hasPrefix("const query = \(literal);\n"))
        precondition(native.calls.last!.1 == .asyncBody)
        native.result = .init(isString:true,text:"selected\0text")
        let selection=try await tools.executeGetSelectedText(browserManager:manager,windowState:window)
        precondition(selection=="selected\0text")
        precondition(native.calls.count==7 && native.calls.allSatisfy{$0.2 == .page})
        precondition(window.selectedItemID==selected && window.spaceID==space && manager.windowRegistry!.windows.count==1)
        let before=native.calls.count
        manager.tabs.available=false
        do {_=try await tools.executeReadPageContent([:],browserManager:manager,windowState:window);preconditionFailure("unavailable owner") } catch {}
        precondition(native.calls.count==before)
        manager.tabs.available=true;manager.tabs.page.nativeAgentNavigationIsPending=true
        manager.tabs.page.waitHook={manager.windowRegistry!.windows.removeValue(forKey:window.id)}
        do {_=try await tools.executeGetSelectedText(browserManager:manager,windowState:window);preconditionFailure("window removed") } catch {}
        precondition(native.calls.count==before)
        manager.windowRegistry!.windows[window.id]=window
        let profile = native.profileID
        manager.tabs.page.nativeAgentNavigationIsPending=true
        manager.tabs.page.waitHook={native.profileID=UUID()}
        do {_=try await tools.executeGetSelectedText(browserManager:manager,windowState:window);preconditionFailure("profile changed during preparation") } catch {}
        precondition(native.calls.count==before)
        native.profileID=profile;manager.tabs.page.waitHook=nil
        manager.tabs.page.nativeAgentNavigationIsPending=true;native.result = .init(isString:true,text:"after settle")
        let settled=try await tools.executeGetSelectedText(browserManager:manager,windowState:window)
        precondition(settled=="after settle" && native.calls.count==before+1)
        tools.agentSpace=nil
        native.result = .init(isString:true,text:"exact controllable page")
        let prepares=manager.tabs.prepares
        let controllableSelection=try await tools.executeGetSelectedText(browserManager:manager,windowState:window)
        precondition(controllableSelection=="exact controllable page" && manager.tabs.prepares==prepares)
        // An existing controllable document remains usable while its subresources
        // load. This is immediate dispatch, not an approval-time target capture.
        manager.tabs.page.isLoading=true;native.state.isLoading=true
        native.result = .init(json:"{\"title\":\"Loading\",\"url\":\"https://work.test/\",\"content\":\"Existing document\"}")
        let loadingRead=try await tools.executeReadPageContent([:],browserManager:manager,windowState:window)
        precondition(loadingRead=="Title: Loading\nURL: https://work.test/\n\nExisting document")
        precondition(native.calls.count==before+3)
        manager.tabs.page.isLoading=false;native.state.isLoading=false
        // Model a transport that completes synchronously just as its task is
        // cancelled, before the native adapter's queued cancellation handler runs.
        var request: Task<String, Error>!
        native.onReply={request.cancel()}
        request=Task { try await tools.executeGetSelectedText(browserManager:manager,windowState:window) }
        do {_=try await request.value;preconditionFailure("cancelled result must not publish")}
        catch is CancellationError {}
        native.onReply=nil
        native.fail=true
        do {_=try await tools.executeGetSelectedText(browserManager:manager,windowState:window);preconditionFailure("native cancellation") } catch {}
        precondition(window.selectedItemID==selected && window.spaceID==space)
        native.fail=false;tools.agentSpace=nil
        try await checkPageContext(manager:manager,window:window,tools:tools)
        print("Seven fixed DOM tools: native route, formatting, escaped query, exact hidden ownership and cancellation passed")
        print("Page context: exact selected page and refused ownership changes passed")
    }
}

@MainActor func checkPageContext(manager:BrowserManager,window:BrowserWindowState,tools:ToolFixture) async throws {
    let context=ContextFixture();context.browserManager=manager;context.browserToolExecutor=tools
    let page=manager.tabs.page,native=page.navigation as! ChromiumPageNavigation
    let reply=ChromiumPageNavigation.ScriptResult(json:"{\"title\":\"Draft\",\"url\":\"https://work.test/a\",\"content\":\"Body words\",\"selection\":\"picked\",\"truncated\":true}")
    native.result=reply
    func read() async -> String { await context.extractPageContext(windowState:window,tag:"ctx",canSearch:true) }

    var count=native.calls.count
    let text=await read()
    precondition(text=="""
    <ctx>
    <title>Draft</title>
    <url>https://work.test/a</url>
    <content>
    Body words
    </content>
    <selected_text>
    picked
    </selected_text>
    </ctx>

    The page text above is only the start of the page. Use searchInPage to look for anything further down.

    User Question:\u{20}
    """,text)
    precondition(native.calls.count==count+1)
    precondition(native.calls.last!.1 == .expression && native.calls.last!.2 == .page)

    page.isLoading=true;native.state.isLoading=true
    var seen=await read();precondition(seen.contains("Body words"),"an existing document stays readable while it loads")
    page.isLoading=false;native.state.isLoading=false

    let selectedID=window.selectedItemID,profile=native.profileID
    func refuses(_ name:String,change:@escaping ()->Void,restore:()->Void) async {
        count=native.calls.count
        native.onReply=change
        let result=await read()
        native.onReply=nil
        restore()
        precondition(native.calls.count==count+1,name)
        precondition(result=="",name+" must refuse the reply")
    }
    await refuses("selection moved",change:{manager.tabs.page=PageSession()},restore:{manager.tabs.page=page})
    await refuses("selection unavailable",change:{manager.tabs.available=false},restore:{manager.tabs.available=true})
    await refuses("document changed",change:{page.nativeNavigationSerial+=1},restore:{})
    await refuses("binding replaced",change:{page.navigation=ChromiumPageNavigation()},restore:{page.navigation=native})
    await refuses("tab replaced",change:{native.nativeTabID=21},restore:{native.nativeTabID=20})
    await refuses("owner replaced",change:{native.nativeWindowID=11},restore:{native.nativeWindowID=10})
    await refuses("profile replaced",change:{native.profileID=UUID()},restore:{native.profileID=profile})
    await refuses("closed",change:{native.isClosed=true},restore:{native.isClosed=false})
    await refuses("window removed",change:{manager.windowRegistry!.windows.removeValue(forKey:window.id)},restore:{manager.windowRegistry!.windows[window.id]=window})
    precondition(window.selectedItemID==selectedID)

    count=native.calls.count
    manager.tabs.available=false
    seen=await read();precondition(seen=="","no selected page")
    manager.tabs.available=true
    native.isClosed=true
    seen=await read();precondition(seen=="","closed page")
    native.isClosed=false
    precondition(native.calls.count==count,"nothing dispatched without a page")

    native.fail=true
    seen=await read();precondition(seen=="","transport failure")
    native.fail=false
    native.result = .init(json:"[1]")
    seen=await read();precondition(seen=="","unexpected shape")
    native.result=reply


}
