// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped clear and zoom methods verbatim; the app around them is stubbed.
import Foundation

enum PageCommand { case clearSiteCookies, clearSiteCache, zoomIn, zoomOut }
final class WKWebView {}
@MainActor final class ChromiumPageNavigation {
    enum ScriptMode { case expression }; enum ScriptWorld { case isolated }
    struct ScriptResult { let json: String }
    var ratio = "2", calls = 0
    func evaluateScript(_ source: String, mode: ScriptMode, world: ScriptWorld) async throws -> ScriptResult {
        calls += 1
        precondition(source == "devicePixelRatio")
        return ScriptResult(json: ratio)
    }
}
@MainActor final class PageSession {
    let itemID = UUID()
    var webView: WKWebView?
    var navigation: AnyObject? = ChromiumPageNavigation()
}
@MainActor final class NSWindowStub { var backingScaleFactor = 2.0 }
@MainActor final class BrowserWindowState { var window: NSWindowStub? = NSWindowStub() }
@MainActor final class CacheManager { var hosts: [String] = []; func clearCacheForDomain(_ host: String) async { hosts.append(host) } }
@MainActor final class CookieManager { var hosts: [String] = []; func deleteCookiesForDomain(_ host: String) async { hosts.append(host) } }
@MainActor final class ZoomManager {
    var calls = 0
    func zoomIn(for webView: WKWebView, tabId: UUID) { calls += 1 }
    func zoomOut(for webView: WKWebView, tabId: UUID) { calls += 1 }
}
@MainActor final class BrowserManager {
    enum Engine { case chromium, webKit }
    var engine = Engine.chromium
    var performed: [PageCommand] = []
    var onPerform: (() -> Void)?
    var cacheManager: CacheManager? = CacheManager()
    var cookieManager: CookieManager? = CookieManager()
    let zoomManager = ZoomManager()
    func perform(_ command: PageCommand) { performed.append(command); onPerform?() }
}

@main struct Main {
    @MainActor static func main() async {
        let manager = BrowserManager(), view = ViewFixture(manager), page = PageSession()
        view.currentTab = page; view.currentHost = "work.test"
        let native = page.navigation as! ChromiumPageNavigation

        view.clear(cache: false)
        view.clear(cache: true)
        await Task.yield()
        precondition(manager.performed == [.clearSiteCookies, .clearSiteCache], "Chromium clears through its own data path")
        precondition(manager.cookieManager!.hosts.isEmpty && manager.cacheManager!.hosts.isEmpty, "Chromium never reaches the WebKit stores")
        precondition(view.dismissals == 2)

        view.currentHost = nil
        manager.performed = []
        view.clear(cache: false)
        precondition(manager.performed.isEmpty, "no host, nothing cleared")
        view.currentHost = "work.test"

        manager.onPerform = { native.ratio = "2.5" }
        view.zoomIn()
        precondition(manager.performed == [.zoomIn] && manager.zoomManager.calls == 0, "Chromium zooms natively")
        for _ in 0..<40 where view.nativeZoomPercent != 125 { try? await Task.sleep(for: .milliseconds(25)) }
        precondition(view.nativeZoomPercent == 125, "the row shows the page's zoom")
        manager.onPerform = { native.ratio = "1.8" }
        view.zoomOut()
        for _ in 0..<40 where view.nativeZoomPercent != 90 { try? await Task.sleep(for: .milliseconds(25)) }
        precondition(manager.performed == [.zoomIn, .zoomOut] && view.nativeZoomPercent == 90)
        manager.onPerform = nil

        native.ratio = "not a number"
        await view.refreshNativeZoom()
        precondition(view.nativeZoomPercent == nil, "an unreadable zoom shows none")
        native.ratio = "2"
        view.windowState.window = nil
        await view.refreshNativeZoom()
        precondition(view.nativeZoomPercent == nil, "no window, no scale to read against")
        view.windowState.window = NSWindowStub()

        precondition(ChromiumPageZoom.percent(devicePixelRatio: 2, backingScale: 2) == 100)
        precondition(ChromiumPageZoom.percent(devicePixelRatio: 1.34, backingScale: 2) == 67)
        precondition(ChromiumPageZoom.percent(devicePixelRatio: 1.1, backingScale: 1) == 110)
        precondition(ChromiumPageZoom.percent(devicePixelRatio: 2, backingScale: 0) == nil)
        precondition(ChromiumPageZoom.percent(devicePixelRatio: 0, backingScale: 2) == nil)

        let window = CGSize(width: 1200, height: 800)
        let centred = ChromiumSiteControlsPlacement.popover(button: CGRect(x: 600, y: 40, width: 28, height: 28), width: 300, in: window, margin: 8)
        precondition(centred.origin == CGPoint(x: 464, y: 76) && centred.notchX == 150, "it hangs centred under the button")
        let left = ChromiumSiteControlsPlacement.popover(button: CGRect(x: 20, y: 50, width: 28, height: 28), width: 300, in: window, margin: 8)
        precondition(left.origin == CGPoint(x: 8, y: 86) && left.notchX == 26, "a button near the edge keeps the popover in the window, its notch on the button")
        let right = ChromiumSiteControlsPlacement.popover(button: CGRect(x: 1180, y: 40, width: 16, height: 16), width: 300, in: window, margin: 8)
        precondition(right.origin.x == 892 && right.notchX == 296)

        manager.engine = .webKit
        manager.performed = []
        view.clear(cache: false)
        view.clear(cache: true)
        for _ in 0..<40 where manager.cacheManager!.hosts.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(manager.performed.isEmpty && manager.cookieManager!.hosts == ["work.test"] && manager.cacheManager!.hosts == ["work.test"], "WebKit keeps its stores")
        page.webView = WKWebView()
        view.zoomIn()
        precondition(manager.zoomManager.calls == 1 && manager.performed.isEmpty, "WebKit keeps its zoom")
        print("Site controls: native clear and zoom on Chromium, WebKit unchanged")
    }
}
