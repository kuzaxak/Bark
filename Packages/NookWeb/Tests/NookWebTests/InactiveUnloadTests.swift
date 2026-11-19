// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import WebKit
@testable import NookWeb

@MainActor
struct InactiveUnloadTests {
    @Test func bulkUnloadingRetainsSilentCaptureIncludingCoordinatedViews() throws {
        let host = try Host()
        let views = CaptureViews()
        host.tabs.webViews = views
        let camera = try backgroundPage(host)
        let microphone = try backgroundPage(host)
        let safe = try backgroundPage(host)
        // Muted capture is still a live call, independent of audible media.
        (camera.webView as? CaptureView)?.cameraState = .muted
        let secondary = CaptureView(frame: .zero, configuration: WKWebViewConfiguration())
        secondary.microphoneState = .muted
        views.additional[microphone.itemID] = [secondary]

        #expect(host.tabs.inactiveUnloadProtectionReason(for: camera) == .camera)
        #expect(host.tabs.inactiveUnloadProtectionReason(for: microphone) == .microphone)
        host.tabs.unloadAllHidden()
        #expect(!camera.isUnloaded)
        #expect(!microphone.isUnloaded)
        #expect(safe.isUnloaded)

        (camera.webView as? CaptureView)?.cameraState = .none
        secondary.microphoneState = .none
        host.tabs.unloadAllHidden()
        #expect(camera.isUnloaded)
        #expect(microphone.isUnloaded)
    }

    @Test func bulkUnloadingRetainsMiniPlayerAndPinnedResidency() throws {
        let host = try Host()
        let media = try backgroundPage(host)
        let pinned = try backgroundPage(host)
        let safe = try backgroundPage(host)
        let space = try #require(host.window.spaceID)
        host.tabs.pin(pinned.itemID, to: .pinned(spaceID: space))
        host.window.miniPlayer.update([
            MiniPlayerPage(id: media.itemID, hasMedia: true, isAudible: true, isOnScreen: false)])
        host.window.miniPlayer.update([
            MiniPlayerPage(id: media.itemID, hasMedia: true, isAudible: false, isOnScreen: false)])
        #expect(host.tabs.isInMiniPlayer(media.itemID))
        host.tabs.unloadAllHidden()
        #expect(!media.isUnloaded)
        #expect(!pinned.isUnloaded)
        #expect(safe.isUnloaded)
        host.window.miniPlayer.dismiss()
        host.tabs.unloadAllHidden()
        #expect(media.isUnloaded)
        #expect(!pinned.isUnloaded)
    }

    private func backgroundPage(_ host: Host) throws -> PageSession {
        let space = try #require(host.window.spaceID)
        let id = try #require(host.tabs.open(url: URL(string: "about:blank")!, in: host.window,
                                           placement: .background, parent: .tabs(spaceID: space)))
        let page = try #require(host.tabs.ensureSession(for: id))
        page.loadWebViewIfNeeded()
        return page
    }
}

@MainActor
private final class CaptureViews: WebKitWebViewProvider {
    var additional: [UUID: [WKWebView]] = [:]
    func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        CaptureView(frame: .zero, configuration: configuration)
    }
    func webView(for itemID: UUID, in windowID: UUID) -> WKWebView? { nil }
    func allWebViews(for itemID: UUID) -> [WKWebView] { additional[itemID] ?? [] }
    func releaseWebViews(for session: PageSession) { additional[session.itemID] = nil }
    func removeFromContainers(_ webView: WKWebView) {}
}

private final class CaptureView: WKWebView {
    var cameraState: WKMediaCaptureState = .none
    var microphoneState: WKMediaCaptureState = .none
    override var cameraCaptureState: WKMediaCaptureState { cameraState }
    override var microphoneCaptureState: WKMediaCaptureState { microphoneState }
    override func load(_ request: URLRequest) -> WKNavigation? { nil }
}
