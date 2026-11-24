// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped performNativePageCommand; the app around it is stubbed.
import Foundation

enum ChromiumSiteDataOutcome { case cleared, failed }
@MainActor final class NativeWindow {}
@MainActor enum CommandWindow { static var key: NativeWindow? }
@MainActor final class ChromiumPageNavigation {
    var nativeWindowID: Int32 = 1
    let nativeTabID: Int32
    var supportsTranslation = true, supportsElementPicker = true
    var performed: [PageCommand] = []
    init(tab: Int32) { nativeTabID = tab }
    func performNativePageCommand(_ command: PageCommand,
                                  completion: @escaping @MainActor (ChromiumSiteDataOutcome) -> Void = { _ in }) -> Bool {
        performed.append(command)
        return true
    }
}
@MainActor final class PageSession {
    let navigation: AnyObject?
    var url: URL
    var nativeNavigationSerial: UInt64 = 1
    var isDetached = false, canTranslate = true, isTranslated = false
    var backs = 0
    init(tab: Int32, url: String) {
        navigation = ChromiumPageNavigation(tab: tab)
        self.url = URL(string: url)!
    }
    var native: ChromiumPageNavigation { navigation as! ChromiumPageNavigation }
    func goBack() { backs += 1 }
    func toggleTranslation() { isTranslated.toggle() }
}
@MainActor final class BrowserWindowState {
    let id = UUID()
    var window: NativeWindow? = NativeWindow()
}
@MainActor final class WindowRegistry {
    var windows: [UUID: BrowserWindowState] = [:]
    var activeWindow: BrowserWindowState?
}
@MainActor final class NativeHost {
    var selection: ChromiumPageNavigation?
    func isNativeSelection(_ page: ChromiumPageNavigation, in window: BrowserWindowState) -> Bool { page === selection }
}
@MainActor final class Tabs { var nativePageHost: NativeHost? = NativeHost() }
@MainActor final class PeekManager {
    var selection: PageSession?
    func isNativeSelection(_ page: PageSession, in window: BrowserWindowState) -> Bool { page === selection }
}
@MainActor final class BrowserManager {
    var windowRegistry: WindowRegistry? = WindowRegistry()
    let tabs = Tabs(), peekManager = PeekManager()
    var front: PageSession?
    var toasts: [String] = [], boostPanels = 0
    var developerSites: [URL] = [], picked: [PageSession] = [], copiedURLs: [URL] = [], screenshots: [PageSession] = []
    func frontPage(in window: BrowserWindowState) -> PageSession? { front }
    func openBoostPanel(in window: BrowserWindowState) { boostPanels += 1 }
    func toggleDeveloperSite(of page: PageSession, in window: BrowserWindowState) { developerSites.append(page.url) }
    func withDeveloperCapture(_ action: () -> Void) { action() }
    func pickNativeElement(on page: PageSession, navigation: ChromiumPageNavigation, in window: BrowserWindowState) async {
        picked.append(page)
    }
    func showWindowToast(_ text: String, in window: BrowserWindowState) { toasts.append(text) }
    func copyURL(of page: PageSession, in window: BrowserWindowState) { copiedURLs.append(page.url) }
    func copyNativeScreenshot(of page: PageSession, in window: BrowserWindowState) async { screenshots.append(page) }
}

@MainActor func settle(until done: () -> Bool) async {
    for _ in 0..<1000 where !done() { await Task.yield() }
}

@main struct Check {
    @MainActor static func main() async {
        let manager = BrowserManager(), window = BrowserWindowState()
        let tab = PageSession(tab: 2, url: "https://source.test/list")
        let peek = PageSession(tab: 3, url: "https://peek.test/item")
        peek.isDetached = true
        manager.windowRegistry?.windows[window.id] = window
        manager.windowRegistry?.activeWindow = window
        CommandWindow.key = window.window
        // As in Chromium with a Peek card mounted: the window's ordinary layout still holds the
        // source tab, and the engine's selection is the card's page.
        manager.tabs.nativePageHost?.selection = tab.native
        manager.front = peek
        manager.peekManager.selection = peek

        let onPeekPage: [PageCommand] = [.reload, .hardReload, .goForward, .find, .print, .webInspector, .developerConsole,
                                         .developerNetwork, .developerPerformance, .pictureInPicture, .mute,
                                         .zoomIn, .zoomOut, .actualSize, .clearSiteCookies, .clearSiteCache, .clearCookiesAndReload]
        for command in onPeekPage {
            precondition(manager.performNativePageCommand(command, in: window, page: peek) && peek.native.performed.last == command,
                         "\(command) runs on the Peek in front")
        }
        precondition(manager.performNativePageCommand(.goBack, in: window, page: peek) && peek.backs == 1, "Back goes back in the Peek")
        precondition(manager.performNativePageCommand(.copyURL, in: window, page: peek) && manager.copiedURLs == [peek.url],
                     "Copy URL copies the Peek's address")
        precondition(manager.performNativePageCommand(.copyScreenshot, in: window, page: peek))
        await settle { !manager.screenshots.isEmpty }
        precondition(manager.screenshots.count == 1 && manager.screenshots[0] === peek, "Copy Screenshot captures the Peek")
        precondition(manager.performNativePageCommand(.pickElement, in: window, page: peek))
        await settle { !manager.picked.isEmpty }
        precondition(manager.picked.count == 1 && manager.picked[0] === peek, "Pick Element picks in the Peek")
        precondition(manager.performNativePageCommand(.developerMode, in: window, page: peek) && manager.developerSites == [peek.url],
                     "Developer Mode turns on for the Peek's site")
        precondition(manager.performNativePageCommand(.boost, in: window, page: peek) && manager.boostPanels == 1,
                     "Boost opens its panel, which edits the page in front")
        precondition(tab.native.performed.isEmpty && tab.backs == 0 && manager.toasts.isEmpty, "the tab under the Peek is untouched")

        let ran = peek.native.performed.count
        manager.peekManager.selection = nil
        precondition(!manager.performNativePageCommand(.reload, in: window, page: peek) && peek.native.performed.count == ran,
                     "a Peek card Chromium does not present refuses commands")
        precondition(!manager.performNativePageCommand(.reload, in: window, page: tab) && tab.native.performed.isEmpty,
                     "the tab under a Peek is not the page in front")
        manager.peekManager.selection = peek
        manager.front = tab
        manager.tabs.nativePageHost?.selection = nil
        precondition(!manager.performNativePageCommand(.reload, in: window, page: tab) && tab.native.performed.isEmpty,
                     "a Peek selection never stands in for its tab")
        manager.tabs.nativePageHost?.selection = tab.native
        precondition(manager.performNativePageCommand(.reload, in: window, page: tab) && tab.native.performed == [.reload],
                     "with no Peek in front the selected tab runs the command")
        precondition(peek.native.performed.count == ran)
        print("Chromium front page commands: \(onPeekPage.count + 6) commands on a Peek, refusals and the selected tab PASS")
    }
}
