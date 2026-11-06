// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookTabsCore
@testable import NookWeb

/// The sidebar's mini player, as Arc's: it shows the page playing in another tab of the window,
/// stays while that page is paused, and goes when the page closes, loses its media, another page
/// starts playing, or the person dismisses it.
struct MiniPlayerTests {
    let a = UUID(), b = UUID()

    func page(_ id: UUID, media: Bool = true, audible: Bool = false, onScreen: Bool = false) -> MiniPlayerPage {
        MiniPlayerPage(id: id, hasMedia: media, isAudible: audible, isOnScreen: onScreen)
    }

    @Test func showsThePagePlayingInAnotherTab() {
        var player = MiniPlayer()
        player.update([page(a), page(b)])
        #expect(player.itemID == nil, "media that never played")
        player.update([page(a, audible: true), page(b)])
        #expect(player.itemID == a)
    }

    @Test func hidesWhileThePageIsOnScreen() {
        var player = MiniPlayer()
        player.update([page(a, audible: true, onScreen: true)])
        #expect(player.itemID == nil)
        player.update([page(a, audible: true)])
        #expect(player.itemID == a, "leaving the tab brings the bar up")
    }

    @Test func staysWhileThePageIsPaused() {
        var player = MiniPlayer()
        player.update([page(a, audible: true)])
        player.update([page(a)])
        #expect(player.itemID == a)
    }

    @Test func goesWhenThePageClosesOrLosesItsMedia() {
        var player = MiniPlayer()
        player.update([page(a, audible: true)])
        player.update([])
        #expect(player.itemID == nil, "closed")

        player.update([page(b, audible: true)])
        player.update([page(b, media: false)])
        #expect(player.itemID == nil, "navigated to a page with no media")
        player.update([page(b)])
        #expect(player.itemID == nil, "media that has not played again")
    }

    @Test func aPageThatStartsPlayingTakesItOver() {
        var player = MiniPlayer()
        player.update([page(a, audible: true), page(b)])
        player.update([page(a, audible: true), page(b, audible: true)])
        #expect(player.itemID == b)
        player.update([page(a, audible: true), page(b)])
        #expect(player.itemID == b, "pausing keeps it")
        player.update([page(a, audible: true)])
        #expect(player.itemID == a, "closing it hands the bar to the page still playing")
    }

    @Test func aPausedPagePlayingAgainTakesItBack() {
        var player = MiniPlayer()
        player.update([page(a, audible: true), page(b)])
        player.update([page(a), page(b, audible: true)])
        #expect(player.itemID == b)
        player.update([page(a, audible: true), page(b, audible: true)])
        #expect(player.itemID == a)
    }

    @Test func anotherPlayingPageShowsWhileTheLatestIsOnScreen() {
        var player = MiniPlayer()
        player.update([page(a, audible: true), page(b)])
        player.update([page(a, audible: true), page(b, audible: true, onScreen: true)])
        #expect(player.itemID == a)
        player.update([page(a), page(b, audible: true, onScreen: true)])
        #expect(player.itemID == nil, "a paused page gives way to the one on screen")
    }

    @Test func dismissingHidesItUntilAnotherPageStartsPlaying() {
        var player = MiniPlayer()
        player.update([page(a, audible: true), page(b)])
        player.dismiss()
        #expect(player.itemID == nil)
        player.update([page(a), page(b)])
        player.update([page(a, audible: true), page(b)])
        #expect(player.itemID == nil, "the dismissed page playing again")
        player.update([page(a, audible: true), page(b, audible: true)])
        #expect(player.itemID == b)
    }

    @Test func aDismissedPageComesBackOnceItHasBeenOnScreen() {
        var player = MiniPlayer()
        player.update([page(a, audible: true)])
        player.dismiss()
        player.update([page(a, audible: true, onScreen: true)])
        player.update([page(a, audible: true)])
        #expect(player.itemID == a)
    }

    @Test func theSidebarVideoTakesItOverWhenMinimised() {
        var player = MiniPlayer()
        player.update([page(a, audible: true), page(b)])
        player.update([page(a, audible: true), page(b, audible: true)])
        player.takeOver(a)
        #expect(player.itemID == a)
    }

    /// Another window's sidebar video, adopted when that window lost focus, is not this window's page.
    @Test func anotherWindowsPageCannotTakeItOver() {
        var player = MiniPlayer()
        player.update([page(a, audible: true)])
        player.takeOver(b)
        #expect(player.itemID == a)
    }

    @Test func pagesStartingTogetherGiveTheSameBarInAnyOrder() {
        let pages = [page(a, audible: true), page(b, audible: true)]
        var forward = MiniPlayer()
        forward.update(pages)
        var backward = MiniPlayer()
        backward.update(Array(pages.reversed()))
        #expect(forward.itemID != nil)
        #expect(forward.itemID == backward.itemID)
    }
}

/// The window keeps its mini player up to date by itself, so a hidden sidebar still knows which
/// page started playing when it shows again.
@MainActor
struct MiniPlayerTrackingTests {
    @Test func followsTheWindowsPagesWithNoViewOnScreen() async throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let music = try #require(host.tabs.open(url: URL(string: "https://music.invalid")!, in: host.window,
                                                placement: .newTab, parent: .tabs(spaceID: spaceID)))
        _ = try #require(host.tabs.open(url: URL(string: "https://other.invalid")!, in: host.window,
                                        placement: .newTab, parent: .tabs(spaceID: spaceID)))
        try #require(host.tabs.session(for: music)).report(PageMedia(hasMedia: true, isAudible: true, isPlaying: true))

        for _ in 0..<100 where host.window.miniPlayer.itemID != music { await Task.yield() }
        #expect(host.window.miniPlayer.itemID == music)

        host.tabs.select(music, in: host.window)
        for _ in 0..<100 where host.window.miniPlayer.itemID != nil { await Task.yield() }
        #expect(host.window.miniPlayer.itemID == nil, "on screen again")
    }

    /// The unload policy keeps the page a bar shows loaded, so its controls keep working.
    @Test func tellsWhichPageABarShows() async throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let music = try #require(host.tabs.open(url: URL(string: "https://music.invalid")!, in: host.window,
                                                placement: .newTab, parent: .tabs(spaceID: spaceID)))
        let other = try #require(host.tabs.open(url: URL(string: "https://other.invalid")!, in: host.window,
                                                placement: .newTab, parent: .tabs(spaceID: spaceID)))
        try #require(host.tabs.session(for: music)).report(PageMedia(hasMedia: true, isAudible: true, isPlaying: true))
        for _ in 0..<100 where host.window.miniPlayer.itemID != music { await Task.yield() }

        #expect(host.tabs.isInMiniPlayer(music))
        #expect(!host.tabs.isInMiniPlayer(other))
    }

    /// Music holds the bar; another tab with a paused video plays a notification chime. WebKit
    /// hears that page, so its row shows the speaker, but its frames report no player playing,
    /// and the bar stays with the music.
    @Test func aChimeBesideAPausedVideoNeverTakesTheBar() async throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let tabs = try ["music", "video", "reading"].map { name in
            try #require(host.tabs.open(url: URL(string: "https://\(name).invalid")!, in: host.window,
                                        placement: .newTab, parent: .tabs(spaceID: spaceID)))
        }
        let music = try #require(host.tabs.session(for: tabs[0]))
        let video = try #require(host.tabs.session(for: tabs[1]))
        music.report(PageMedia(hasMedia: true, isAudible: true, isPlaying: true))
        video.report(PageMedia(hasMedia: true, hasVideo: true))
        for _ in 0..<100 where host.window.miniPlayer.itemID != music.itemID { await Task.yield() }
        #expect(host.window.miniPlayer.itemID == music.itemID)

        video.webKitAudible = true
        video.applyMediaFrames()
        host.tabs.trackMiniPlayer(of: host.window)
        for _ in 0..<100 { await Task.yield() }

        #expect(video.hasAudioContent, "the row's speaker")
        #expect(!video.media.isAudible && !video.media.isPlaying, "the bar's play state")
        #expect(host.window.miniPlayer.itemID == music.itemID)
    }
}

extension PageSession {
    /// Feeds a report the way the page's media script posts one.
    func report(_ media: PageMedia, frame: String = "main") {
        receiveMediaReport([
            "frame": frame, "hasMedia": media.hasMedia, "isAudible": media.isAudible, "isPlaying": media.isPlaying,
            "isMuted": media.isMuted, "hasVideo": media.hasVideo, "isPlayingVideo": media.isPlayingVideo,
            "previousTrack": media.handlesPreviousTrack, "nextTrack": media.handlesNextTrack,
        ], from: nil)
    }
}

/// Which pages a window's mini player looks at: the window's own tabs in every space, on any
/// site, never another window's, a private window's, the Agent space's or a Peek's.
@MainActor
struct MiniPlayerPagesTests {
    let playing = PageMedia(hasMedia: true, isAudible: true, isPlaying: true)

    private func openTab(_ address: String, in window: BrowserWindowState, space: UUID, _ host: Host) throws -> UUID {
        try #require(host.tabs.open(url: URL(string: address)!, in: window, placement: .newTab, parent: .tabs(spaceID: space)))
    }

    private func play(_ itemID: UUID, _ host: Host) throws {
        try #require(host.tabs.session(for: itemID)).report(playing)
    }

    private func ids(_ window: BrowserWindowState, _ host: Host) -> Set<UUID> {
        Set(host.tabs.miniPlayerPages(for: window).map(\.id))
    }

    @Test func listsThisWindowsTabsInEverySpaceOnAnySite() throws {
        let host = try Host()
        let first = try #require(host.window.spaceID)
        let second = try #require(host.tabs.createSpace(name: "Second", icon: "", accentHex: "#000000", after: first))
        let music = try openTab("https://music.invalid", in: host.window, space: first, host)
        let video = try openTab("https://video.invalid", in: host.window, space: second, host)
        try play(music, host)
        try play(video, host)

        let pages = host.tabs.miniPlayerPages(for: host.window)
        let musicPage = try #require(pages.first { $0.id == music })
        #expect(musicPage.hasMedia && musicPage.isAudible && !musicPage.isOnScreen)
        #expect(pages.contains { $0.id == video && $0.isOnScreen })
    }

    @Test func aTabMovesToTheWindowThatSelectsIt() throws {
        let host = try Host()
        let other = BrowserWindowState()
        host.registry.register(other)
        host.tabs.attach(window: other)
        let spaceID = try #require(host.window.spaceID)
        let tab = try openTab("https://music.invalid", in: host.window, space: spaceID, host)
        try play(tab, host)
        #expect(ids(host.window, host).contains(tab))
        #expect(!ids(other, host).contains(tab))

        host.tabs.select(tab, in: other)
        #expect(!ids(host.window, host).contains(tab))
        #expect(ids(other, host).contains(tab))
    }

    @Test func aPrivateWindowsPagesStayInIt() throws {
        let host = try Host()
        let privateWindow = BrowserWindowState()
        privateWindow.isIncognito = true
        privateWindow.ephemeralProfile = Profile.createEphemeral()
        host.registry.register(privateWindow)
        host.tabs.attach(window: privateWindow)
        let privateSpace = try #require(privateWindow.spaceID)
        let tab = try openTab("https://music.invalid", in: privateWindow, space: privateSpace, host)
        try play(tab, host)

        #expect(ids(privateWindow, host).contains(tab))
        #expect(!ids(host.window, host).contains(tab))
    }

    @Test func leavesOutTheAgentSpaceAndPeek() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let agent = try #require(host.tabs.ensureAgentSpace(loginsFrom: host.window))
        host.tabs.setSpace(agent, in: host.window)
        let agentTab = try openTab("https://agent.invalid", in: host.window, space: agent, host)
        try play(agentTab, host)
        let profile = try #require(host.tabs.profile(forSpace: spaceID))
        let peek = host.tabs.openDetached(url: URL(string: "https://peek.invalid")!, profile: profile, in: host.window)
        peek.report(playing)

        let listed = ids(host.window, host)
        #expect(!listed.contains(agentTab))
        #expect(!listed.contains(peek.itemID))
    }

    @Test func marksEveryPaneOnScreen() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let left = try openTab("https://left.invalid", in: host.window, space: spaceID, host)
        let right = try openTab("https://right.invalid", in: host.window, space: spaceID, host)
        let hidden = try openTab("https://hidden.invalid", in: host.window, space: spaceID, host)
        for tab in [left, right, hidden] { try play(tab, host) }
        host.tabs.select(left, in: host.window)
        host.window.split = SplitRecord([left, right])

        let onScreen = Set(host.tabs.miniPlayerPages(for: host.window).filter(\.isOnScreen).map(\.id))
        #expect(onScreen == [left, right])
    }

    /// A split shows only while one of its panes is selected; selecting another tab hides it.
    @Test func aHiddenSplitsPanesAreOffScreen() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let left = try openTab("https://left.invalid", in: host.window, space: spaceID, host)
        let right = try openTab("https://right.invalid", in: host.window, space: spaceID, host)
        let other = try openTab("https://other.invalid", in: host.window, space: spaceID, host)
        for tab in [left, right, other] { try play(tab, host) }
        host.window.split = SplitRecord([left, right])
        host.tabs.select(other, in: host.window)

        let onScreen = Set(host.tabs.miniPlayerPages(for: host.window).filter(\.isOnScreen).map(\.id))
        #expect(onScreen == [other])
    }

    /// A new document has no media until its own script says so; a PDF never does.
    @Test func navigatingToAnotherPageDropsTheOldPagesMedia() throws {
        let host = try Host()
        let tab = try openTab("https://video.invalid", in: host.window, space: try #require(host.window.spaceID), host)
        try play(tab, host)
        let page = try #require(host.tabs.session(for: tab))

        page.webView(page.activeWebView, didCommit: nil)
        #expect(!(host.tabs.miniPlayerPages(for: host.window).first { $0.id == tab }?.hasMedia ?? true))
    }

    @Test func aLinkOpenedInTheBackgroundBelongsToItsWindow() throws {
        let host = try Host()
        let opener = try #require(host.window.selectedItemID)
        let openerPage = try #require(host.tabs.ensureSession(for: opener))
        let before = Set(host.tabs.tree.items.keys)
        openerPage.openInNewTab(URL(string: "https://link.invalid/video")!)
        let child = try #require(Set(host.tabs.tree.items.keys).subtracting(before).first)
        try play(child, host)

        #expect(ids(host.window, host).contains(child))
    }
}
