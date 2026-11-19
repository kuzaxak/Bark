// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import WebKit
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
@testable import NookWeb

/// A tab opened from a link in the background loads at once, as in Arc; a tab made in the
/// background any other way waits until it is selected.
@MainActor
struct BackgroundLinkTabTests {
    // `.invalid` never resolves, so no favicon reaches the shared favicon cache.
    let link = URL(string: "https://link.invalid/article")!

    @Test func linkOpenedInBackgroundLoadsAndKeepsSelection() throws {
        let host = try Host()
        let opener = try #require(host.window.selectedItemID)
        let openerPage = try #require(host.tabs.ensureSession(for: opener))
        let before = host.items()

        openerPage.openInNewTab(link)

        let child = try #require(host.items().subtracting(before).first)
        #expect(host.window.selectedItemID == opener)
        let page = try #require(host.tabs.session(for: child))
        #expect(!page.isUnloaded)
        #expect((page.primaryWebView as? RecordingWebView)?.requested == [link])
        #expect(host.backgroundLoads == [child])
    }

    @Test func linkOpenedInBackgroundInPrivateWindowLoads() throws {
        let host = try Host(isPrivate: true)
        let spaceID = try #require(host.window.spaceID)
        let opener = try #require(host.tabs.open(url: URL(string: "https://opener.invalid")!, in: host.window,
                                                 placement: .newTab, parent: .tabs(spaceID: spaceID)))
        let openerPage = try #require(host.tabs.session(for: opener))
        let before = host.items()

        openerPage.openInNewTab(link)

        let child = try #require(host.items().subtracting(before).first)
        #expect(host.window.selectedItemID == opener)
        let page = try #require(host.tabs.session(for: child))
        #expect(page.isPrivate)
        #expect((page.primaryWebView as? RecordingWebView)?.requested == [link])
    }

    @Test func legacyWebKitObserverReceivesOpenTitleAndClose() throws {
        let host = try Host()
        let observer = RecordingWebKitTabEvents()
        host.tabs.tabEvents = observer
        let space = try #require(host.window.spaceID)
        let id = try #require(host.tabs.open(url: link, in: host.window, placement: .newTab,
                                            parent: .tabs(spaceID: space)))
        let page = try #require(host.tabs.session(for: id))
        page.updateTitle("Fixture title")
        host.tabs.close(id)
        #expect(observer.opened.contains(id) && observer.activated.contains(id))
        #expect(observer.changed.contains(id))
        #expect(observer.closed.contains(id))
    }

    @Test func backgroundTabWithoutOpenerWaitsForSelection() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)

        let imported = try #require(host.tabs.open(url: link, in: host.window, placement: .background,
                                                   parent: .tabs(spaceID: spaceID)))

        #expect(host.tabs.session(for: imported)?.isUnloaded ?? true)
        #expect(host.backgroundLoads.isEmpty)
    }
}

/// A TabsController with one window, on a throwaway directory, whose web views record loads
/// instead of navigating.
@MainActor
final class Host {
    let tabs: TabsController
    let window = BrowserWindowState()
    let registry = WindowRegistry()
    let webViews = RecordingWebViews()
    /// Pages the app's unload policy was told about.
    private(set) var backgroundLoads: [UUID] = []

    init(isPrivate: Bool = false, engine: Profile.Engine = .webKit) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookWebTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = NookSettingsService()
        tabs = TabsController(
            settings: settings, windowRegistry: registry, blocker: ContentBlockerManager(settings: settings),
            sponsorBlock: SponsorBlockManager(settings: settings), siteRouting: SiteRoutingManager(settings: settings),
            profileEngine: engine, directory: directory)
        tabs.loadsWebKitFavicons = false
        if engine == .webKit { tabs.webViews = webViews }
        tabs.onPageLoadedInBackground = { [weak self] in self?.backgroundLoads.append($0.itemID) }
        if isPrivate {
            window.isIncognito = true
            window.ephemeralProfile = Profile.createEphemeral(engine: engine)
        }
        registry.register(window)
        registry.setActive(window)
        tabs.attach(window: window)
    }

    /// The items of the tree this window shows.
    func items() -> Set<UUID> {
        Set((window.privateTree ?? tabs.tree).items.keys)
    }
}

@MainActor
final class RecordingWebViews: WebKitWebViewProvider {
    func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        RecordingWebView(frame: .zero, configuration: configuration)
    }
    func webView(for itemID: UUID, in windowID: UUID) -> WKWebView? { nil }
    func allWebViews(for itemID: UUID) -> [WKWebView] { [] }
    func releaseWebViews(for session: PageSession) {}
    func removeFromContainers(_ webView: WKWebView) {}
}

final class RecordingWebView: WKWebView, SessionWebView {
    weak var owningSession: PageSession?
    var contextMenuBridge: WebContextMenuBridge?
    private(set) var requested: [URL] = []

    func contextMenuPayloadDidUpdate(_ payload: WebContextMenuPayload?) {}

    override func load(_ request: URLRequest) -> WKNavigation? {
        request.url.map { requested.append($0) }
        return nil
    }
}

@MainActor
final class RecordingWebKitTabEvents: WebKitTabEventObserver {
    private(set) var opened: [UUID] = []
    private(set) var activated: [UUID] = []
    private(set) var changed: [UUID] = []
    private(set) var closed: [UUID] = []
    private(set) var granted: [URL] = []
    var nativeController: WKWebExtensionController? { nil }
    func tabOpened(_ session: PageSession) { opened.append(session.itemID) }
    func tabActivated(new session: PageSession, previous: PageSession?) { activated.append(session.itemID) }
    func tabClosed(itemID: UUID) { closed.append(itemID) }
    func tabMoved(itemID: UUID, from oldIndex: Int?, in oldWindow: BrowserWindowState?, pinnedChanged: Bool) {}
    func tabPropertiesChanged(_ session: PageSession, properties: WKWebExtension.TabChangedProperties) {
        if properties.contains(.title) { changed.append(session.itemID) }
    }
    func grantAccess(to url: URL) { granted.append(url) }
    func wakeBackgroundWorkers() {}
    func diagnose(for webView: WKWebView, url: URL) {}
}
