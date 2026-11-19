// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped certificate, clear, zoom and site setting methods, and the Developer Mode and Boost writers;
// the app around them is stubbed.
import Foundation

enum PageCommand { case clearSiteCookies, clearSiteCache, zoomIn, zoomOut }
@MainActor final class ChromiumPageNavigation {
    enum ScriptMode { case expression }; enum ScriptWorld { case isolated }
    struct ScriptResult { let json: String }
    var ratio = "2", calls = 0
    var certificateCalls = 0
    var nativeWindowID: Int32 = 1, nativeTabID: Int32 = 2
    var certificateAvailable = true
    func showCertificate() -> Bool { certificateCalls += 1; return certificateAvailable }
    var beforeReply: (() -> Void)?
    func evaluateScript(_ source: String, mode: ScriptMode, world: ScriptWorld) async throws -> ScriptResult {
        calls += 1
        precondition(source == "devicePixelRatio")
        beforeReply?()
        return ScriptResult(json: ratio)
    }
}
@MainActor final class PageSession {
    let itemID = UUID()
    var url = URL(string: "https://work.test/a")!
    var isLoading = false
    var nativeNavigationSerial: UInt64 = 1
    var navigation: AnyObject? = ChromiumPageNavigation()
}
@MainActor final class NSWindowStub { var backingScaleFactor = 2.0; var isKeyWindow = true }
@MainActor final class BrowserWindowState {
    var window: NSWindowStub? = NSWindowStub(); var isIncognito = false
    var isBoostPanelVisible = false, boostPanelOpensLibrary = false
    var isExtensionLibraryVisible = true
}
@MainActor final class WindowRegistry { var allWindows: [BrowserWindowState] = []; var activeWindow: BrowserWindowState? }
@MainActor final class ContentBlockerManager {
    var allowed: Set<String> = []
    @discardableResult func allowDomain(_ host: String, allowed: Bool = true, from page: PageSession?) -> Bool {
        if allowed { self.allowed.insert(host) } else { self.allowed.remove(host) }
        return true
    }
}
@MainActor final class NookSettingsService {
    var developerSites: Set<String> = []
    var developerModeEnabled = false
    func isDeveloperSite(_ host: String) -> Bool { developerSites.contains(host) }
    func setDeveloperSite(_ host: String, on: Bool) { if on { developerSites.insert(host) } else { developerSites.remove(host) } }
}
enum Boost { static func normalizeHost(_ host: String) -> String { host } }
@MainActor final class BrowserManager {
    enum Engine { case chromium, webKit }
    var engine = Engine.chromium
    var performed: [PageCommand] = []
    var onPerform: (() -> Void)?
    let contentBlockerManager = ContentBlockerManager()
    let settings = NookSettingsService()
    func perform(_ command: PageCommand) { performed.append(command); onPerform?() }
    var keyWindow: BrowserWindowState?
    func performNativePageCommand(_ command: PageCommand, in window: BrowserWindowState, page: PageSession) -> Bool {
        guard window === keyWindow, page === front else { return false }
        perform(command)
        return true
    }
    var nookSettings: NookSettingsService? { settings }
    var windowRegistry: WindowRegistry? = WindowRegistry()
    var front: PageSession?
    var toasts: [String] = []
    func frontPage(in window: BrowserWindowState) -> PageSession? { front }
    func showsDeveloperBar(in window: BrowserWindowState) -> Bool { false }
    func closeDeveloperTools(in windows: [BrowserWindowState], developerMode: Bool) {}
    func showWindowToast(_ message: String, in window: BrowserWindowState) { toasts.append(message) }
}

@main struct Main {
    @MainActor static func main() async {
        let manager = BrowserManager(), view = ViewFixture(manager), page = PageSession()
        view.currentTab = page; view.currentHost = "work.test"
        let native = page.navigation as! ChromiumPageNavigation

        manager.keyWindow = view.windowState
        manager.front = page
        manager.windowRegistry?.activeWindow = view.windowState
        let staleCertificate = view.certificateAction()!
        page.nativeNavigationSerial += 1
        staleCertificate()
        let currentCertificate = view.certificateAction()!
        let certificateWindow = view.windowState.window!
        certificateWindow.isKeyWindow = false
        currentCertificate()
        certificateWindow.isKeyWindow = true
        page.navigation = ChromiumPageNavigation()
        currentCertificate()
        page.navigation = native
        native.nativeWindowID += 1
        currentCertificate()
        native.nativeWindowID -= 1
        manager.windowRegistry?.activeWindow = BrowserWindowState()
        currentCertificate()
        manager.windowRegistry?.activeWindow = view.windowState
        view.windowState.isExtensionLibraryVisible = false
        currentCertificate()
        view.windowState.isExtensionLibraryVisible = true
        precondition(native.certificateCalls == 0 && view.dismissals == 0,
                     "the original certificate action cannot reach a successor document or owner")
        currentCertificate()
        precondition(native.certificateCalls == 1 && view.dismissals == 1,
                     "the current certificate opens once and closes Site Controls")
        native.certificateAvailable = false
        currentCertificate()
        precondition(view.dismissals == 1 && manager.toasts.last == "No certificate is available for this page.",
                     "a native refusal keeps Site Controls open and reports why")
        view.dismissals = 0
        let clearCookies = view.clearSiteDataAction(.clearSiteCookies)!
        let clearCache = view.clearSiteDataAction(.clearSiteCache)!
        clearCookies()
        clearCache()
        precondition(manager.performed == [.clearSiteCookies, .clearSiteCache], "Chromium clears through its own data path")
        precondition(view.dismissals == 2)

        manager.performed = []
        manager.keyWindow = BrowserWindowState()
        clearCache()
        manager.keyWindow = view.windowState
        let replacement = PageSession()
        view.currentTab = replacement
        manager.front = replacement
        clearCookies()
        view.currentTab = page
        manager.front = page
        page.nativeNavigationSerial += 1
        clearCache()
        let beforeTransfer = view.clearSiteDataAction(.clearSiteCookies)!
        page.navigation = ChromiumPageNavigation()
        beforeTransfer()
        page.navigation = native
        let beforeNavigation = view.clearSiteDataAction(.clearSiteCache)!
        page.url = URL(string: "https://other.test/b")!
        beforeNavigation()
        precondition(manager.performed.isEmpty && view.dismissals == 2, "stale menu commands leave both sites untouched")
        page.url = URL(string: "chrome://settings/")!
        precondition(view.clearSiteDataAction(.clearSiteCookies) == nil)
        page.url = URL(string: "https://work.test/a")!

        manager.onPerform = { native.ratio = "2.5" }
        view.zoomIn()
        precondition(manager.performed == [.zoomIn], "Chromium zooms natively")
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
        view.nativeZoomPercent = 160
        native.beforeReply = { view.currentTab = replacement }
        await view.refreshNativeZoom()
        precondition(view.nativeZoomPercent == 160, "a previous pane cannot replace the new pane’s zoom")
        view.currentTab = page
        native.beforeReply = { page.nativeNavigationSerial += 1 }
        await view.refreshNativeZoom()
        precondition(view.nativeZoomPercent == 160, "a reload retires the original document’s zoom reply")
        native.beforeReply = nil

        precondition(ChromiumPageZoom.percent(devicePixelRatio: 2, backingScale: 2) == 100)
        precondition(ChromiumPageZoom.percent(devicePixelRatio: 1.34, backingScale: 2) == 67)
        precondition(ChromiumPageZoom.percent(devicePixelRatio: 1.1, backingScale: 1) == 110)
        precondition(ChromiumPageZoom.percent(devicePixelRatio: 2, backingScale: 0) == nil)
        precondition(ChromiumPageZoom.percent(devicePixelRatio: 0, backingScale: 2) == nil)

        let windowSize = CGSize(width: 1200, height: 800)
        let centred = ChromiumSiteControlsPlacement.popover(button: CGRect(x: 600, y: 40, width: 28, height: 28), width: 300, in: windowSize, margin: 8)
        precondition(centred.origin == CGPoint(x: 464, y: 76) && centred.notchX == 150, "it hangs centred under the button")
        let left = ChromiumSiteControlsPlacement.popover(button: CGRect(x: 20, y: 50, width: 28, height: 28), width: 300, in: windowSize, margin: 8)
        precondition(left.origin == CGPoint(x: 8, y: 86) && left.notchX == 26, "a button near the edge keeps the popover in the window, its notch on the button")
        let right = ChromiumSiteControlsPlacement.popover(button: CGRect(x: 1180, y: 40, width: 16, height: 16), width: 300, in: windowSize, margin: 8)
        precondition(right.origin.x == 892 && right.notchX == 296)

        guard let blocker = view.contentBlockerToggle(for: "work.test") else { preconditionFailure("a regular window offers the blocker toggle") }
        blocker()
        precondition(manager.contentBlockerManager.allowed == ["work.test"] && !view.contentBlockerEnabled, "a regular window turns the blocker off for the site")
        view.developerModeToggle(for: "work.test")?()
        precondition(manager.settings.developerSites == ["work.test"], "a regular window turns Developer Mode on for the site")
        precondition(view.boostHost == "work.test")

        view.windowState.isIncognito = true
        manager.contentBlockerManager.allowed = []; manager.settings.developerSites = []
        precondition(view.contentBlockerToggle(for: "private.test") == nil, "a private window cannot add the site to the blocker's saved list")
        precondition(view.developerModeToggle(for: "private.test") == nil, "a private window cannot add the site to the saved developer sites")
        precondition(view.boostHost == nil, "a private window saves no Boost for the site")
        precondition(manager.contentBlockerManager.allowed.isEmpty && manager.settings.developerSites.isEmpty)

        let window = view.windowState, keyPage = PageSession()
        keyPage.url = URL(string: "https://keyed.test/")!
        manager.toggleDeveloperSite(of: keyPage, in: window)
        precondition(manager.settings.developerSites.isEmpty && manager.toasts.last == "Developer Mode isn’t available in private windows",
                     "the key and the command bar save no developer site from a private window, and say why")
        precondition(!manager.setDeveloperSite("keyed.test", on: true, in: window) && manager.settings.developerSites.isEmpty,
                     "no caller can save one from a private window")
        manager.front = keyPage
        manager.openBoostPanel(in: window)
        manager.openBoostLibrary(in: window)
        precondition(!window.isBoostPanelVisible && !window.boostPanelOpensLibrary, "a private window opens no Boost panel, so it saves no Boost")

        view.windowState.isIncognito = false
        manager.toggleDeveloperSite(of: keyPage, in: window)
        precondition(manager.settings.developerSites == ["keyed.test"] && manager.toasts.last == "Developer Mode on for keyed.test",
                     "a regular window's key turns Developer Mode on for the site")
        manager.openBoostLibrary(in: window)
        precondition(window.isBoostPanelVisible && window.boostPanelOpensLibrary, "a regular window opens the Boost library")
        window.isBoostPanelVisible = false; window.boostPanelOpensLibrary = false
        manager.settings.developerSites = []

        print("Site controls passed for document-bound certificate and clearing, zoom and private-window settings")
    }
}
