// Licensed under GPL-3.0. See LICENSE.
import AppKit
import Foundation
import Testing
import WebKit
import NookTabsCore
@testable import NookWeb

/// The mini player through Nook's own path: `TabsController`, `PageSession`, the shared
/// `BrowserConfiguration`, its scripts and message handlers, in live web views. A tab plays a
/// local page, is left the way the compositor leaves it (its view taken out of the window), and
/// the bar and the tab row must follow what the page plays.
@MainActor
@Suite(.serialized)
struct MiniPlayerLiveTests {
    /// Swift must not depend on the page's reports arriving (`LivePage.rewrittenPlayer`).
    @Test func aPageWhoseReportsNeverArriveStillShowsInTheBar() async throws {
        let live = try LivePage()
        let tab = try live.open(script: LivePage.rewrittenPlayer)
        let page = try #require(live.host.tabs.session(for: tab))
        let webView = try #require(page.webView)
        try await live.until("the page playing") { live.playing(webView) == true }
        live.leave()

        try await live.until("the row's speaker and the bar") {
            page.hasAudioContent && page.media.hasMedia && page.media.isPlaying && live.host.window.miniPlayer.itemID == tab
        }
    }

    /// Each control answers with the frame's new state, so the bar follows within half a second
    /// even where nothing else would tell it: here a page that muted itself, which WebKit already
    /// counts as silent, on a page whose reports never arrive.
    @Test func theControlsShowTheirEffectAtOnce() async throws {
        let live = try LivePage()
        let tab = try live.open(script: LivePage.rewrittenPlayer)
        let page = try #require(live.host.tabs.session(for: tab))
        let webView = try #require(page.webView)
        try await live.until("playing") { page.media.isPlaying && page.hasAudioContent }
        live.leave()

        _ = try await webView.evaluateJavaScript("document.getElementById('player').muted = true; 1")
        try await live.until("muted by the page", within: .milliseconds(500)) { page.media.isMuted && page.media.isPlaying }
        page.togglePlayback()
        try await live.until("paused", within: .milliseconds(500)) { !page.media.isPlaying }
        page.togglePlayback()
        try await live.until("playing again", within: .milliseconds(500)) { page.media.isPlaying }
        page.toggleSound()
        try await live.until("unmuted", within: .milliseconds(500)) { !page.media.isMuted && page.hasAudioContent }
    }

    @Test func aPageThatMutedItselfShowsMutedAndUnmutes() async throws {
        let live = try LivePage()
        let tab = try live.open(script: "write(song); player.play();")
        let page = try #require(live.host.tabs.session(for: tab))
        let webView = try #require(page.webView)
        try await live.until("playing") { page.media.isPlaying && page.hasAudioContent }
        live.leave()

        _ = try await webView.evaluateJavaScript("document.getElementById('player').muted = true; 1")
        try await live.until("muted by the page", within: .milliseconds(500)) {
            page.media.isMuted && page.media.isPlaying && !page.isAudioMuted
        }
        page.toggleSound()
        try await live.until("unmuted", within: .milliseconds(500)) { !page.media.isMuted && page.hasAudioContent }
        let elementMuted = try await webView.evaluateJavaScript("document.getElementById('player').muted") as? Bool
        #expect(elementMuted == false, "the page's own element is unmuted, not Nook's tab mute")
        #expect(!page.isAudioMuted)
    }

    /// A short sound in the page, such as a mail or calendar notification, shows the row's speaker
    /// but never takes the bar.
    @Test func aNotificationChimeStaysOutOfTheBar() async throws {
        let live = try LivePage()
        let tab = try live.open(script: "write(chime); player.loop = true; player.play();")
        let page = try #require(live.host.tabs.session(for: tab))
        try await live.until("the row's speaker") { page.hasAudioContent }
        live.leave()

        try await Task.sleep(for: .milliseconds(500))
        #expect(live.host.window.miniPlayer.itemID != tab)
        #expect(!page.media.hasMedia)
    }
}

/// One window of live web views on a throwaway Nook state, and a local page per test.
@MainActor
final class LivePage {
    let host: Host
    private let webViews = LiveWebViews()
    private let window: NSWindow
    private let directory: URL

    init() throws {
        host = try Host()
        host.tabs.webViews = webViews
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniPlayerLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 800, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
    }

    /// Opens a selected tab on a page that runs `script` with `song` (60 s) and `chime` (2 s), both
    /// silent, and `write(source)`, which adds `#player` with that source to the document.
    func open(script: String) throws -> UUID {
        let file = directory.appendingPathComponent("\(UUID().uuidString).html")
        try """
            <!doctype html><html><body><script>
            const song = '\(Self.wav(seconds: 60))', chime = '\(Self.wav(seconds: 2))';
            let player;
            function write(source) {
                player = document.body.appendChild(document.createElement('audio'));
                player.id = 'player'; player.src = source;
            }
            \(script)
            </script></body></html>
            """.write(to: file, atomically: true, encoding: .utf8)
        let spaceID = try #require(host.window.spaceID)
        let tab = try #require(host.tabs.open(url: file, in: host.window, placement: .newTab, parent: .tabs(spaceID: spaceID)))
        window.contentView = try #require(host.tabs.session(for: tab)?.webView)
        return tab
    }

    /// Selects another tab and takes the page's view out of the window, as the compositor does.
    func leave() {
        guard let spaceID = host.window.spaceID else { return }
        window.contentView?.removeFromSuperview()
        _ = host.tabs.open(url: URL(string: "about:blank")!, in: host.window, placement: .newTab, parent: .tabs(spaceID: spaceID))
    }

    /// A page that writes itself again with `document.open()` once Nook's scripts are in, then
    /// plays `song`. The spec erases the document's and the window's listeners, so the page's
    /// reports never arrive while the page itself still knows what plays.
    static let rewrittenPlayer = """
        setTimeout(() => {
            document.open(); document.write('<audio id="player" loop></audio>'); document.close();
            const player = document.getElementById('player'); player.src = song; player.play();
        }, 300);
        """

    /// Whether `#player` plays, asked of the page itself; nil until the page answers.
    func playing(_ webView: WKWebView) -> Bool? {
        webView.evaluateJavaScript("(p => !!p && !p.paused && p.readyState >= 2)(document.getElementById('player'))") { [weak self] result, _ in
            self?.lastPlaying = result as? Bool
        }
        return lastPlaying
    }
    private var lastPlaying: Bool?

    /// Page loads and WebKit's first process launch can take a while next to the other suites.
    func until(_ what: String, within limit: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > limit {
                Issue.record("not \(what) within \(limit)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Silent 8-bit mono WAV: the scripts and WebKit go by the element's state, not by its sound.
    static func wav(seconds: Int) -> String {
        let rate = 8000, count = rate * seconds
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate)); append(UInt16(1)); append(UInt16(8))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count))
        data.append(Data(repeating: 128, count: count))
        return "data:audio/wav;base64," + data.base64EncodedString()
    }
}

@MainActor
final class LiveWebViews: WebViewProvider {
    func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        LiveWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }
    func webView(for itemID: UUID, in windowID: UUID) -> WKWebView? { nil }
    func allWebViews(for itemID: UUID) -> [WKWebView] { [] }
    func releaseWebViews(for session: PageSession) {}
    func removeFromContainers(_ webView: WKWebView) { webView.removeFromSuperview() }
}

final class LiveWebView: WKWebView, SessionWebView {
    weak var owningSession: PageSession?
    var contextMenuBridge: WebContextMenuBridge?
    func contextMenuPayloadDidUpdate(_ payload: WebContextMenuPayload?) {}
}
