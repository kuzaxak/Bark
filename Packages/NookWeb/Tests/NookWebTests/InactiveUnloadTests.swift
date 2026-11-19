// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookWeb

@MainActor
struct InactiveUnloadTests {
    @Test func bulkUnloadingKeepsHiddenNativePagesWithUnknownActivity() throws {
        let host = try Host(); defer { host.cleanup() }
        let page = try backgroundPage(host)

        #expect(!page.isUnloaded)
        #expect(host.tabs.inactiveUnloadProtectionReason(for: page) == .unknownNativeActivity)
        let result = host.tabs.unloadAllHidden()
        #expect(result.unloaded == 0 && result.kept == 2)
        #expect(result.retained == [.visible: 1, .unknownNativeActivity: 1])
        #expect(!page.isUnloaded && host.native.closes.isEmpty)
    }

    @Test func bulkUnloadingRetainsMiniPlayerAndPinnedResidency() throws {
        let host = try Host(); defer { host.cleanup() }
        let media = try backgroundPage(host)
        let pinned = try backgroundPage(host)
        let unknown = try backgroundPage(host)
        let space = try #require(host.window.spaceID)
        host.tabs.pin(pinned.itemID, to: .pinned(spaceID: space))
        host.window.miniPlayer.update([
            MiniPlayerPage(id: media.itemID, hasMedia: true, isAudible: true, isOnScreen: false)])
        host.window.miniPlayer.update([
            MiniPlayerPage(id: media.itemID, hasMedia: true, isAudible: false, isOnScreen: false)])
        #expect(host.tabs.isInMiniPlayer(media.itemID))
        let initial = host.tabs.unloadAllHidden()
        #expect(initial.unloaded == 0 && initial.kept == 4)
        #expect(initial.retained == [.visible: 1, .miniPlayer: 1, .pinned: 1, .unknownNativeActivity: 1])
        #expect(!media.isUnloaded)
        #expect(!pinned.isUnloaded)
        #expect(!unknown.isUnloaded)
        host.window.miniPlayer.dismiss()
        let afterDismissal = host.tabs.unloadAllHidden()
        #expect(afterDismissal.unloaded == 0 && afterDismissal.kept == 4)
        #expect(afterDismissal.retained == [.visible: 1, .pinned: 1, .unknownNativeActivity: 2])
        #expect(!media.isUnloaded && host.native.closes.isEmpty)
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
