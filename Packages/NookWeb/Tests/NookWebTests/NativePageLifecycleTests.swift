// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Observation
import os
import Testing
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
import SwiftData
@testable import NookWeb

#if os(macOS)
import AppKit

private func cornerPNG(topRight: [UInt8], rest: [UInt8]) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32))
    let bytes = try #require(bitmap.bitmapData)
    for y in 0..<4 {
        for x in 0..<4 {
            let color = x == 3 && y == 0 ? topRight : rest
            for channel in 0..<3 { bytes[y * 16 + x * 4 + channel] = color[channel] }
            bytes[y * 16 + x * 4 + 3] = 255
        }
    }
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor
struct NativePageLifecycleTests {
    @Test func syncedDeletionWaitsForNativeOwnerAndThenPersists() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let item = try #require(f.window.selectedItemID)
        var inbound = SpaceSyncInbound()
        inbound.change.items[item] = .some(nil)

        #expect(!f.tabs.applyNativeSpaceSync(inbound))
        #expect(f.tabs.tree.item(item) != nil)
        #expect(f.tabs.session(for: item)?.navigation === native)
        #expect(f.host.closes.isEmpty)

        var retried: Bool?
        f.tabs.onNativeSyncAdmissionChanged = { retried = f.tabs.applyNativeSpaceSync(inbound) }
        native.onEvent?(.ownerEnded)
        for _ in 0..<50 where retried == nil { await Task.yield() }
        #expect(retried == true)
        #expect(f.tabs.tree.item(item) == nil)
        #expect(f.restored(at: f.tabs.directory).tree.item(item) == nil)
        f.tabs.onNativeSyncAdmissionChanged = nil
    }

    @Test func syncedFolderMovesAndDeletesUnloadedTabs() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let home = try #require(f.window.spaceID)
        let homeTab = try #require(f.window.selectedItemID)
        let work = try #require(f.tabs.createSpace(name: "Work", icon: "", accentHex: "#000000",
                                                 after: nil, profileName: "Work profile"))
        let folder = UUID()
        let tab = UUID()
        var projected = f.tabs.tree
        try projected.createFolder(id: folder, title: "Projects", in: .pinned(spaceID: home), after: nil)
        try projected.createTab(id: tab, url: URL(string: "https://example.invalid/project")!, title: "Project",
                                in: .folder(itemID: folder), after: nil)
        var added = SpaceSyncInbound()
        added.change.items[folder] = .some(projected.item(folder))
        added.change.items[tab] = .some(projected.item(tab))
        #expect(f.tabs.applyNativeSpaceSync(added))

        try projected.move(folder, to: .pinned(spaceID: work), after: nil)
        var moved = SpaceSyncInbound()
        moved.change.items[folder] = .some(projected.item(folder))
        #expect(f.tabs.applyNativeSpaceSync(moved))
        #expect(f.tabs.tree.spaceID(of: tab) == work)

        var removed = SpaceSyncInbound()
        removed.change.items[folder] = .some(nil)
        removed.change.items[tab] = .some(nil)
        #expect(f.tabs.applyNativeSpaceSync(removed))
        #expect(f.tabs.tree.item(folder) == nil)
        #expect(f.tabs.tree.item(tab) == nil)
        #expect(f.tabs.session(for: homeTab)?.navigation === native)
        #expect(f.host.closes.isEmpty)
    }

    @Test func syncedSpaceDeletionKeepsLocalProfileAndLastSpace() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let home = try #require(f.window.spaceID)
        let work = try #require(f.tabs.createSpace(name: "Work", icon: "", accentHex: "#000000",
                                                 after: nil, profileName: "Work profile"))
        let profile = try #require(f.tabs.tree.dataStoreID(for: work))
        var inbound = SpaceSyncInbound()
        inbound.deletedSpaces = [work, home]
        #expect(f.tabs.applyNativeSpaceSync(inbound))
        #expect(f.tabs.tree.space(work) == nil)
        #expect(f.tabs.tree.space(home) != nil)
        #expect(f.tabs.device.keptProfiles?.contains { $0.id == profile } == true)
    }

    @Test func nativeTopBarColorSamplesThePageOncePerDomain() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        native.allowsThumbnails = true
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        func navigate(_ address: String, finish: Bool = true) {
            let url = URL(string: address)!
            native.onEvent?(.started(url))
            native.onEvent?(.committed(url, sameDocument: false))
            if finish { native.onEvent?(.finished(url, title: "Fixture", isReload: false)) }
        }
        func nextCapture(_ count: Int) async -> Bool {
            for _ in 0..<200 where native.thumbnailCompletions.count < count { try? await Task.sleep(for: .milliseconds(10)) }
            return native.thumbnailCompletions.count == count
        }
        func red(_ color: NSColor?) -> Bool { (color?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.9 }
        func blue(_ color: NSColor?) -> Bool { (color?.usingColorSpace(.deviceRGB)?.blueComponent ?? 0) > 0.9 }
        let redCorner = try cornerPNG(topRight: [255, 0, 0], rest: [0, 255, 0])
        let blueCorner = try cornerPNG(topRight: [0, 0, 255], rest: [0, 255, 0])
        let before = native.thumbnailCompletions.count

        navigate("https://first.test/a")
        #expect(await nextCapture(before + 1))
        native.thumbnailCompletions[before](redCorner)
        #expect(red(page.topBarBackgroundColor), "the top right corner colours the bar")

        navigate("https://first.test/b")
        try await Task.sleep(for: .milliseconds(450))
        #expect(native.thumbnailCompletions.count == before + 1, "one sample per domain")

        navigate("https://second.test/a")
        #expect(await nextCapture(before + 2))
        navigate("https://third.test/a", finish: false)
        native.thumbnailCompletions[before + 1](blueCorner)
        #expect(red(page.topBarBackgroundColor), "a reply from a page already left is dropped")

        native.onEvent?(.finished(URL(string: "https://third.test/a")!, title: "Fixture", isReload: false))
        #expect(await nextCapture(before + 3))
        native.thumbnailCompletions[before + 2](nil)
        #expect(red(page.topBarBackgroundColor), "no frame yet keeps the colour")
        page.sampleNativeTopBarColor()
        #expect(await nextCapture(before + 4), "selecting the page asks again")
        native.thumbnailCompletions[before + 3](blueCorner)
        #expect(blue(page.topBarBackgroundColor))
        page.sampleNativeTopBarColor()
        try await Task.sleep(for: .milliseconds(450))
        #expect(native.thumbnailCompletions.count == before + 4, "a sampled domain is not asked again")
        page.resetNativeTopBarSample()
        page.sampleNativeTopBarColor()
        #expect(await nextCapture(before + 5), "an appearance change samples again")
    }

    @Test func nativeBlockNoticeRequiresProvenanceAndContinuePublishesBeforeLoad() async throws {
        let f = try NativeModelFixture(nativeBlocking: true); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        let target = URL(string: "https://blocked.invalid/path")!
        native.onEvent?(.started(target))
        native.onEvent?(.failed(NSError(domain: "Barc.Chromium.Navigation", code: -20), provisional: true))
        #expect(page.blockedURL == nil)
        native.onEvent?(.nativeBlocked(target))
        #expect(page.blockedURL == target)
        let count = native.loaded.count
        native.onEvent?(.continueNativeBlock(target))
        #expect(native.loaded.count == count)
        await agentCallbacks()
        #expect(native.loaded.count == count + 1 && native.loaded.last == target)
        #expect(native.blockingPolicies.last?.continuedHost == "blocked.invalid")
        #expect(page.blockedURL == nil && page.primaryWebView == nil)
    }

    @Test(arguments: ["navigation", "owner", "adapter", "profile"])
    func nativeBlockContinueRejectsStaleIntent(change: String) async throws {
        let f = try NativeModelFixture(nativeBlocking: true); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        let profileID = try #require(page.profile?.id)
        let target = URL(string: "https://blocked.invalid/path")!
        native.onEvent?(.started(target)); native.onEvent?(.nativeBlocked(target))
        let loads = native.loaded.count, policies = native.blockingPolicies.count
        native.onEvent?(.continueNativeBlock(target))
        switch change {
        case "navigation": native.onEvent?(.started(URL(string: "https://replacement.invalid/")))
        case "owner": page.nativeOwnerEnded()
        case "adapter": page.navigation = NativeTestPage(profileID: profileID)
        case "profile": page.detachedProfile = Profile.createEphemeral(id: UUID(), engine: .chromium)
        default: break
        }
        await agentCallbacks()
        #expect(native.loaded.count == loads && native.blockingPolicies.count == policies)
        #expect(f.tabs.blocker.networkPolicy(for: page).continuedHost == nil)
    }

    @Test func nativeBlockingExceptionsUpdateBoundPageBeforeRetry() throws {
        let f = try NativeModelFixture(nativeBlocking: true); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        page.isOAuthFlow = true
        #expect(native.blockingPolicies.last?.isOAuthFlow == true)
        f.tabs.blocker.disableTemporarily(for: page, duration: 60)
        #expect(native.blockerReloads == 1 && native.blockingPolicies.last?.disabledUntil != nil)
        let target = URL(string: "https://blocked.invalid/path")!
        page.blockedURL = target
        page.continueToBlockedPage()
        #expect(native.blockingPolicies.last?.continuedHost == "blocked.invalid")
        #expect(native.loaded.last == target && page.blockedURL == nil)
        let next = URL(string: "https://other.invalid/")!
        native.state.url = next; native.onStateChanged?(native.state)
        native.onEvent?(.started(next))
        #expect(native.blockingPolicies.last?.continuedHost == nil)
        native.acceptsBlockingPolicy = false
        let loads = native.loaded.count
        page.blockedURL = target
        page.continueToBlockedPage()
        #expect(page.blockedURL == target && native.loaded.count == loads)
        page.nativeOwnerEnded()
        let calls = native.blockingPolicies.count
        page.isOAuthFlow = false
        #expect(native.blockingPolicies.count == calls && page.primaryWebView == nil)
    }

    @Test func nativeHistoryTextUsesExistingOptInAndCoalescesSamePath() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        let container = try ModelContainer(for: HistoryEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let history = HistoryManager(context: container.mainContext,
            pageTextURL: f.directory.appendingPathComponent("HistoryText.sqlite"))
        f.tabs.history = history
        let url = URL(string: "https://fixture.invalid/article")!
        native.state = PageNavigationState(url: url, title: "Article", canGoBack: false, canGoForward: false)
        native.onStateChanged?(native.state)
        f.tabs.settings.searchPageTextInHistory = false
        native.onEvent?(.started(url)); native.onEvent?(.committed(url))
        native.onEvent?(.finished(url, title: "Article", isReload: false))
        #expect(page.nativePageTextTask == nil && native.pageTextCaptures == 0)

        f.tabs.settings.searchPageTextInHistory = true
        native.onEvent?(.started(url)); native.onEvent?(.committed(url))
        native.onEvent?(.finished(url, title: "Article", isReload: false))
        let capture = try #require(page.nativePageTextTask)
        await capture.value
        _ = await history.getHistory()
        let found = await history.searchPageText(query: "chromiummarker", limit: 10)
        #expect(found.map(\.url) == [url] && native.pageTextCaptures == 1)
        #expect(page.primaryWebView == nil && f.host.creates.count == 1)

        let fragment = URL(string: "https://fixture.invalid/article#section")!
        native.state.url = fragment; native.onStateChanged?(native.state)
        native.onEvent?(.committed(fragment, sameDocument: true))
        await page.nativePageTextTask?.value
        #expect(native.pageTextCaptures == 1)
        let next = URL(string: "https://fixture.invalid/next")!
        native.state.url = next; native.onStateChanged?(native.state)
        native.onEvent?(.committed(next, sameDocument: true))
        await page.nativePageTextTask?.value
        #expect(native.pageTextCaptures == 2 && page.primaryWebView == nil)
        _ = await history.getHistory()
    }

    @Test func nativeHistoryTextExcludesPrivateAndAgentPages() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        f.tabs.settings.searchPageTextInHistory = true
        _ = try agentItem(f)
        let preparing = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }
        await agentCallbacks()
        let agentNative = f.host.finishCreate(1)
        let agent = try #require(await preparing.value)
        let url = URL(string: "https://fixture.invalid/excluded")!
        agentNative.state = PageNavigationState(url: url, canGoBack: false, canGoForward: false)
        agentNative.onStateChanged?(agentNative.state)
        agentNative.onEvent?(.started(url)); agentNative.onEvent?(.committed(url))
        agentNative.onEvent?(.finished(url, title: "Agent", isReload: false))
        #expect(agent.isAgentPage && agent.nativePageTextTask == nil && agentNative.pageTextCaptures == 0)

        let privateWindow = f.privateWindow()
        let id = try #require(f.tabs.open(url: url, in: privateWindow, placement: .newTab))
        let privateNative = f.host.finishCreate(f.host.creates.count - 1)
        let privatePage = try #require(privateWindow.privateSessions[id])
        privateNative.state = PageNavigationState(url: url, canGoBack: false, canGoForward: false)
        privateNative.onStateChanged?(privateNative.state)
        privateNative.onEvent?(.started(url)); privateNative.onEvent?(.committed(url))
        privateNative.onEvent?(.finished(url, title: "Private", isReload: false))
        #expect(privatePage.isPrivate && privatePage.profile?.isEphemeral == true)
        #expect(privatePage.nativePageTextTask == nil && privateNative.pageTextCaptures == 0)
        #expect(agent.primaryWebView == nil && privatePage.primaryWebView == nil)
    }

    @Test(arguments: ["setting", "navigation", "ephemeral", "owner", "controller", "cancel", "closing"])
    func nativeHistoryTextRejectsLateResults(change: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        let container = try ModelContainer(for: HistoryEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let history = HistoryManager(context: container.mainContext,
            pageTextURL: f.directory.appendingPathComponent("HistoryText.sqlite"))
        f.tabs.history = history; f.tabs.settings.searchPageTextInHistory = true
        let url = URL(string: "https://fixture.invalid/late")!
        native.state = PageNavigationState(url: url, title: "Late", canGoBack: false, canGoForward: false)
        native.onStateChanged?(native.state); native.holdPageText = true
        await withCheckedContinuation { started in
            native.onPageTextCapture = { started.resume() }
            native.onEvent?(.started(url)); native.onEvent?(.committed(url))
            native.onEvent?(.finished(url, title: "Late", isReload: false))
        }
        let capture = try #require(page.nativePageTextTask)
        switch change {
        case "setting": f.tabs.settings.searchPageTextInHistory = false
        case "navigation": native.onEvent?(.started(URL(string: "https://replacement.invalid/")!))
        case "ephemeral": page.profile?.isEphemeral = true
        case "owner": page.nativeOwnerEnded()
        case "controller": page.controller = nil
        case "cancel": page.cancelNativePageTextCapture()
        default: f.tabs.close(id)
        }
        native.completePageText()
        await capture.value
        _ = await history.getHistory()
        #expect(await history.searchPageText(query: "chromiummarker", limit: 10).isEmpty)
        #expect(page.primaryWebView == nil && native.pageTextCaptures == 1)
    }

    private func agentCallbacks() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test func paletteSearchBackgroundSurvivesRestoreColdThenUsesExactProfile() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let first = try #require(f.window.selectedItemID)
        f.host.finishCreate(0)
        let count = f.host.creates.count
        let id = try #require(f.tabs.openSearch("cold POST query", in: f.window, placement: .background))
        #expect(f.window.selectedItemID == first && f.host.creates.count == count)
        #expect(f.tabs.device.openPages[id]?.pendingSearch == "cold POST query")
        f.tabs.saveNow()
        let restored = f.restored(at: f.directory.appendingPathComponent("Tabs"))
        let page = try #require(restored.ensureSession(for: id))
        #expect(page.nativeSearchIntent?.query == "cold POST query" && page.navigation == nil)
        let host = ControlledNativeHost(); restored.nativePageHost = host
        let window = BrowserWindowState(); window.spaceID = f.window.spaceID
        restored.windowRegistry.register(window); restored.windowRegistry.setActive(window)
        restored.attach(window: window, restoringSavedState: false)
        let expectedProfile = try #require(restored.profile(for: page)?.id)
        restored.onProfileSearch = { profile, candidate, _, _, _, done in
            #expect(profile == expectedProfile && candidate === page)
            done(.success(ProfileSearchState(version: "native", selected: "post", name: "POST", controlled: false,
                managed: false, providers: [], suggestions: "")))
        }
        restored.select(id, in: window)
        #expect(host.creates.count == 1)
        let native = host.finishCreate(0)
        #expect(native.loaded.isEmpty && native.searched == ["cold POST query"])
        #expect(restored.device.openPages[id]?.pendingSearch == "cold POST query")
        native.onEvent?(.committed(URL(string: "https://post.invalid/results")!))
        #expect(restored.device.openPages[id]?.pendingSearch == nil)
        restored.saveNow()
        #expect(f.restored(at: f.directory.appendingPathComponent("Tabs")).device.openPages[id]?.pendingSearch == nil)
    }

    @Test func paletteSearchForegroundAndSplitStageBeforeFactoryAndDoNotGET() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let first = try #require(f.window.selectedItemID); f.host.finishCreate(0)
        f.tabs.onProfileSearch = { _, _, _, _, _, done in done(.success(ProfileSearchState(
            version: "native", selected: "post", name: "POST", controlled: false, managed: false, providers: [], suggestions: ""))) }
        let foreground = try #require(f.tabs.openSearch("foreground query", in: f.window, placement: .newTab))
        #expect(f.window.selectedItemID == first)
        let native = f.host.finishCreate(1)
        #expect(f.window.selectedItemID == foreground)
        #expect(native.searched == ["foreground query"] && native.loaded.isEmpty)
        let pane = try #require(f.tabs.openSearch("split query", in: f.window, placement: .background))
        #expect(f.host.creates.count == 2 && f.window.selectedItemID == foreground)
        let split = try #require(SplitRecord([first, pane]))
        #expect(f.tabs.presentNativeSplit(split, activeItemID: pane, in: f.window) { _ in })
        let paneNative = f.host.finishCreate(2)
        #expect(paneNative.searched == ["split query"] && paneNative.loaded.isEmpty)
        #expect(f.tabs.openSearch("https://explicit.invalid", in: f.window, placement: .background) == nil)
    }

    @Test func paletteSearchPendingSurvivesPinMoveFolderCloseAndReopen() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }; f.host.finishCreate(0)
        let space = try #require(f.window.spaceID)
        let id = try #require(f.tabs.openSearch("kept query", in: f.window, placement: .background))
        f.tabs.pin(id, to: .pinned(spaceID: space))
        #expect(f.tabs.device.openPages[id]?.pendingSearch == "kept query")
        f.tabs.unpin(id, in: f.window)
        #expect(f.tabs.device.openPages[id]?.pendingSearch == "kept query")
        let folder = try #require(f.tabs.createFolder(title: "Queries", in: .tabs(spaceID: space), after: nil))
        f.tabs.move(id, to: .folder(itemID: folder), after: nil)
        let second = try #require(f.tabs.openSearch("second query", in: f.window, placement: .background))
        f.tabs.move(second, to: .folder(itemID: folder), after: id)
        let count = f.host.creates.count
        f.tabs.close(folder)
        #expect(f.tabs.device.newestClosed?.pendingPages?.count == 2)
        #expect(f.tabs.device.openPages[id] == nil && f.host.creates.count == count)
        f.tabs.reopenLastClosed(in: f.window)
        #expect(f.tabs.device.openPages[id]?.pendingSearch == "kept query")
        #expect(f.tabs.device.openPages[second]?.pendingSearch == "second query")
        #expect(f.tabs.session(for: id)?.nativeSearchIntent?.query == "kept query")
    }

    @Test func paletteSearchPinnedPlaceholderResolvesHomeOnlyAtRealCommit() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }; f.host.finishCreate(0)
        let space = try #require(f.window.spaceID)
        let id = try #require(f.tabs.openSearch("pin first", in: f.window, placement: .background))
        f.tabs.pin(id, to: .pinned(spaceID: space))
        var reply: ((Result<ProfileSearchState, Error>) -> Void)?
        f.tabs.onProfileSearch = { _, _, _, _, _, done in reply = done }
        f.tabs.select(id, in: f.window)
        let native = f.host.finishCreate(1)
        native.onEvent?(.committed(URL(string: "about:blank")!))
        #expect(f.tabs.device.openPages[id]?.pendingSearch == "pin first")
        #expect(f.tabs.item(id)?.url?.absoluteString == "about:blank" && native.loaded.isEmpty)
        reply?(.success(ProfileSearchState(version: "native", selected: "post", name: "POST", controlled: false,
            managed: false, providers: [], suggestions: "")))
        #expect(native.searched == ["pin first"] && f.tabs.device.openPages[id]?.pendingSearch == "pin first")
        let result = URL(string: "https://post.invalid/pinned-result")!
        native.onEvent?(.committed(result))
        #expect(f.tabs.item(id)?.url == result && f.tabs.device.openPages[id]?.pendingSearch == nil)
        f.tabs.resetToHome(id)
        #expect(native.loaded.last == result)
        f.tabs.saveNow()
        let restored = f.restored(at: f.directory.appendingPathComponent("Tabs"))
        #expect(restored.item(id)?.url == result && restored.ensureSession(for: id)?.nativeSearchIntent == nil)
    }

    @Test func paletteSearchReopenConsumesPendingOnAlreadyBoundPinnedPage() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }; f.host.finishCreate(0)
        let id = try #require(f.tabs.openSearch("reopen query", in: f.window, placement: .background))
        f.tabs.pin(id, to: .pinned(spaceID: try #require(f.window.spaceID)))
        f.tabs.close(id)
        #expect(f.tabs.device.newestClosed?.endedPage?.pendingSearch == "reopen query")
        f.tabs.select(id, in: f.window)
        let existing = f.host.finishCreate(1)
        f.tabs.onProfileSearch = { _, _, _, _, _, done in done(.success(ProfileSearchState(
            version: "native", selected: "post", name: "POST", controlled: false, managed: false, providers: [], suggestions: ""))) }
        f.host.nativeSelectedPage = existing; f.host.nativeSelectedWindow = f.window.id
        #expect(f.host.acceptNativeSelection(existing, in: f.window))
        f.tabs.reopenLastClosed(in: f.window)
        #expect(f.host.creates.count == 2 && existing.searched == ["reopen query"])
        #expect(f.tabs.session(for: id)?.navigation === existing)
    }

    @Test func paletteSearchSupersessionStopAndPrivateCloseStayOwned() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }; f.host.finishCreate(0)
        let id = try #require(f.tabs.openSearch("first query", in: f.window, placement: .background))
        let page = try #require(f.tabs.session(for: id))
        page.stageNativeSearch("new query")
        #expect(f.tabs.device.openPages[id]?.pendingSearch == "new query")
        page.stop()
        #expect(f.tabs.device.openPages[id] == nil && page.nativeSearchIntent == nil)
        page.stageNativeSearch("explicit replacement")
        page.load(URL(string: "https://explicit.invalid/")!)
        #expect(f.tabs.device.openPages[id] == nil && page.nativeSearchIntent == nil)
        let privateWindow = f.privateWindow()
        let before = f.tabs.device
        let privateID = try #require(f.tabs.openSearch("private query", in: privateWindow, placement: .background))
        #expect(f.tabs.device == before && f.tabs.session(for: privateID)?.navigation == nil)
        f.tabs.close(privateID)
        #expect(privateWindow.privateClosed.last?.pendingPages?[privateID]?.pendingSearch == "private query")
        #expect(f.tabs.device == before)
        f.tabs.reopenLastClosed(in: privateWindow)
        #expect(f.tabs.session(for: privateID)?.nativeSearchIntent?.query == "private query")
        #expect(f.tabs.device == before)
        let profile = try #require(privateWindow.ephemeralProfile)
        let detachedNative = NativeTestPage(profileID: profile.id)
        let detached = try #require(f.tabs.bindDetachedNativePage(detachedNative, profile: profile,
            owner: DetachedNativeOwner(), in: privateWindow))
        detached.stageNativeSearch("detached pending")
        detached.load(URL(string: "https://explicit.invalid/private")!)
        #expect(detached.nativePrivatePendingSearch == nil && detached.nativeSearchIntent == nil)
        detached.stageNativeSearch("detached stop")
        detached.stop()
        #expect(detached.nativePrivatePendingSearch == nil && detached.nativeSearchIntent == nil)
        f.tabs.onProfileSearch = { _, _, _, _, _, done in done(.success(ProfileSearchState(
            version: "native", selected: "post", name: "POST", controlled: false, managed: false, providers: [], suggestions: ""))) }
        detached.navigate(to: "detached completed query")
        #expect(detachedNative.searched == ["detached completed query"])
        #expect(detached.nativePrivatePendingSearch == "detached completed query")
        detachedNative.onEvent?(.committed(URL(string: "https://post.invalid/private-result")!))
        #expect(detached.nativePrivatePendingSearch == nil && detached.nativeSearchIntent == nil)
        #expect(f.tabs.device == before)
    }

    @Test func nativeSearchUsesAdmittedBlankAndLatestIntentWithoutPreliminaryGET() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        var replies: [(Result<ProfileSearchState, Error>) -> Void] = []
        f.tabs.onProfileSearch = { _, candidate, _, _, choices, done in
            #expect(candidate === page && !choices); replies.append(done)
        }
        page.navigate(to: "first search")
        let native = f.host.finishCreate(0)
        #expect(native.loaded.isEmpty && native.searched.isEmpty && replies.count == 1)
        page.navigate(to: "second search")
        #expect(replies.count == 2)
        let state = ProfileSearchState(version: "v", selected: "native", name: "Native", controlled: false,
                                      managed: false, providers: [], suggestions: "")
        replies[0](.success(state))
        #expect(native.searched.isEmpty)
        replies[1](.success(state))
        #expect(native.searched == ["second search"] && native.loaded.isEmpty)
        page.navigate(to: "old search")
        page.load(URL(string: "https://newer.invalid/")!)
        replies[2](.success(state))
        #expect(native.searched == ["second search"] && native.loaded.last?.host == "newer.invalid")
    }

    @Test func nativeSearchColdBlankWaitsForExactSettlementAndStopCancelsMetadata() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        var replies: [(Result<ProfileSearchState, Error>) -> Void] = []
        f.tabs.onProfileSearch = { _, _, _, _, _, done in replies.append(done) }
        page.navigate(to: "first cold search")
        let native = f.host.finishCreate(0, loading: true)
        #expect(replies.isEmpty && native.searched.isEmpty && native.loaded.isEmpty)
        #expect(!page.nativeStartupNavigationHasSettled && page.isLoading)
        native.state = PageNavigationState(url: URL(string: "about:blank")!, canGoBack: false, canGoForward: false)
        native.onEvent?(.finished(URL(string: "about:blank"), title: "", isReload: false))
        await agentCallbacks()
        #expect(replies.count == 1 && !page.nativeStartupNavigationHasSettled && page.isLoading)
        let state = ProfileSearchState(version: "v", selected: "native", name: "Native", controlled: false,
                                      managed: false, providers: [], suggestions: "")
        page.stop()
        #expect(page.nativeStartupNavigationHasSettled && !page.isLoading)
        replies[0](.success(state))
        #expect(native.searched.isEmpty)
        page.navigate(to: "same URL superseded")
        native.onEvent?(.started(URL(string: "about:blank")))
        replies[1](.success(state))
        #expect(native.searched.isEmpty)
    }

    // Chromium reports a factory blank's load stop as a state change alone when it observed no commit.
    @Test func nativeSearchColdBlankDispatchesWhenLoadingEndsWithoutNavigationEvent() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.host.finishCreate(0)
        f.tabs.onProfileSearch = { _, _, _, _, _, done in done(.success(ProfileSearchState(
            version: "native", selected: "native", name: "Native", controlled: false, managed: false, providers: [], suggestions: ""))) }
        let id = try #require(f.tabs.openSearch("state only settlement", in: f.window, placement: .newTab))
        let native = f.host.finishCreate(1, loading: true)
        let page = try #require(f.tabs.session(for: id))
        let loading = PageNavigationState(url: URL(string: "about:blank")!, isLoading: true, canGoBack: false, canGoForward: false)
        native.state = loading
        native.onStateChanged?(loading)
        await agentCallbacks()
        #expect(native.searched.isEmpty && page.isLoading)
        let settled = PageNavigationState(url: URL(string: "about:blank")!, canGoBack: false, canGoForward: false)
        native.state = settled
        native.onStateChanged?(settled)
        #expect(page.isLoading)
        await agentCallbacks()
        #expect(native.searched == ["state only settlement"] && native.loaded.isEmpty && page.isLoading)
    }

    @Test func nativeSearchStoppedBeforeLoadingEndsDoesNotDispatch() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.host.finishCreate(0)
        var replies = 0
        f.tabs.onProfileSearch = { _, _, _, _, _, _ in replies += 1 }
        let id = try #require(f.tabs.openSearch("stopped search", in: f.window, placement: .newTab))
        let native = f.host.finishCreate(1, loading: true)
        let page = try #require(f.tabs.session(for: id))
        page.stop()
        let settled = PageNavigationState(url: URL(string: "about:blank")!, canGoBack: false, canGoForward: false)
        native.state = settled
        native.onStateChanged?(settled)
        await agentCallbacks()
        #expect(replies == 0 && native.searched.isEmpty && !page.isLoading)
    }

    @Test func typedInternalAddressesNavigateInsteadOfSearching() throws {
        #expect(isSearchInput("chrome"))
        #expect(isSearchInput("about: the movie"))
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let id = try #require(f.window.selectedItemID)
        let native = f.host.finishCreate(0)
        let page = try #require(f.tabs.session(for: id))
        for typed in ["chrome://version", "about:blank"] {
            #expect(!isSearchInput(typed))
            page.navigate(to: typed)
            #expect(native.searched.isEmpty && native.loaded.last == URL(string: typed))
        }
    }

    @Test func nativeSearchNewAndSplitTabsUseExistingOwnership() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let firstID = try #require(f.window.selectedItemID)
        let first = f.host.finishCreate(0)
        let state = ProfileSearchState(version: "v", selected: "native", name: "Native", controlled: false,
                                      managed: false, providers: [], suggestions: "")
        f.tabs.onProfileSearch = { _, _, _, _, _, done in done(.success(state)) }
        let secondID = try #require(f.tabs.open(url: URL(string: "about:blank")!, in: f.window, placement: .background))
        let split = try #require(SplitRecord([firstID, secondID]))
        #expect(f.tabs.presentNativeSplit(split, activeItemID: firstID, in: f.window) { _ in })
        let second = f.host.finishCreate(1)
        let oldLoads = second.loaded
        f.tabs.search("split query", in: f.window, splitItemID: secondID)
        #expect(second.searched == ["split query"] && second.loaded == oldLoads)
        #expect(first.searched.isEmpty && f.host.creates.count == 2)
        let page = try #require(f.tabs.session(for: secondID))
        #expect(page.navigation === second)
    }

    @Test func nativeSearchBorrowsKagiKeychainTokenOnlyForEffectiveKagi() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        f.tabs.settings.setKagiSession("https://kagi.com/search?token=synthetic-keychain-only")
        f.tabs.onProfileSearch = { _, _, _, _, _, done in
            done(.success(ProfileSearchState(version: "kagi", selected: "kagi", name: "Kagi", controlled: false,
                managed: false, providers: [], suggestions: "", kagiSession: true)))
        }
        page.navigate(to: "private search terms")
        #expect(native.searchTokens.count == 1 && native.searchTokens[0] == "synthetic-keychain-only")
        f.tabs.onProfileSearch = { _, _, _, _, _, done in
            done(.success(ProfileSearchState(version: "managed", selected: "managed", name: "Managed", controlled: true,
                managed: true, providers: [], suggestions: "")))
        }
        page.navigate(to: "another query")
        #expect(native.searchTokens.count == 2 && native.searchTokens[1] == nil)
        #expect(f.tabs.settings.customSearchEngines.isEmpty)
    }

    @Test func nativeSearchRefusalDoesNotFallbackToAppGoogleOrCreateAnotherPage() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        let loads = native.loaded
        f.tabs.onProfileSearch = { _, _, _, _, _, done in done(.failure(ProfileSearchError.refused)) }
        page.navigate(to: "managed disabled query")
        #expect(native.searched.isEmpty && native.loaded == loads && f.host.creates.count == 1)
    }

    private func agentItem(_ f: NativeModelFixture) throws -> UUID {
        let agent = try #require(f.tabs.ensureAgentSpace(loginsFrom: f.window))
        return try #require(f.tabs.open(url: URL(string: "https://agent.test/")!, in: f.window,
            placement: .background, parent: .tabs(spaceID: agent)))
    }

    @Test func nativeScriptApprovalRevisionFollowsExactAgentDocumentWithoutSelection() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        _ = try agentItem(f)
        let preparing = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }
        await agentCallbacks()
        let native = f.host.finishCreate(1)
        let page = try #require(await preparing.value)
        let selected = f.window.selectedItemID, space = f.window.spaceID
        let captured = page.nativeNavigationSerial
        native.onEvent?(.started(URL(string: "https://agent.test/new")))
        #expect(page.nativeNavigationSerial != captured)
        #expect(f.tabs.existingNativeAgentPage(in: f.window) === page)
        #expect(f.window.selectedItemID == selected && f.window.spaceID == space)
        let next = page.nativeNavigationSerial
        native.onEvent?(.committed(URL(string: "https://agent.test/new#fragment"), sameDocument: true))
        #expect(page.nativeNavigationSerial != next)
        #expect(page.primaryWebView == nil && f.host.creates.count == 2)
    }

    @Test func nativePageCacheFlushIsColdSafeAndHonoursCloseRefusal() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let id = try #require(f.window.selectedItemID)
        let page = try #require(f.tabs.session(for: id))
        #expect(!page.clearPageCache() && page.primaryWebView == nil)
        #expect(f.host.creates.count == 1)
        let native = f.host.finishCreate(0)
        native.acceptsCacheFlush = false
        #expect(!page.clearPageCache() && native.cacheFlushes == 1)
        native.acceptsCacheFlush = true
        let selected = f.window.selectedItemID, space = f.window.spaceID, url = page.url
        #expect(page.clearPageCache() && native.cacheFlushes == 2)
        #expect(f.host.creates.count == 1 && f.host.selectionCount == 1 && native.loaded.count == 1)
        #expect(f.window.selectedItemID == selected && f.window.spaceID == space && page.url == url && page.primaryWebView == nil)
        f.tabs.close(id)
        #expect(page.nativeIsEnding && !page.clearPageCache() && native.cacheFlushes == 2)
        f.host.finishClose(0, admitted: false)
        #expect(!page.nativeIsEnding && page.clearPageCache() && native.cacheFlushes == 3)
        #expect(page.navigation === native && page.url == url)
    }

    @Test func existingNativeAgentToolPageNeverCreatesAndRequiresExactOwner() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let selected = f.window.selectedItemID, space = f.window.spaceID
        #expect(f.tabs.existingNativeAgentPage(in: f.window) == nil)
        let id = try agentItem(f)
        #expect(f.tabs.existingNativeAgentPage(in: f.window) == nil)
        #expect(f.host.creates.count == 1)
        let prepare = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }
        await agentCallbacks()
        let native = f.host.finishCreate(1)
        let page = try #require(await prepare.value)
        #expect(f.tabs.existingNativeAgentPage(in: f.window) === page)
        #expect(f.tabs.agentItem == id && page.primaryWebView == nil)
        let other = BrowserWindowState()
        f.registry.register(other)
        #expect(f.tabs.existingNativeAgentPage(in: other) == nil)
        #expect(f.tabs.existingNativeAgentPage(in: f.privateWindow()) == nil)
        f.host.admitsAdoption = false
        #expect(f.tabs.existingNativeAgentPage(in: f.window) == nil)
        f.host.admitsAdoption = true
        #expect(native.profileID == page.profile?.id)
        let agent = try #require(f.tabs.agentSpaceID)
        let source = try #require(f.tabs.tree.space(agent)?.agentLoginSpaceID)
        _ = f.tabs.perform(.main, "missingToolProfile", undoable: false) {
            try $0.updateSpace(agent, icon: SpaceRecord.agentIcon(loginsFrom: UUID()))
        }
        #expect(f.tabs.existingNativeAgentPage(in: f.window) == nil)
        _ = f.tabs.perform(.main, "restoreToolProfile", undoable: false) {
            try $0.updateSpace(agent, icon: SpaceRecord.agentIcon(loginsFrom: source))
        }
        #expect(f.tabs.existingNativeAgentPage(in: f.window) === page)
        f.tabs.close(id)
        #expect(page.nativeIsEnding && f.host.canAdoptPage(native, in: f.window))
        #expect(f.tabs.existingNativeAgentPage(in: f.window) == nil)
        f.host.finishClose(0, admitted: false)
        #expect(!page.nativeIsEnding && page.navigation === native)
        #expect(f.tabs.existingNativeAgentPage(in: f.window) === page)
        f.tabs.recordPageOwner(id, in: other)
        #expect(f.tabs.existingNativeAgentPage(in: f.window) == nil)
        #expect(f.host.creates.count == 2 && f.window.selectedItemID == selected && f.window.spaceID == space)
    }

    @Test func nativeAgentPreparationIsBackgroundAndWaitsForActualNavigation() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let selected = f.window.selectedItemID, space = f.window.spaceID
        let id = try agentItem(f)
        let privateWindow = f.privateWindow()
        #expect(await f.tabs.prepareNativeAgentPage(in: privateWindow) == nil)
        #expect(f.host.creates.count == 1)
        let prepare = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }
        await agentCallbacks()
        #expect(f.host.creates.count == 2 && f.host.selectionCount == 1)
        let native = f.host.finishCreate(1)
        let page = try #require(await prepare.value)
        #expect(page.itemID == id && page.navigation === native && f.tabs.isNativePageOwner(page, in: f.window))
        #expect(native.profileID == f.host.creates[0].profileID)
        #expect(f.window.selectedItemID == selected && f.window.spaceID == space && page.primaryWebView == nil)
        let wait = Task { await page.waitForNativeAgentNavigation(in: f.window, reload: false, while: { true }) }
        await agentCallbacks()
        #expect(page.nativeAgentWaitID != nil)
        native.onStateChanged?(PageNavigationState(url: native.loaded.last, isLoading: false, canGoBack: false, canGoForward: false))
        await agentCallbacks()
        #expect(page.nativeAgentWaitID != nil) // Neither blank nor nonloading state is target completion.
        native.onEvent?(.started(native.loaded.last))
        native.onEvent?(.finished(native.loaded.last, title: "Agent", isReload: false))
        #expect(await wait.value)
        #expect(f.window.selectedItemID == selected && native.stops == 0)
    }

    @Test func nativeAgentPreparationNeverGuessesMissingBorrowedProfile() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0); let id = try agentItem(f)
        let agent = try #require(f.tabs.agentSpaceID)
        let missing = UUID()
        // Model a legacy/restored marker, not the UI's deliberately protected
        // Agent-space editor.
        _ = f.tabs.perform(.main, "restoredAgentMarker", undoable: false) {
            try $0.updateSpace(agent, icon: SpaceRecord.agentIcon(loginsFrom: missing))
        }
        try #require(f.tabs.tree.space(agent)?.agentLoginSpaceID == missing)
        #expect(await f.tabs.prepareNativeAgentPage(in: f.window) == nil)
        #expect(f.tabs.session(for: id) == nil && f.host.creates.count == 1)
    }

    @Test(arguments: ["cancel", "window", "replace", "newer", "agent"])
    func nativeAgentPreparationRejectsLateResultsWithoutRetargeting(change: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0); _ = try agentItem(f)
        let selected = f.window.selectedItemID
        let old = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }
        await agentCallbacks()
        let revision = f.registry.registrationRevision
        f.registry.register(f.window)
        #expect(f.registry.registrationRevision == revision)
        let unrelated = BrowserWindowState(); f.registry.register(unrelated); f.registry.unregister(unrelated.id)
        await agentCallbacks()
        #expect(!f.host.creates[1].cancelled)
        var newer: Task<PageSession?, Never>?
        if change == "cancel" {
            old.cancel()
            // Deliver before actor cleanup, not after awaiting cancellation.
            let late = f.host.finishCreate(1)
            #expect(late.loaded.isEmpty && f.host.closes.count == 1)
            #expect(await old.value == nil)
            return
        }
        else if change == "window" { f.registry.unregister(f.window.id) }
        else if change == "replace" { f.registry.windows[f.window.id] = BrowserWindowState(id: f.window.id) }
        else if change == "agent" {
            let next = try agentItem(f)
            f.tabs.select(next, in: f.window)
        } else { newer = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }; await agentCallbacks() }
        #expect(await old.value == nil)
        let late = f.host.finishCreate(1)
        if let newer {
            #expect(await newer.value != nil && late.loaded.count == 1 && f.host.closes.isEmpty)
        } else { #expect(late.loaded.isEmpty && f.host.closes.count == 1) }
        #expect(f.window.selectedItemID == selected)
    }

    @Test func nativeAgentCancellationPreservesActualForegroundTakeover() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0); let id = try agentItem(f)
        let preparation = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }
        await agentCallbacks()
        let agent = try #require(f.tabs.agentSpaceID)
        f.tabs.setSpace(agent, in: f.window)
        preparation.cancel()
        #expect(await preparation.value == nil)
        let native = f.host.finishCreate(1)
        #expect(f.window.spaceID == agent && f.window.selectedItemID == id)
        #expect(native.loaded.count == 1 && f.host.closes.isEmpty && !f.host.creates[1].cancelled)
    }

    @Test(arguments: ["cancel", "newer", "load", "close", "window", "cancelEvent", "transfer", "binding"])
    func nativeAgentReloadWaitOwnsItsStartAndNeverStopsNewerWork(change: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0); _ = try agentItem(f)
        let preparation = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }
        await agentCallbacks()
        let native = f.host.finishCreate(1), target = URL(string: "https://agent.test/")!
        let page = try #require(await preparation.value)
        native.onEvent?(.started(target)); native.onEvent?(.finished(target, title: nil, isReload: false))
        native.reloadResult = true
        let wait = Task { await page.waitForNativeAgentNavigation(in: f.window, reload: true, while: { true }) }
        await agentCallbacks()
        native.onEvent?(.finished(target, title: nil, isReload: false)) // Preceding finish cannot complete this reload.
        await agentCallbacks()
        #expect(page.nativeAgentWaitID != nil)
        if change == "cancel" { wait.cancel() }
        else if change == "newer" {
            let newer = Task { await page.waitForNativeAgentNavigation(in: f.window, reload: false, while: { true }) }
            await agentCallbacks()
            native.onEvent?(.started(target)); native.onEvent?(.finished(target, title: nil, isReload: true))
            #expect(await newer.value)
        } else if change == "load" { page.load(URL(string: "https://newer.test/")!) }
        else if change == "window" { f.registry.unregister(f.window.id) }
        else if change == "cancelEvent" { native.onEvent?(.cancelled(committedURL: target)) }
        else if change == "transfer" {
            f.host.nativeOwnerWindow = UUID()
            native.onStateChanged?(native.state)
        } else if change == "binding" {
            let replacement = NativeTestPage(profileID: native.profileID!)
            page.installNavigation(replacement)
            #expect(await wait.value == false && replacement.stops == 0)
            return
        } else { native.onEvent?(.ownerEnded) }
        #expect(await wait.value == false)
        #expect(native.stops == 0)
    }

    @Test func nativeAgentReloadHandlesSynchronousEventsFailureAndSameDocument() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0); _ = try agentItem(f)
        let preparation = Task { await f.tabs.prepareNativeAgentPage(in: f.window) }
        await agentCallbacks()
        let native = f.host.finishCreate(1), target = URL(string: "https://agent.test/")!
        let page = try #require(await preparation.value)
        native.onEvent?(.started(target)); native.onEvent?(.finished(target, title: nil, isReload: false))
        #expect(await page.waitForNativeAgentNavigation(in: f.window, reload: true, while: { true }) == false)
        native.reloadResult = true
        native.onReload = { [weak native] in native?.onEvent?(.started(target)); native?.onEvent?(.finished(target, title: nil, isReload: false)) }
        #expect(await page.waitForNativeAgentNavigation(in: f.window, reload: true, while: { true }) == false)
        native.onReload = { [weak native] in native?.onEvent?(.started(target)); native?.onEvent?(.finished(target, title: nil, isReload: true)) }
        #expect(await page.waitForNativeAgentNavigation(in: f.window, reload: true, while: { true }))
        native.onReload = { [weak native] in native?.onEvent?(.started(target)); native?.onEvent?(.failed(URLError(.cannotLoadFromNetwork), provisional: true)) }
        #expect(await page.waitForNativeAgentNavigation(in: f.window, reload: true, while: { true }) == false)
        let fragment = URL(string: "https://agent.test/#part")!
        page.load(fragment)
        let sameDocument = Task { await page.waitForNativeAgentNavigation(in: f.window, reload: false, while: { true }) }
        await agentCallbacks()
        native.onEvent?(.committed(fragment, sameDocument: true))
        #expect(await sameDocument.value)
    }

    @Test func nativeBlockingURLAndExplicitReloadNeverCreateWebKit() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let session = try #require(f.tabs.selectedSession(in: f.window))
        #expect(session.blockingURL == session.url)
        #expect(!session.reloadForBlocking() && session.primaryWebView == nil)
        let native = f.host.finishCreate(0)
        let current = URL(string: "https://actual-native.test/current")!
        native.state = PageNavigationState(url: current, canGoBack: false, canGoForward: false)
        #expect(session.blockingURL == current)
        #expect(!session.reloadForBlocking() && native.blockerReloads == 1)
        #expect(session.primaryWebView == nil && f.host.creates.count == 1)
    }

    private func settleWarmingCallbacks() async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test(arguments: [TabManagementMode.powerSaving, .standard, .performance])
    func nativeWarmingWaitsForRequestedNavigationAndHonorsAdmissionCeiling(mode: TabManagementMode) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.startupLoadMode = .favoritesAndSpace
        f.tabs.settings.tabManagementMode = mode
        let selected = try #require(f.tabs.selectedSession(in: f.window))
        let target = URL(string: "https://selected.test/")!
        selected.load(target)
        for index in 0..<40 {
            _ = f.tabs.open(url: URL(string: "https://warm.test/\(index)")!, in: f.window, placement: .background)
        }
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        defer { task.cancel() }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 1)
        let initial = f.host.finishCreate(0)
        await settleWarmingCallbacks()
        #expect(initial.loaded == [target])
        #expect(f.host.creates.count == 1) // Seeded blank is not requested-page completion.
        initial.onStateChanged?(PageNavigationState(url: target, isLoading: false, canGoBack: false, canGoForward: false))
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 1)
        initial.onEvent?(.finished(target, title: nil, isReload: false))
        for index in 1..<mode.startupWarmLimit {
            await settleWarmingCallbacks()
            #expect(f.host.creates.count == index + 1)
            guard f.host.creates.count > index else { return }
            let native = f.host.finishCreate(index)
            native.onEvent?(.finished(native.loaded.last, title: nil, isReload: false))
        }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == mode.startupWarmLimit)
        #expect(f.tabs.sessions.filter { $0.navigation != nil }.count == mode.startupWarmLimit)
        #expect(f.host.closes.isEmpty)
        await task.value
    }

    @Test func nativeWarmingNothingSettingDisablesAndSkipsSpecialURLs() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.startupLoadMode = .nothing
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.finished(initial.loaded.last, title: nil, isReload: false))
        for value in ["chrome://quit", "file:///tmp/test", "nook://action", "chrome-extension://id/page", "https://safe.test/"] {
            _ = f.tabs.open(url: URL(string: value)!, in: f.window, placement: .background)
        }
        await f.tabs.warmNativeStartupPages(in: f.window, while: { true })
        #expect(f.host.creates.count == 1)
        f.tabs.settings.startupLoadMode = .favoritesAndSpace
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        defer { task.cancel() }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 2)
        let native = f.host.finishCreate(1)
        #expect(native.loaded == [URL(string: "https://safe.test/")!])
        native.onEvent?(.finished(native.loaded.last, title: nil, isReload: false))
        await task.value
    }

    @Test(arguments: [false, true])
    func nativeWarmingCancellationPreservesForegroundTakeover(takeover: Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.startupLoadMode = .favoritesAndSpace
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.finished(initial.loaded.last, title: nil, isReload: false))
        let id = try #require(f.tabs.open(url: URL(string: "https://takeover.test/")!, in: f.window, placement: .background))
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 2)
        if takeover { f.tabs.select(id, in: f.window) }
        f.tabs.settings.startupLoadMode = .nothing
        await task.value
        let late = f.host.finishCreate(1)
        if takeover {
            #expect(late.loaded == [URL(string: "https://takeover.test/")!])
            #expect(f.window.selectedItemID == id && f.host.closes.isEmpty)
        } else {
            #expect(late.loaded.isEmpty && f.host.closes.count == 1)
        }
    }

    @Test(arguments: ["mode", "space", "profile", "window"])
    func nativeWarmingCancelsPendingOnOwnershipOrSettingsChange(change: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.startupLoadMode = .favoritesAndSpace
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.finished(initial.loaded.last, title: nil, isReload: false))
        _ = f.tabs.open(url: URL(string: "https://pending.test/")!, in: f.window, placement: .background)
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 2)
        if change == "mode" { f.tabs.settings.tabManagementMode = .performance }
        else if change == "window" {
            // WindowRegistry membership is intentionally not observable. The
            // native app's existing close callback explicitly cancels this task.
            f.registry.onWindowClose = { _ in task.cancel() }
            f.registry.unregister(f.window.id)
        }
        else {
            let space = try #require(f.window.spaceID)
            let next = try #require(f.tabs.createSpace(name: "Other", icon: "", accentHex: "#123456",
                after: space, sharingLoginsWith: change == "space" ? space : nil))
            f.window.spaceID = next
        }
        await task.value
        let late = f.host.finishCreate(1)
        #expect(late.loaded.isEmpty && f.host.closes.count == 1)
        #expect(f.host.creates.count == 2)
    }

    @Test func nativeWarmingSharesGlobalPendingReservationAndWakesAfterCancellation() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.finished(initial.loaded.last, title: nil, isReload: false))
        _ = f.tabs.open(url: URL(string: "https://one.test/")!, in: f.window, placement: .background)
        _ = f.tabs.open(url: URL(string: "https://two.test/")!, in: f.window, placement: .background)
        let other = BrowserWindowState(); other.spaceID = f.window.spaceID
        f.registry.register(other); f.tabs.attach(window: other, restoringSavedState: false)
        let first = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        await settleWarmingCallbacks()
        let second = Task { await f.tabs.warmNativeStartupPages(in: other, while: { true }) }
        defer { second.cancel() }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 2)
        first.cancel(); await first.value
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 3) // Ignored creation identity wakes via observed loading state.
        let late = f.host.finishCreate(1)
        #expect(late.loaded.isEmpty && f.host.closes.count == 1)
        let admitted = f.host.finishCreate(2)
        #expect(admitted.loaded.count == 1)
        second.cancel(); await second.value
        #expect(f.host.closes.count == 1) // An admitted background page is never evicted.
    }

    @Test func nativeWarmingSelectedFailureContinuesButLostOwnerStopsAndPrivateIsSkipped() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.failed(URLError(.cannotLoadFromNetwork), provisional: true))
        _ = f.tabs.open(url: URL(string: "https://safe.test/")!, in: f.window, placement: .background)
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 2)
        let warming = f.host.finishCreate(1)
        f.host.admitsAdoption = false
        warming.onStateChanged?(PageNavigationState(url: warming.loaded.last,
            isLoading: false, canGoBack: false, canGoForward: false))
        await task.value
        let privateWindow = f.privateWindow()
        let before = f.host.creates.count
        await f.tabs.warmNativeStartupPages(in: privateWindow, while: { true })
        #expect(f.host.creates.count == before && f.host.closes.isEmpty)
    }

    @Test func nativeWarmingCountsOtherWindowsButNeverBlocksForegroundAdmission() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        #expect(f.tabs.settings.startupLoadMode == .favoritesAndSpace)
        f.tabs.settings.tabManagementMode = .powerSaving
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.finished(initial.loaded.last, title: nil, isReload: false))
        let space = try #require(f.window.spaceID), profile = try #require(f.tabs.profile(forSpace: space))
        let other = BrowserWindowState(); other.spaceID = space
        f.registry.register(other); f.tabs.attach(window: other, restoringSavedState: false)
        for index in 0..<7 {
            let page = NativeTestPage(profileID: profile.id)
            page.state = PageNavigationState(url: URL(string: "https://existing.test/\(index)")!,
                canGoBack: false, canGoForward: false)
            #expect(f.tabs.adoptNativePage(page, through: f.host, in: other, spaceID: space, select: false) != nil)
        }
        let foreground = try #require(f.tabs.open(url: URL(string: "https://foreground.test/")!, in: f.window, placement: .background))
        await f.tabs.warmNativeStartupPages(in: f.window, while: { true })
        #expect(f.host.creates.count == 1 && f.tabs.sessions.filter { $0.navigation != nil }.count == 8)
        f.tabs.select(foreground, in: f.window)
        #expect(f.host.creates.count == 2) // Mandatory selection bypasses the speculation ceiling.
        _ = f.host.finishCreate(1)
        #expect(f.tabs.sessions.filter { $0.navigation != nil }.count == 9 && f.host.closes.isEmpty)
    }

    @Test func nativeWarmingCancellationWhileForegroundNeverFinishesDoesNotWaitForTimeout() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let initial = f.host.finishCreate(0)
        _ = f.tabs.open(url: URL(string: "https://cold.test/")!, in: f.window, placement: .background)
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 1)
        task.cancel(); await task.value
        #expect(initial.stops == 0 && f.host.closes.isEmpty)
    }

    @Test func nativeWarmingFavoritesRespectsCurrentProfileAndLeavesPrivateCold() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.startupLoadMode = .favorites
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.finished(initial.loaded.last, title: nil, isReload: false))
        let space = try #require(f.window.spaceID)
        let favorite = try #require(f.tabs.open(url: URL(string: "https://favorite.test/")!, in: f.window, placement: .background))
        f.tabs.pin(favorite, to: .favorites(spaceID: space))
        _ = f.tabs.open(url: URL(string: "https://ordinary.test/")!, in: f.window, placement: .background)
        let otherSpace = try #require(f.tabs.createSpace(name: "Other profile", icon: "", accentHex: "#123456", after: space))
        let other = BrowserWindowState(); other.spaceID = otherSpace
        f.registry.register(other); f.tabs.attach(window: other, restoringSavedState: false)
        let foreign = try #require(f.tabs.open(url: URL(string: "https://foreign.test/")!, in: other, placement: .background))
        f.tabs.pin(foreign, to: .favorites(spaceID: otherSpace))
        let privateWindow = f.privateWindow()
        _ = f.tabs.open(url: URL(string: "https://private.test/")!, in: privateWindow, placement: .background)
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 2)
        let page = f.host.finishCreate(1)
        #expect(page.profileID == initial.profileID && page.loaded == [URL(string: "https://favorite.test/")!])
        page.onEvent?(.finished(page.loaded.last, title: nil, isReload: false))
        await task.value
        #expect(f.host.creates.count == 2 && f.tabs.session(for: foreign)?.navigation == nil)
    }

    @Test(arguments: ["chrome://quit", "chrome://restart"])
    func nativeWarmingChecksRestoredCurrentURLWithoutMaterializingUnsafeFavorite(special: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.finished(initial.loaded.last, title: nil, isReload: false))
        let space = try #require(f.window.spaceID)
        let unsafe = try #require(f.tabs.open(url: URL(string: "https://favorite-home.test/")!, in: f.window, placement: .background))
        f.tabs.pin(unsafe, to: .favorites(spaceID: space))
        f.tabs.setOpenPage(unsafe, OpenPage(url: URL(string: special)!, title: "Current special page"))
        #expect(f.tabs.session(for: unsafe) == nil)
        _ = f.tabs.open(url: URL(string: "https://safe-later.test/")!, in: f.window, placement: .background)
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 2 && f.tabs.session(for: unsafe) == nil)
        let safe = f.host.finishCreate(1)
        #expect(safe.loaded == [URL(string: "https://safe-later.test/")!])
        safe.onEvent?(.finished(safe.loaded.last, title: nil, isReload: false))
        await task.value
        #expect(f.tabs.device.openPages[unsafe]?.url == URL(string: special))
    }

    @Test(arguments: [false, true])
    func nativeWarmingRechecksActualPendingTargetBeforeBinding(useRequestedURL: Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let initial = f.host.finishCreate(0)
        initial.onEvent?(.finished(initial.loaded.last, title: nil, isReload: false))
        let id = try #require(f.tabs.open(url: URL(string: "https://initial-safe.test/")!, in: f.window, placement: .background))
        let task = Task { await f.tabs.warmNativeStartupPages(in: f.window, while: { true }) }
        await settleWarmingCallbacks()
        #expect(f.host.creates.count == 2)
        let pending = try #require(f.tabs.session(for: id))
        // An explicitly selected foreground page retains its normal URL rules;
        // this remains an optional preparation throughout the target change.
        if useRequestedURL { pending.nativeRequestedURL = URL(string: "chrome://quit")! }
        else { pending.url = URL(string: "chrome://restart")! }
        let late = f.host.finishCreate(1)
        await task.value
        #expect(late.loaded.isEmpty && pending.navigation == nil && f.host.closes.count == 1)
    }

    @Test(arguments: [false, true])
    func nativeTranslationCancelledStartDeduplicatesReplayAndKeepsNewNodes(isPrivate: Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let window = isPrivate ? f.privateWindow() : f.window
        let profile = try #require(isPrivate ? window.ephemeralProfile :
            window.spaceID.flatMap { f.tabs.profile(forSpace: $0) })
        let page = NativeTestPage(profileID: profile.id), owner = DetachedNativeOwner()
        page.supportsTranslation = true
        page.state = PageNavigationState(url: URL(string:"https://fixture.invalid/resume")!,
            canGoBack:false, canGoForward:false)
        let session = try #require(f.tabs.bindDetachedNativePage(page, profile:profile, owner:owner, in:window))
        session.isTranslated = true
        let nodes = (0..<4096).map {
            PageTranslationNode(id:String($0), text:$0 == 4095 ? "Added while hidden" : "Source\($0)")
        }
        let first = Task { await session.runTranslation(onDevice:nil) }
        for _ in 0..<10 { await Task.yield() }
        try #require(page.translations.count == 1)
        for start in stride(from:0,to:2048,by:128) {
            page.onTranslationNodes?(Array(nodes[start..<start+128]))
        }
        first.cancel()
        page.onTranslationNodes?([nodes[4095]])
        page.translations[0].completion(PageTranslationResult())
        await first.value
        #expect(session.isTranslated && session.translationBacklog.count == 2049)
        let resumed = Task { await session.runTranslation(onDevice:nil) }
        for _ in 0..<10 { await Task.yield() }
        try #require(page.translations.count == 2)
        for start in stride(from:0,to:nodes.count,by:128) {
            page.onTranslationNodes?(Array(nodes[start..<start+128]))
        }
        #expect(session.translationBacklog.count == 4096)
        #expect(Set(session.translationBacklog.compactMap { $0["id"] as? String }).count == 4096)
        #expect(session.translationBacklog.contains { $0["text"] as? String == "Added while hidden" })
        #expect(session.translationBacklog.contains { $0["id"] as? String == "2048" })
        page.translations[1].completion(PageTranslationResult())
        await resumed.value
        #expect(session.isTranslated && session.translationBacklog.isEmpty && page.translations.count == 2)
        let id = f.tabs.adoptDetachedNativePage(session, through:f.host, in:window,
            spaceID:window.spaceID!, select:false)
        #expect(id == session.itemID && session.navigation === page && session.isTranslated)
        let oldSink = page.onTranslationNodes
        page.onEvent?(.committed(URL(string:"https://fixture.invalid/new-document")!, sameDocument:false))
        session.isTranslated = true
        oldSink?(nil)
        oldSink?([nodes[0]])
        for _ in 0..<10 { await Task.yield() }
        #expect(session.isTranslated && session.translationBacklog.isEmpty && page.translations.count == 2)
    }

    @Test(arguments: [false, true])
    func nativeTranslationStartAcceptsEntireBoundedDocument(characterBudget: Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = f.host.finishCreate(0)
        page.supportsTranslation = true
        let session = try #require(f.tabs.selectedSession(in: f.window))
        session.isTranslated = true
        // No installed language/model is needed: exercise the real start/feed
        // admission before a translator would consume its first batch.
        let run = Task { await session.runTranslation(onDevice: nil) }
        for _ in 0..<10 { await Task.yield() }
        try #require(page.translations.count == 1)
        let count = characterBudget ? 64 : 4096
        let text = characterBudget ? String(repeating: "𝒜", count: 16384) : "bonjour"
        let batchSize = characterBudget ? 1 : 128
        var all = (0..<count).map { PageTranslationNode(id: String($0), text: text) }
        let tail = Array(all.suffix(batchSize)); all.removeLast(batchSize)
        for start in stride(from: 0, to: all.count, by: batchSize) {
            page.onTranslationNodes?(Array(all[start..<min(start + batchSize, all.count)]))
        }
        page.translations[0].completion(PageTranslationResult(nodes: tail))
        await run.value
        for _ in 0..<10 { await Task.yield() }
        #expect(session.isTranslated, "accepted initial document overflowed before consumption")
        #expect(session.translationBacklog.isEmpty)
        #expect(page.translations.count == 1, "accepted start requested restoration")
        // Complete queued restoration on assertion failure, avoiding dangling continuations.
        for pending in page.translations.dropFirst() {
            if case .restore = pending.command { pending.completion(PageTranslationResult()) }
        }
    }

    @Test func nativePeekIntentLeavesCallbackAndCannotReviveAfterDocumentOrOwnerEnd() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = f.host.finishCreate(0)
        let session = try #require(f.tabs.selectedSession(in: f.window))
        let delegate = RecordingCertificateDelegate()
        f.tabs.sessionDelegate = delegate
        var links: [URL] = []
        delegate.onPeek = { url, source in
            #expect(source === session && source.navigation === page)
            links.append(url)
        }
        let sourceURL = session.url
        let first = URL(string: "https://fixture.invalid/peek-first")!
        let latest = URL(string: "https://fixture.invalid/peek-latest")!
        page.onEvent?(.peekRequested(first)); page.onEvent?(.peekRequested(latest))
        #expect(links.isEmpty && session.url == sourceURL)
        for _ in 0..<10 { await Task.yield() }
        #expect(links == [latest] && session.url == sourceURL)
        page.onEvent?(.peekRequested(first))
        page.onEvent?(.started(sourceURL))  // Same-URL reload also supersedes it.
        for _ in 0..<10 { await Task.yield() }
        #expect(links == [latest])
        page.onEvent?(.peekRequested(first))
        let stale = page.onEvent
        page.onEvent?(.ownerEnded)
        stale?(.peekRequested(latest))
        for _ in 0..<10 { await Task.yield() }
        #expect(links == [latest] && session.navigation == nil && session.primaryWebView == nil)
        #expect(f.host.creates.count == 1 && f.host.closes.isEmpty)
    }

    @Test func nativeTranslationQueuedCommandCannotRetargetNewDocument() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = f.host.finishCreate(0)
        page.supportsTranslation = true
        page.state = PageNavigationState(url: URL(string: "https://fixture.invalid/old")!,
            canGoBack: false, canGoForward: false)
        let session = try #require(f.tabs.selectedSession(in: f.window))
        page.onEvent?(.committed(page.state.url, sameDocument: false))
        session.toggleTranslation()
        page.onEvent?(.committed(URL(string: "https://fixture.invalid/new")!, sameDocument: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(page.translations.isEmpty && !session.isTranslated)
        session.isTranslated = true
        session.showOriginal()
        page.onEvent?(.committed(URL(string: "https://fixture.invalid/newer")!, sameDocument: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(page.translations.isEmpty && !session.isTranslated)
    }

    @Test func nativeTranslationBackpressureRestoresWithoutUnboundedBacklog() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = f.host.finishCreate(0)
        page.supportsTranslation = true
        let loadedBefore = page.loaded.count
        let session = try #require(f.tabs.selectedSession(in: f.window))
        session.isTranslated = true
        let start = Task { await session.callTranslateScript("start()") }
        for _ in 0..<10 { await Task.yield() }
        page.translations[0].completion(PageTranslationResult())
        _ = await start.value
        let (stream, feed) = AsyncStream.makeStream(of: [[String: Any]].self, bufferingPolicy: .bufferingOldest(1))
        defer { withExtendedLifetime(stream) {} }
        session.translationFeed = feed
        let oldSink = page.onTranslationNodes
        page.onTranslationNodes?([.init(id: "0", text: "one")])
        page.onTranslationNodes?([.init(id: "1", text: "two")])
        for _ in 0..<10 { await Task.yield() }
        #expect(!session.isTranslated && session.translationFeed == nil && session.translationBacklog.isEmpty)
        try #require(page.translations.count == 2)
        if case .restore = page.translations[1].command {} else { Issue.record("overflow did not restore") }
        page.translations[1].completion(PageTranslationResult())
        oldSink?([.init(id: "late", text: "stale")])
        #expect(session.translationBacklog.isEmpty)
        #expect(page.loaded.count == loadedBefore && session.primaryWebView == nil)
    }

    @Test(arguments: [false, true])
    func nativeTranslationSavedDetachedAndStaleDocument(isPrivate: Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let window = isPrivate ? f.privateWindow() : f.window
        let profile = try #require(isPrivate ? window.ephemeralProfile :
            window.spaceID.flatMap { f.tabs.profile(forSpace: $0) })
        let page = NativeTestPage(profileID: profile.id), owner = DetachedNativeOwner()
        page.supportsTranslation = true
        page.state = PageNavigationState(url: URL(string: "https://fixture.invalid/translate")!,
            canGoBack: false, canGoForward: false)
        let session = try #require(f.tabs.bindDetachedNativePage(page, profile: profile, owner: owner, in: window))
        let sampleTask = Task { await session.callTranslateScript("sample()") }
        for _ in 0..<10 { await Task.yield() }
        #expect(page.translations.count == 1)
        page.translations[0].completion(PageTranslationResult(text: "bonjour", lang: "fr"))
        let sample = await sampleTask.value as? [String: String]
        #expect(sample?["text"] == "bonjour" && sample?["lang"] == "fr")
        session.isTranslated = true
        let startTask = Task { await session.callTranslateScript("start()") }
        for _ in 0..<10 { await Task.yield() }
        page.translations[1].completion(PageTranslationResult(nodes: [.init(id: "0", text: "bonjour")]))
        #expect((await startTask.value as? [[String: String]])?.first?["id"] == "0")
        page.onTranslationNodes?([.init(id: "1", text: "salut")])
        #expect(session.translationBacklog.count == 1)
        session.unload()
        #expect(owner.requests == 1 && session.navigation === page)
        owner.complete(.cancelled)
        #expect(session.isTranslated && page.onTranslationNodes != nil && !page.invalidated)
        let originalGeneration = session.translationGeneration
        page.onEvent?(.committed(URL(string: "https://fixture.invalid/translate#same")!, sameDocument: true))
        #expect(session.translationGeneration == originalGeneration && session.isTranslated)
        let applyTask = Task { await session.callTranslateScript("apply(pairs)", arguments: ["pairs": [["0", "hello"]]]) }
        for _ in 0..<10 { await Task.yield() }
        page.onEvent?(.committed(URL(string: "https://fixture.invalid/new")!, sameDocument: false))
        page.translations[2].completion(PageTranslationResult())
        #expect(await applyTask.value == nil)
        #expect(!session.isTranslated && session.translationBacklog.isEmpty && page.onTranslationNodes == nil)
        let id = f.tabs.adoptDetachedNativePage(session, through: f.host, in: window,
            spaceID: window.spaceID!, select: false)
        #expect(id == session.itemID && session.navigation === page && page.loaded.isEmpty)
        let restoreTask = Task { await session.callTranslateScript("restore()") }
        for _ in 0..<10 { await Task.yield() }
        page.translations[3].completion(PageTranslationResult())
        _ = await restoreTask.value
        #expect(page.loaded.isEmpty && !page.invalidated)
        let lateTask = Task { await session.callTranslateScript("sample()") }
        for _ in 0..<10 { await Task.yield() }
        page.onEvent?(.ownerEnded)
        page.translations[4].completion(PageTranslationResult(text: "stale", lang: "fr"))
        #expect(await lateTask.value == nil && session.navigation == nil)
        #expect(page.onTranslationNodes == nil && !session.isTranslated)
    }

    @Test(arguments: [false, true])
    func detachedNativeBoostCSSFollowsEditsVetoPromotionAndClose(isPrivate: Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        await f.tabs.settings.waitForBoosts()
        f.tabs.settings.boosts = [Boost(host: "fixture.invalid", css: "body { color: red; }")]
        _ = f.host.finishCreate(0)
        let window = isPrivate ? f.privateWindow() : f.window
        let profile = try #require(isPrivate ? window.ephemeralProfile :
            window.spaceID.flatMap { f.tabs.profile(forSpace: $0) })
        let owner = DetachedNativeOwner(), page = NativeTestPage(profileID: profile.id)
        page.supportsUserCSS = true
        page.state = PageNavigationState(url: URL(string: "https://fixture.invalid/detached")!,
            canGoBack: false, canGoForward: false)
        let creates = f.host.creates.count
        let session = try #require(f.tabs.bindDetachedNativePage(page, profile: profile, owner: owner, in: window))
        for _ in 0..<10 { await Task.yield() }
        #expect(session.isDetached && f.tabs.session(for: session.itemID) == nil)
        #expect(page.styles.map(\.css) == ["body { color: red; }"])
        f.tabs.settings.boosts[0].css = "body { color: green; }"
        for _ in 0..<10 { await Task.yield() }
        #expect(page.styles.count == 2 && page.styles.last?.css == "body { color: green; }")
        f.tabs.settings.boosts[0].isEnabled = false
        for _ in 0..<10 { await Task.yield() }
        #expect(page.styles.count == 3 && page.styles.last?.css == "")
        f.tabs.settings.boosts[0].isEnabled = true
        for _ in 0..<10 { await Task.yield() }
        #expect(page.styles.count == 4)
        session.unload()
        #expect(owner.requests == 1 && session.navigation === page)
        f.tabs.settings.boosts[0].css = "body { color: blue; }"
        for _ in 0..<10 { await Task.yield() }
        #expect(page.styles.count == 4)
        owner.complete(.cancelled)
        for _ in 0..<10 { await Task.yield() }
        #expect(session.navigation === page && !page.invalidated)
        #expect(page.styles.count == 5 && page.styles.last?.css == "body { color: blue; }")
        let id = try #require(f.tabs.adoptDetachedNativePage(session, through: f.host, in: window,
            spaceID: window.spaceID!, select: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(id == session.itemID && session.navigation === page && !session.isDetached)
        #expect(page.styles.count == 5 && page.loaded.isEmpty)
        #expect(owner.requests == 1 && f.host.creates.count == creates && f.host.closes.isEmpty)
        f.tabs.settings.boosts[0].css = "body { color: yellow; }"
        for _ in 0..<10 { await Task.yield() }
        #expect(page.styles.count == 6 && page.styles.last?.css == "body { color: yellow; }")
        session.unload()
        f.host.finishClose(0, admitted: true)
        f.tabs.settings.boosts[0].css = "body { color: black; }"
        for _ in 0..<10 { await Task.yield() }
        #expect(page.styles.count == 6 && session.navigation == nil && page.invalidated)
        #expect(f.host.creates.count == creates && session.primaryWebView == nil)
    }

    @Test func savedNativeBoostCSSUpdatesRemovesAndSkipsSameDocumentDuplicates() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        await f.tabs.settings.waitForBoosts()
        f.tabs.settings.boosts = [Boost(host: "fixture.invalid", css: "body { color: red; }")]
        let native = f.host.finishCreate(0)
        native.supportsUserCSS = true
        let doc = URL(string: "https://fixture.invalid/first")!
        native.onEvent?(.committed(doc, sameDocument: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.map(\.css) == ["body { color: red; }"])
        native.onEvent?(.committed(URL(string: doc.absoluteString + "#state")!, sameDocument: true))
        f.tabs.settings.boosts.append(Boost(host: "other.invalid", css: "body { color: blue; }"))
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.count == 1)
        f.tabs.settings.boosts[0].css = "body { color: green; }"
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.map(\.css) == ["body { color: red; }", "body { color: green; }"])
        f.tabs.settings.boosts[0].isEnabled = false
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.last?.css == "" && native.styles.count == 3)
        #expect(f.tabs.selectedSession(in: f.window)?.primaryWebView == nil)
        #expect(f.host.creates.count == 1)
    }

    @Test func nativeBoostPickerResultBelongsOnlyToItsPreviewAndDocument() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        await f.tabs.settings.waitForBoosts()
        let native = f.host.finishCreate(0)
        native.supportsUserCSS = true
        native.supportsElementPicker = true
        native.onEvent?(.committed(URL(string: "https://fixture.invalid/picker")!, sameDocument: false))
        let session = try #require(f.tabs.selectedSession(in: f.window))
        let first = try #require(session.beginNativeBoostPreview())
        let stale = Task { await session.pickNativeBoostElement(token: first) }
        while native.picks.isEmpty { await Task.yield() }
        let second = try #require(session.beginNativeBoostPreview())
        #expect(native.pickerCancels > 0)
        native.picks[0].resume(returning: "#old")
        #expect(await stale.value == nil)
        let current = Task { await session.pickNativeBoostElement(token: second) }
        while native.picks.count < 2 { await Task.yield() }
        session.cancelNativeBoostElementPicker(token: first)
        let cancels = native.pickerCancels
        native.picks[1].resume(returning: "#chosen")
        #expect(await current.value == "#chosen" && native.pickerCancels == cancels)
        let outgoing = Task { await session.pickNativeBoostElement(token: second) }
        while native.picks.count < 3 { await Task.yield() }
        native.onEvent?(.committed(URL(string: "https://fixture.invalid/picker")!, sameDocument: false))
        native.picks[2].resume(returning: "#outgoing")
        #expect(await outgoing.value == nil)
        let lease = try #require(session.beginNativeBoostPreview())
        let closing = Task { await session.pickNativeBoostElement(token: lease) }
        while native.picks.count < 4 { await Task.yield() }
        session.endNativeBoostPreview(lease)
        native.picks[3].resume(returning: "#closed")
        #expect(await closing.value == nil)
        #expect(f.tabs.settings.boosts.isEmpty && f.host.creates.count == 1)
    }

    @Test func nativeBoostPreviewIsTransientAndCannotRestoreIntoNewDocumentOrLease() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        await f.tabs.settings.waitForBoosts()
        let saved = Boost(host: "fixture.invalid", css: "body { color: red; }")
        f.tabs.settings.boosts = [saved]
        let native = f.host.finishCreate(0)
        native.supportsUserCSS = true
        native.completeStyles = false
        let doc = URL(string: "https://fixture.invalid/preview")!
        native.onEvent?(.committed(doc, sameDocument: false))
        for _ in 0..<10 { await Task.yield() }
        let session = try #require(f.tabs.selectedSession(in: f.window))
        let token = try #require(session.beginNativeBoostPreview())
        var draft = saved; draft.css = "body { color: blue; }"
        #expect(session.previewNativeBoost(draft, token: token))
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.last?.css == draft.css && f.tabs.settings.boosts == [saved])
        let stale = try #require(native.styles.last?.completion)
        let replacement = try #require(session.beginNativeBoostPreview())
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.last?.css == saved.css)
        session.endNativeBoostPreview(token)
        #expect(!session.previewNativeBoost(draft, token: token))
        #expect(session.previewNativeBoost(draft, token: replacement))
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.last?.css == draft.css)
        f.tabs.settings.boosts[0].css = "body { color: green; }"
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.last?.css == draft.css)
        session.endNativeBoostPreview(replacement)
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.last?.css == "body { color: green; }")
        let count = native.styles.count
        stale(false)
        f.tabs.settings.boosts.append(Boost(host: "other.invalid", css: "body { color: black; }"))
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.count == count)
        let old = try #require(session.beginNativeBoostPreview())
        #expect(session.previewNativeBoost(draft, token: old))
        native.onEvent?(.committed(doc, sameDocument: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(!session.previewNativeBoost(draft, token: old))
        let newer = try #require(session.beginNativeBoostPreview())
        draft.css = "body { color: orange; }"
        #expect(session.previewNativeBoost(draft, token: newer))
        for _ in 0..<10 { await Task.yield() }
        let newerCount = native.styles.count
        session.endNativeBoostPreview(old)
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.count == newerCount && native.styles.last?.css == draft.css)
        session.nativeOwnerEnded()
        session.endNativeBoostPreview(newer)
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.count == newerCount && session.navigation == nil)
        #expect(f.tabs.settings.boosts[0].css == "body { color: green; }" && f.host.creates.count == 1)
    }

    @Test func nativeBoostCSSReloadAndStaleConfirmationDoNotResurrectOldStyle() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        await f.tabs.settings.waitForBoosts()
        f.tabs.settings.boosts = [Boost(host: "fixture.invalid", css: "body { color: red; }")]
        let native = f.host.finishCreate(0)
        native.supportsUserCSS = true
        native.completeStyles = false
        let doc = URL(string: "https://fixture.invalid/reload")!
        native.onEvent?(.committed(doc, sameDocument: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.count == 1)
        let old = try #require(native.styles.first?.completion)
        native.onEvent?(.committed(doc, sameDocument: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.count == 2)
        old(false)
        f.tabs.settings.boosts.append(Boost(host: "other.invalid", css: "body { color: blue; }"))
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.count == 2)
        let session = try #require(f.tabs.selectedSession(in: f.window))
        session.nativeOwnerEnded()
        native.styles.last?.completion(true)
        f.tabs.settings.boosts[0].css = "body { color: black; }"
        for _ in 0..<10 { await Task.yield() }
        #expect(native.styles.count == 2 && session.navigation == nil && session.primaryWebView == nil)
    }

    @Test func savedBoostCSSUsesExactPrivateSessionAndOnlyExistingPages() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        await f.tabs.settings.waitForBoosts()
        f.tabs.settings.boosts = [Boost(host: "fixture.invalid", css: "body { color: red; }")]
        let regular = f.host.finishCreate(0)
        regular.supportsUserCSS = true
        let privateWindow = f.privateWindow()
        let url = URL(string: "https://fixture.invalid/private")!
        _ = f.tabs.open(url: url, in: privateWindow, placement: .newTab)
        let privatePage = f.host.finishCreate(1)
        privatePage.supportsUserCSS = true
        privatePage.onEvent?(.committed(url, sameDocument: false))
        for _ in 0..<10 { await Task.yield() }
        #expect(privatePage.styles.map(\.css) == ["body { color: red; }"])
        #expect(privatePage.profileID == privateWindow.ephemeralProfile?.id)
        #expect(privatePage.profileID != regular.profileID && regular.styles.isEmpty)
        #expect(f.host.creates.count == 2)
        f.tabs.settings.boosts[0].css = "body { color: green; }"
        for _ in 0..<10 { await Task.yield() }
        #expect(privatePage.styles.last?.css == "body { color: green; }")
        #expect(regular.styles.isEmpty && f.host.creates.count == 2)
    }

    @Test func pausedNativeMiniPlayerSurvivesUnknownAndClearsAtDocumentEnd() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let session = try #require(f.tabs.selectedSession(in: f.window))
        let item = session.itemID
        _ = f.tabs.open(url: URL(string: "https://fixture.invalid/another")!, in: f.window, placement: .newTab)
        _ = f.host.finishCreate(1)
        func refresh() { f.window.miniPlayer.update(f.tabs.miniPlayerPages(for: f.window)) }
        let playing = PageMedia(hasMedia: true, isAudible: true, isPlaying: true, title: "Playing")
        native.onEvent?(.mediaChanged(playing)); refresh()
        #expect(f.window.miniPlayer.itemID == item)
        let paused = PageMedia(hasMedia: true, isAudible: false, isPlaying: false, title: "Paused")
        native.onEvent?(.mediaChanged(paused)); refresh()
        #expect(f.window.miniPlayer.itemID == item)
        native.onEvent?(.mediaChanged(nil)); refresh()
        #expect(f.window.miniPlayer.itemID == item && session.media.hasMedia && !session.media.isKnown)
        #expect(!session.media.canPlay && !session.media.canPause && session.media.title == nil)
        native.onEvent?(.mediaChanged(paused)); refresh()
        #expect(f.window.miniPlayer.itemID == item && session.media.isKnown && session.media.title == "Paused")
        native.onEvent?(.mediaChanged(PageMedia(canPlay: false, canPause: false))); refresh()
        #expect(f.window.miniPlayer.itemID == nil)
        native.onEvent?(.mediaChanged(playing)); refresh()
        #expect(f.window.miniPlayer.itemID == item)
        native.onEvent?(.committed(URL(string: "https://fixture.invalid/new-document"), sameDocument: false)); refresh()
        #expect(f.window.miniPlayer.itemID == nil && !session.media.hasMedia)
    }

    @Test func nativeMediaTransportUsesObservedPlaybackAndChangeOnlyWrites() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let session = try #require(f.tabs.selectedSession(in: f.window))
        #expect(!session.media.isKnown)
        session.togglePlayback(); session.skipTrack(forward: true)
        #expect(native.playbackRequests.isEmpty && native.trackRequests.isEmpty)
        native.state.isAudioMuted = false; native.state.isAudible = false
        native.state.hasVideoPictureInPicture = false; native.state.hasDocumentPictureInPicture = false
        native.state.media = PageMedia(hasMedia: true, isPlaying: true, hasVideo: true, isPlayingVideo: true,
            handlesPreviousTrack: true, handlesNextTrack: true, title: "Track", artist: "Artist", album: "Album")
        native.onStateChanged?(native.state)
        native.onEvent?(.mediaChanged(native.state.media))
        #expect(session.media.isPlaying && !session.media.isAudible && !session.hasPlayingAudio)
        #expect(session.media.title == "Track" && session.hasPlayingVideo)
        session.togglePlayback(); session.skipTrack(forward: true); session.skipTrack(forward: false)
        #expect(native.playbackRequests == [true] && native.trackRequests == [true, false])
        #expect(session.media.isPlaying, "Dispatch refusal/acceptance must not invent paused state")
        native.state.media?.isAudible = true
        native.onEvent?(.mediaChanged(native.state.media))
        native.onEvent?(.mediaChanged(nil))
        #expect(!session.media.isKnown && session.media.title == nil && !session.media.canPlay)
        #expect(session.hasAudioContent && session.hasPlayingVideo, "Unknown UI state erased activity protection")
        session.togglePlayback()
        #expect(native.playbackRequests == [true])
        native.state.media?.isAudible = false
        native.onEvent?(.mediaChanged(native.state.media))
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = session.media; _ = session.isAudioMuted; _ = session.hasAudioContent
            _ = session.hasPlayingAudio; _ = session.hasPiPActive
        } onChange: { changes.withLock { $0 += 1 } }
        native.state.title = "Unrelated page title"
        native.onStateChanged?(native.state)
        #expect(changes.withLock { $0 } == 0)
        let pending = URL(string: "https://fixture.invalid/pending-media-navigation")!
        session.load(pending)
        let playbackChanges = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = session.media } onChange: { playbackChanges.withLock { $0 += 1 } }
        native.state.media?.isPlaying = false; native.state.media?.isPlayingVideo = false
        native.onEvent?(.mediaChanged(native.state.media))
        #expect(session.url == pending && session.loadingState.isLoading,
                "Metadata reapplied an old committed navigation snapshot")
        #expect(playbackChanges.withLock { $0 } == 1 && !session.media.isPlaying)
        session.togglePlayback()
        #expect(native.playbackRequests == [true, false] && session.primaryWebView == nil)
        let late = native.onEvent
        session.nativeOwnerEnded()
        session.togglePlayback(); session.skipTrack(forward: true); session.toggleSound()
        late?(.mediaChanged(native.state.media))
        #expect(native.playbackRequests == [true, false] && session.media.title == nil && !session.media.hasMedia)
    }

    @Test func nativePictureInPictureWithoutNavigationNeverDelegatesToWebKit() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let delegate = RecordingCertificateDelegate()
        f.tabs.sessionDelegate = delegate
        let session = try #require(f.tabs.selectedSession(in: f.window))
        #expect(session.navigation == nil)
        session.requestPictureInPicture()
        #expect(delegate.pictureInPictureRequests == 0 && session.primaryWebView == nil && f.host.creates.count == 1)
        _ = f.host.finishCreate(0)
        session.nativeOwnerEnded()
        session.requestPictureInPicture()
        #expect(delegate.pictureInPictureRequests == 0 && session.navigation == nil && session.primaryWebView == nil)
    }

    @Test func nativePictureInPictureDispatchAndObservedKindsAvoidWebKit() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let native = f.host.finishCreate(0)
        let session = try #require(f.tabs.selectedSession(in: f.window))
        #expect(native.state.hasVideoPictureInPicture == nil && native.state.hasDocumentPictureInPicture == nil)
        session.requestPictureInPicture()
        #expect(native.pipRequests == 1 && !session.hasPiPActive && session.primaryWebView == nil)
        native.allowsPiP = true
        session.requestPictureInPicture()
        #expect(native.pipRequests == 2 && !session.hasPiPActive)
        native.state.hasVideoPictureInPicture = true; native.state.hasDocumentPictureInPicture = false
        native.onStateChanged?(native.state)
        #expect(session.hasPiPActive)
        native.state.hasVideoPictureInPicture = false; native.state.hasDocumentPictureInPicture = true
        native.onStateChanged?(native.state)
        #expect(session.hasPiPActive && session.primaryWebView == nil)
        // Unavailable observation must not overwrite a previously protected state.
        native.state.hasDocumentPictureInPicture = nil
        native.onStateChanged?(native.state)
        #expect(session.hasPiPActive)
        let late = native.onStateChanged
        session.nativeOwnerEnded()
        #expect(!session.hasPiPActive && session.navigation == nil)
        late?(PageNavigationState(canGoBack: false, canGoForward: false,
            hasVideoPictureInPicture: true, hasDocumentPictureInPicture: false))
        #expect(!session.hasPiPActive && session.primaryWebView == nil)
    }

    @Test func detachedNativePageUsesCloseOnlyOwnerWithoutLoadingOrPublishing() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let profile = try #require(f.window.spaceID.flatMap { f.tabs.profile(forSpace: $0) })
        let owner = DetachedNativeOwner()
        let page = NativeTestPage(profileID: profile.id)
        let host = "detached-native-\(UUID().uuidString.lowercased()).invalid"
        let cachedIcon = NSImage(size: NSSize(width: 16, height: 16))
        FaviconCache.shared.store(cachedIcon, for: host, toDisk: false)
        #expect(FaviconCache.shared.image(for: host) === cachedIcon)
        page.state = PageNavigationState(url: URL(string: "https://\(host)/already-loaded")!,
            title: "Loaded native document", canGoBack: false, canGoForward: false)
        let tree = f.tabs.tree, device = f.tabs.device, creates = f.host.creates.count
        let session = try #require(f.tabs.bindDetachedNativePage(page, profile: profile, owner: owner, in: f.window))
        #expect(session.navigation === page && session.isDetached && session.profile === profile)
        #expect(!session.hasFavicon)
        #expect(FaviconCache.shared.image(for: host) === cachedIcon)
        #expect(page.loaded.isEmpty && f.tabs.tree == tree && f.tabs.device == device)
        #expect(f.host.creates.count == creates && f.host.closes.isEmpty)
        session.unload()
        #expect(owner.requests == 1 && session.navigation === page)
        owner.complete(.cancelled)
        #expect(session.navigation === page && !page.invalidated)
        session.unload()
        owner.complete(.closed)
        #expect(owner.requests == 2 && session.navigation == nil && page.invalidated)
        #expect(f.tabs.tree == tree && f.tabs.device == device && f.host.closes.isEmpty)
    }

    @Test func detachedNativePromotionRetainsSessionAndRefusalRetainsSource() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let profile = try #require(f.window.spaceID.flatMap { f.tabs.profile(forSpace: $0) })
        let owner = DetachedNativeOwner(), page = NativeTestPage(profileID: profile.id)
        let session = try #require(f.tabs.bindDetachedNativePage(page, profile: profile, owner: owner, in: f.window))
        let tree = f.tabs.tree, creates = f.host.creates.count
        var closed = false
        session.onClose = { closed = true }
        f.host.admitSelection = false
        #expect(f.tabs.adoptDetachedNativePage(session, through: f.host, in: f.window,
            spaceID: f.window.spaceID!, select: true) == nil)
        #expect(session.isDetached && session.navigation === page && f.tabs.tree == tree && !closed)
        f.host.admitSelection = true
        let id = try #require(f.tabs.adoptDetachedNativePage(session, through: f.host, in: f.window,
            spaceID: f.window.spaceID!, select: true))
        #expect(id == session.itemID && f.tabs.session(for: id) === session)
        #expect(session.navigation === page && !session.isDetached && f.window.selectedItemID == id)
        #expect(page.loaded.isEmpty && !page.invalidated && owner.requests == 0 && !closed)
        #expect(f.host.creates.count == creates && f.host.closes.isEmpty)
    }

    @Test func detachedPrivatePromotionUsesExistingEphemeralSessionOnly() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let window = f.privateWindow(), foreign = f.privateWindow()
        let profile = try #require(window.ephemeralProfile)
        let owner = DetachedNativeOwner(), page = NativeTestPage(profileID: profile.id)
        let session = try #require(f.tabs.bindDetachedNativePage(page, profile: profile, owner: owner, in: window))
        let tree = f.tabs.tree, device = f.tabs.device
        #expect(f.tabs.adoptDetachedNativePage(session, through: f.host, in: foreign,
            spaceID: foreign.spaceID!, select: false) == nil)
        let id = try #require(f.tabs.adoptDetachedNativePage(session, through: f.host, in: window,
            spaceID: window.spaceID!, select: false))
        #expect(window.privateSessions[id] === session && session.navigation === page && !session.isDetached)
        #expect(f.tabs.tree == tree && f.tabs.device == device && page.loaded.isEmpty && !page.invalidated)
    }

    @Test func detachedBindingDoesNotOverwriteReentrantModelAdmission() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let profile = try #require(f.window.spaceID.flatMap { f.tabs.profile(forSpace: $0) })
        let owner = DetachedNativeOwner(), page = NativeTestPage(profileID: profile.id)
        var adopted: UUID?
        page.onReadState = {
            adopted = f.tabs.adoptNativePage(page, through: f.host, in: f.window,
                spaceID: f.window.spaceID!, select: false)
        }
        #expect(f.tabs.bindDetachedNativePage(page, profile: profile, owner: owner, in: f.window) == nil)
        let session = try #require(adopted.flatMap { f.tabs.session(for: $0) })
        #expect(session.navigation === page)
        page.onEvent?(.ownerEnded)
        #expect(session.navigation == nil && page.invalidated && owner.requests == 0)
    }

    @Test func detachedNativeBindingRejectsForeignProfileWithoutTouchingPage() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let profile = try #require(f.window.spaceID.flatMap { f.tabs.profile(forSpace: $0) })
        let owner = DetachedNativeOwner(), page = NativeTestPage(profileID: UUID())
        #expect(f.tabs.bindDetachedNativePage(page, profile: profile, owner: owner, in: f.window) == nil)
        #expect(!page.invalidated && page.loaded.isEmpty && owner.requests == 0)
    }

    @Test func splitPreparesHiddenPagesBeforePublishingTwoToFourPanes() throws {
        for count in 2...4 {
            let f = try NativeModelFixture(); defer { f.cleanup() }
            let firstID = try #require(f.window.selectedItemID)
            let first = f.host.finishCreate(0)
            let firstLoads = first.loaded
            var ids = [firstID]
            for index in 1..<count {
                ids.append(try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/pane-\(index)")!,
                    in: f.window, placement: .background)))
            }
            let record = try #require(SplitRecord(ids, orientation: .vertical))
            let selections = f.host.selectionCount
            var outcomes: [Bool] = []
            #expect(f.tabs.presentNativeSplit(record, activeItemID: ids.last, in: f.window) { outcomes.append($0) })
            #expect(f.window.split == nil && f.window.selectedItemID == firstID)
            for index in 1..<count {
                #expect(f.host.selectionCount == selections && f.window.split == nil)
                _ = f.host.finishCreate(index)
            }
            #expect(outcomes == [true] && f.window.split == record)
            #expect(f.window.selectedItemID == ids.last && f.host.selectionCount == selections)
            #expect(f.host.actualSplit == record && first.loaded == firstLoads)
            #expect(f.tabs.session(for: firstID)?.navigation === first)
            #expect(f.host.closes.isEmpty && first.invalidated == false)
        }
    }

    @Test func mixedProfileSplitPreparesExactPagesWithoutChangingTheirProfile() throws {
        for activePersonal in [false, true] {
            for admitted in [true, false] {
                let f = try NativeModelFixture(); defer { f.cleanup() }
                let firstID = try #require(f.window.selectedItemID)
                let first = f.host.finishCreate(0)
                let originalLoads = first.loaded
                let space = try #require(f.tabs.createSpace(name: "Personal", icon: "person", accentHex: "#123456", after: f.window.spaceID))
                let secondID = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/personal-pane")!,
                    in: f.window, placement: .background, parent: .tabs(spaceID: space)))
                let personal = try #require(f.tabs.profile(forSpace: space))
                #expect(personal.id != first.profileID)
                let record = try #require(SplitRecord([firstID, secondID]))
                let selections = f.host.selectionCount
                f.host.admitSplit = admitted
                var outcomes: [Bool] = []
                #expect(f.tabs.presentNativeSplit(record, activeItemID: activePersonal ? secondID : firstID, in: f.window) { outcomes.append($0) })
                #expect(outcomes.isEmpty && f.window.split == nil)
                #expect(f.host.creates[1].profileID == personal.id)
                let second = f.host.finishCreate(1)
                #expect(outcomes == [admitted])
                #expect(f.window.split == (admitted ? record : nil))
                #expect(f.window.selectedItemID == (admitted && activePersonal ? secondID : firstID) && f.host.selectionCount == selections)
                #expect(f.tabs.session(for: firstID)?.navigation === first)
                #expect(f.tabs.session(for: secondID)?.navigation === second)
                #expect(first.loaded == originalLoads && second.profileID == personal.id)
                #expect(!first.invalidated && !second.invalidated && f.host.closes.isEmpty)
            }
        }
    }

    @Test func liveRemainderNeverCreatesMissingOrEndedPages() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let firstID = try #require(f.window.selectedItemID)
        let first = f.host.finishCreate(0)
        let secondID = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/live-remainder")!,
            in: f.window, placement: .background))
        let record = try #require(SplitRecord([firstID, secondID]))
        var results: [Bool] = []
        #expect(!f.tabs.presentNativeSplit(record, activeItemID: firstID, in: f.window,
            liveAdmission: { true }) { results.append($0) })
        #expect(results == [false] && f.host.creates.count == 1)
        f.tabs.select(secondID, in: f.window)
        let second = f.host.finishCreate(1)
        f.tabs.select(firstID, in: f.window)
        let creations = f.host.creates.count
        f.host.onSplit = { second.onEvent?(.ownerEnded) }
        #expect(f.tabs.presentNativeSplit(record, activeItemID: firstID, in: f.window,
            liveAdmission: { true }) { results.append($0) })
        #expect(results == [false, false] && f.window.split == nil)
        #expect(f.tabs.item(secondID) != nil && f.tabs.session(for: secondID)?.navigation == nil)
        #expect(f.host.creates.count == creations && !first.invalidated)
        #expect(!f.tabs.presentNativeSplit(record, activeItemID: firstID, in: f.window,
            liveAdmission: { true }) { results.append($0) })
        #expect(results == [false, false, false] && f.host.creates.count == creations)
    }

    @Test func liveRemainderReentrantSelectionCancelsOnlyItsOwnAttempt() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let firstID = try #require(f.window.selectedItemID)
        _ = f.host.finishCreate(0)
        let secondID = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/live-second")!,
            in: f.window, placement: .newTab))
        _ = f.host.finishCreate(1)
        f.tabs.select(firstID, in: f.window)
        let record = try #require(SplitRecord([firstID, secondID]))
        let creations = f.host.creates.count
        var validations = 0, results: [Bool] = []
        #expect(f.tabs.presentNativeSplit(record, activeItemID: firstID, in: f.window, liveAdmission: {
            validations += 1
            if validations == 2 { f.tabs.select(secondID, in: f.window) }
            return true
        }) { results.append($0) })
        #expect(results == [false] && f.window.selectedItemID == secondID && f.window.split == nil)
        #expect(f.host.creates.count == creations && f.window.nativeSplitPreparation == nil)
    }

    @Test func cancelledSplitKeepsSavedLayoutAndRejectsLatePreparedPage() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let firstID = try #require(f.window.selectedItemID)
        _ = f.host.finishCreate(0)
        let second = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/old")!, in: f.window, placement: .background))
        let old = try #require(SplitRecord([firstID, second]))
        #expect(f.tabs.presentNativeSplit(old, activeItemID: firstID, in: f.window))
        _ = f.host.finishCreate(1)
        let cold = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/cold")!, in: f.window, placement: .background))
        let requested = try #require(SplitRecord([firstID, cold]))
        var outcomes: [Bool] = []
        #expect(f.tabs.presentNativeSplit(requested, activeItemID: cold, in: f.window) { outcomes.append($0) })
        let applications = f.host.splitCount
        f.tabs.select(firstID, in: f.window)
        #expect(outcomes == [false] && f.host.creates[2].cancelled)
        #expect(f.window.split == old && f.host.actualSplit == old)
        let late = f.host.finishCreate(2)
        #expect(late.loaded.isEmpty && f.host.splitCount == applications)
        #expect(f.window.selectedItemID == firstID && f.window.split == old)
    }

    @Test func splitRefusalPreservesExistingLayoutAndUnrelatedSelection() throws {
        for unrelated in [false, true] {
            let f = try NativeModelFixture(synchronous: true); defer { f.cleanup() }
            let firstID = try #require(f.window.selectedItemID)
            let first = try #require(f.tabs.session(for: firstID)?.navigation as? NativeTestPage)
            let second = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/second")!, in: f.window, placement: .background))
            let old = try #require(SplitRecord([firstID, second]))
            #expect(f.tabs.presentNativeSplit(old, activeItemID: firstID, in: f.window))
            let cold = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/new")!, in: f.window, placement: .background))
            if unrelated {
                _ = f.tabs.open(url: URL(string: "https://fixture.invalid/unrelated")!, in: f.window, placement: .newTab)
            }
            let selected = f.window.selectedItemID, selections = f.host.selectionCount, loads = first.loaded
            f.host.admitSplit = false
            var outcomes: [Bool] = []
            let request = try #require(SplitRecord([second, cold]))
            #expect(f.tabs.presentNativeSplit(request, activeItemID: cold, in: f.window) { outcomes.append($0) })
            #expect(outcomes == [false] && f.window.split == old && f.host.actualSplit == old)
            #expect(f.window.selectedItemID == selected && f.host.selectionCount == selections)
            #expect(first.loaded == loads && first.invalidated == false)
        }
    }

    @Test func reentrantSplitAdmissionCannotOverwriteNewSelection() throws {
        let f = try NativeModelFixture(synchronous: true); defer { f.cleanup() }
        let first = try #require(f.window.selectedItemID)
        let second = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/second")!, in: f.window, placement: .background))
        let other = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/other")!, in: f.window, placement: .background))
        let old = try #require(SplitRecord([first, second]))
        #expect(f.tabs.presentNativeSplit(old, activeItemID: first, in: f.window))
        f.host.onSplit = { f.tabs.select(other, in: f.window) }
        var outcomes: [Bool] = []
        let request = try #require(SplitRecord([second, other]))
        #expect(f.tabs.presentNativeSplit(request, activeItemID: other, in: f.window) { outcomes.append($0) })
        #expect(outcomes == [false] && f.window.selectedItemID == other)
        #expect(f.window.split == old && f.host.actualSplit == old)
        #expect(f.window.nativeSplitPreparation == nil)
    }

    @Test func clearingColdSavedSplitNeverLoadsItsPanes() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let first = try #require(f.window.selectedItemID)
        let cold = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/cold")!, in: f.window, placement: .background))
        f.window.split = SplitRecord([first, cold])
        let creations = f.host.creates.count, selections = f.host.selectionCount
        var outcomes: [Bool] = []
        #expect(f.tabs.presentNativeSplit(nil, activeItemID: first, in: f.window) { outcomes.append($0) })
        #expect(outcomes == [true] && f.window.split == nil)
        #expect(f.window.selectedItemID == first && f.host.creates.count == creations)
        #expect(f.host.selectionCount == selections && f.tabs.session(for: cold) == nil)
    }

    @Test(arguments: [false, true])
    func profileChangeCannotStartWithoutDurableIntent(keepSource: Bool) throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), item = try #require(f.window.selectedItemID)
        let source = try #require(f.tabs.tree.dataStoreID(for: space))
        let originalKept = f.tabs.device.keptProfiles
        f.tabs.saveNow()
        var nativeInvoked = false
        f.tabs.onDeleteProfile = { _, _, _, _ in nativeInvoked = true }
        let path = f.directory.appendingPathComponent("Tabs"), saved = f.directory.appendingPathComponent("saved-tabs")
        try FileManager.default.moveItem(at: path, to: saved)
        try Data("not a directory".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.moveItem(at: saved, to: path) }
        var failure: ProfileDeletionError?
        f.tabs.setProfile(space, to: nil, keepingLeftProfile: keepSource) {
            if case .failure(let error) = $0 { failure = error }
        }
        #expect(failure == .persistenceFailed && !nativeInvoked && f.host.closes.isEmpty)
        #expect(f.tabs.device.pendingProfileDeletion == nil && f.tabs.device.keptProfiles == originalKept)
        #expect(f.tabs.tree.dataStoreID(for: space) == source && f.tabs.tree.item(item) != nil)
        #expect(f.tabs.session(for: item)?.navigation === page && !page.invalidated)
    }

    @Test func activeCancellationPersistenceFailureKeepsReservationUntilDurableRetry() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), source = try #require(f.tabs.tree.dataStoreID(for: space))
        let other = try #require(f.tabs.createSpace(name: "Survivor", icon: "", accentHex: "#123456", after: space))
        let survivor = try #require(f.tabs.tree.dataStoreID(for: other))
        var callback: (@MainActor (ProfileDeletionOutcome) -> Void)?
        f.tabs.onDeleteProfile = { _, _, _, done in callback = done }
        f.tabs.deleteProfile(source, surviving: survivor) { _ in }
        let path = f.directory.appendingPathComponent("Tabs"), saved = f.directory.appendingPathComponent("saved-tabs")
        try FileManager.default.moveItem(at: path, to: saved)
        try Data("not a directory".utf8).write(to: path)
        var acknowledgements = 0
        callback?(.cancelled(acknowledge: { acknowledgements += 1; return true }))
        #expect(acknowledgements == 0 && f.tabs.device.pendingProfileDeletion != nil)
        #expect(!f.tabs.isProfileAvailable(source) && f.tabs.tree.dataStoreID(for: space) == source)
        try FileManager.default.removeItem(at: path); try FileManager.default.moveItem(at: saved, to: path)
        f.tabs.retryPendingProfileChange { _ in }
        callback?(.cancelled(acknowledge: { acknowledgements += 1; return true }))
        #expect(acknowledgements == 1 && f.tabs.device.pendingProfileDeletion == nil)
        #expect(f.tabs.isProfileAvailable(source))
    }

    @Test func profileReassignmentVetoPreservesIDsAndUnrelatedSourceSpace() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let original = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), item = try #require(f.window.selectedItemID)
        let source = try #require(f.tabs.tree.dataStoreID(for: space))
        let shared = try #require(f.tabs.createSpace(name: "Other source", icon: "", accentHex: "#123456", after: space, sharingLoginsWith: space))
        let destination = try #require(f.tabs.createSpace(name: "Destination", icon: "", accentHex: "#123456", after: shared))
        let target = try #require(f.tabs.tree.dataStoreID(for: destination))
        let other = BrowserWindowState(); other.spaceID = shared
        f.registry.register(other); f.tabs.attach(window: other, restoringSavedState: false)
        var erased = false
        f.tabs.onDeleteProfile = { _, _, _, _ in erased = true }
        var result: ProfileDeletionError?
        f.tabs.setProfile(space, to: target) { if case .failure(let error) = $0 { result = error } }
        #expect(f.host.closes.count == 1 && f.host.closes[0].page === original)
        #expect(f.tabs.tree.dataStoreID(for: space) == source)
        #expect(f.tabs.isProfileAvailable(source) && f.tabs.profile(forSpace: shared)?.id == source)
        let next = f.host.creates.count
        let otherItem = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/other")!, in: other, placement: .newTab))
        let otherPage = f.host.finishCreate(next)
        #expect(otherPage.profileID == source)
        f.host.finishClose(0, admitted: false)
        #expect(result == .cancelled && !erased)
        #expect(f.tabs.tree.dataStoreID(for: space) == source && f.tabs.tree.item(item) != nil)
        #expect(f.tabs.session(for: item)?.navigation === original && !original.invalidated)
        #expect(f.tabs.session(for: otherItem)?.navigation === otherPage && !otherPage.invalidated)
        #expect(f.tabs.device.pendingProfileDeletion == nil)
    }

    @Test func profileReassignmentRecreatesExactDestinationWithoutCloningOrChangingIDs() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let old = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), id = try #require(f.window.selectedItemID)
        let session = try #require(f.tabs.session(for: id)), url = session.url
        let destinationSpace = try #require(f.tabs.createSpace(name: "Destination", icon: "", accentHex: "#123456", after: space))
        let destination = try #require(f.tabs.tree.dataStoreID(for: destinationSpace))
        var reloads = 0
        f.tabs.onProfileWindowsNeedReload = { windows in
            reloads += 1
            #expect(windows.contains(f.window.id))
            let saved = TabStore(directory: f.directory.appendingPathComponent("Tabs")).load()
            #expect(saved.tree.dataStoreID(for: space) == destination)
            #expect(saved.device.pendingProfileDeletion?.change?.phase == .assignmentCommitted)
            f.tabs.select(id, in: f.window)
        }
        var succeeded = false
        f.tabs.setProfile(space, to: destination, keepingLeftProfile: true) { if case .success = $0 { succeeded = true } }
        #expect(f.host.creates.count == 1)
        f.host.finishClose(0, admitted: true)
        #expect(succeeded && reloads == 1 && old.invalidated)
        #expect(f.tabs.session(for: id) === session && f.tabs.tree.item(id) != nil)
        #expect(f.host.creates.count == 2 && f.host.creates[1].profileID == destination)
        let replacement = f.host.finishCreate(1)
        #expect(replacement !== old && replacement.loaded == [url])
        #expect(session.navigation === replacement && session.primaryWebView == nil)
        #expect(f.tabs.device.pendingProfileDeletion == nil)
    }

    @Test func activeDeletionContinuesWipeOnlyAfterDurableAssignmentAndSourceRecord() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let old = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), id = try #require(f.window.selectedItemID)
        let source = try #require(f.tabs.tree.dataStoreID(for: space))
        let destinationSpace = try #require(f.tabs.createSpace(name: "Destination", icon: "", accentHex: "#123456", after: space))
        let destination = try #require(f.tabs.tree.dataStoreID(for: destinationSpace))
        var prepare: (@MainActor (ProfileDeletionOutcome) -> Void)?
        f.tabs.onDeleteProfile = { intent, reconciliation, canDelete, done in
            #expect(intent.change?.kind == .deleteProfile && !reconciliation && canDelete())
            prepare = done
        }
        var continued = false
        f.tabs.deleteProfile(source, surviving: destination) { _ in }
        #expect(f.tabs.tree.dataStoreID(for: space) == source)
        #expect(!f.tabs.isProfileAvailable(source))
        prepare?(.closeAdmitted(continueCleanup: { done in
            let disk = TabStore(directory: f.directory.appendingPathComponent("Tabs")).load()
            #expect(disk.tree.dataStoreID(for: space) == destination && disk.tree.item(id) != nil)
            #expect(disk.device.pendingProfileDeletion?.change?.phase == .assignmentCommitted)
            #expect(disk.device.keptProfiles?.contains { $0.id == source } == true)
            continued = true; done(.pending)
        }))
        #expect(continued && old.invalidated)
        #expect(f.tabs.tree.item(id) != nil && f.tabs.isProfileAvailable(destination))
        #expect(!f.tabs.isProfileAvailable(source) && f.tabs.device.pendingProfileDeletion != nil)
        let existing = f.tabs.device.pendingProfileDeletion
        var refusedBypass = false
        f.tabs.deleteKeptProfile(source, surviving: destination) {
            if case .failure(.unavailable) = $0 { refusedBypass = true }
        }
        #expect(refusedBypass && f.tabs.device.pendingProfileDeletion == existing)
        #expect(f.host.closes.isEmpty, "Native profile authority already admitted every owner; don't close twice")
    }

    @Test func assignmentSaveFailureNeverContinuesWipeAndRetainsWindowID() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), item = try #require(f.window.selectedItemID)
        let source = try #require(f.tabs.tree.dataStoreID(for: space))
        let destinationSpace = try #require(f.tabs.createSpace(name: "Destination", icon: "", accentHex: "#123456", after: space))
        let destination = try #require(f.tabs.tree.dataStoreID(for: destinationSpace))
        var prepared: (@MainActor (ProfileDeletionOutcome) -> Void)?
        f.tabs.onDeleteProfile = { _, _, _, done in prepared = done }
        f.tabs.deleteProfile(source, surviving: destination) { _ in }
        f.tabs.detach(window: f.window); f.registry.unregister(f.window.id)
        #expect(f.tabs.device.windows.contains { $0.id == f.window.id })
        let path = f.directory.appendingPathComponent("Tabs"), saved = f.directory.appendingPathComponent("saved-tabs")
        try FileManager.default.moveItem(at: path, to: saved)
        try Data("not a directory".utf8).write(to: path)
        var wiped = false
        prepared?(.closeAdmitted(continueCleanup: { _ in wiped = true }))
        #expect(!wiped && f.tabs.tree.dataStoreID(for: space) == source)
        #expect(f.tabs.tree.item(item) != nil && f.tabs.device.pendingProfileDeletion != nil)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: saved, to: path)
    }

    @Test func newProfileReassignmentPersistsItsIdentityBeforeCloseAndCancelsUncommittedRestart() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), original = try #require(f.tabs.tree.dataStoreID(for: space))
        f.tabs.setProfile(space, to: nil, name: "Research", keepingLeftProfile: true)
        let intent = try #require(f.tabs.device.pendingProfileDeletion)
        #expect(intent.change?.newDestination?.id == intent.survivor)
        #expect(intent.change?.newDestination?.name == "Research")
        let disk = TabStore(directory: f.directory.appendingPathComponent("Tabs")).load()
        #expect(disk.device.pendingProfileDeletion == intent)
        #expect(disk.device.keptProfiles?.contains { $0.id == intent.survivor && $0.name == "Research" } == true)
        let clone = f.directory.appendingPathComponent("Restart/Tabs")
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.directory.appendingPathComponent("Tabs"), to: clone)
        let recovered = f.restored(at: clone)
        var nativeInvoked = false
        recovered.onDeleteProfile = { _, _, _, _ in nativeInvoked = true }
        recovered.resumePendingProfileDeletion { _ in }
        #expect(!nativeInvoked && recovered.device.pendingProfileDeletion == nil)
        #expect(recovered.tree.dataStoreID(for: space) == original)
        #expect(recovered.profiles.contains { $0.id == intent.survivor && $0.name == "Research" })
    }

    @Test(arguments: [PendingProfileChange.Kind.reassignSpace, .deleteProfile])
    func structureOnlyAssignmentWriteRecoversWithoutDataDeletion(kind: PendingProfileChange.Kind) throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), item = try #require(f.window.selectedItemID)
        let source = try #require(f.tabs.tree.dataStoreID(for: space))
        let destinationSpace = try #require(f.tabs.createSpace(name: "Destination", icon: "", accentHex: "#123456", after: space))
        let destination = try #require(f.tabs.tree.dataStoreID(for: destinationSpace))
        f.tabs.onDeleteProfile = { _, _, _, _ in }
        f.tabs.setProfile(space, to: destination, keepingLeftProfile: kind == .reassignSpace)
        var device = f.tabs.device
        var intent = try #require(device.pendingProfileDeletion)
        intent.change?.phase = .closeAdmitted
        device.pendingProfileDeletion = intent
        let crashPath = f.directory.appendingPathComponent("CrashDisk/Tabs")
        let store = TabStore(directory: crashPath)
        store.save(f.tabs.tree, device); store.flush()
        #expect(store.lastError == nil)
        var moved = f.tabs.tree
        try moved.setProfile(space, to: destination, kept: device.keptProfiles ?? [])
        var next = device
        next.keptProfiles = (next.keptProfiles ?? []) + [try #require(intent.change?.source)]
        intent.change?.phase = .assignmentCommitted; next.pendingProfileDeletion = intent
        let deviceFile = crashPath.appendingPathComponent("device.json")
        // A real deterministic device-replacement failure: structure remains
        // writable, while the original device file remains readable/unchanged.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: deviceFile.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: deviceFile.path) }
        store.save(moved, next); store.flush()
        #expect(store.lastError != nil)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: deviceFile.path)
        let partial = TabStore(directory: crashPath).load()
        #expect(partial.tree.dataStoreID(for: space) == destination)
        #expect(partial.device.pendingProfileDeletion?.change?.phase == .closeAdmitted)
        let recovered = f.restored(at: crashPath)
        var reconciliationCalls = 0
        recovered.onDeleteProfile = { requested, reconcileOnly, canDelete, done in
            reconciliationCalls += 1
            #expect(reconcileOnly && canDelete() && requested.change?.kind == .deleteProfile)
            done(.cancelled(acknowledge: { true }))
        }
        recovered.resumePendingProfileDeletion { _ in }
        #expect(reconciliationCalls == (kind == .deleteProfile ? 1 : 0))
        #expect(recovered.tree.dataStoreID(for: space) == destination && recovered.tree.item(item) != nil)
        #expect(recovered.device.pendingProfileDeletion == nil)
        #expect(recovered.device.keptProfiles?.contains { $0.id == source } == true)
        #expect(recovered.isProfileAvailable(source))
        #expect(recovered.device.windows.contains { $0.id == f.window.id })
    }

    @Test func activePreparedRecoveryDoesNotWipeOrChangeAssignmentAfterVeto() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID), source = try #require(f.tabs.tree.dataStoreID(for: space))
        let destinationSpace = try #require(f.tabs.createSpace(name: "Destination", icon: "", accentHex: "#123456", after: space))
        let destination = try #require(f.tabs.tree.dataStoreID(for: destinationSpace))
        f.tabs.onDeleteProfile = { _, _, _, _ in }
        f.tabs.deleteProfile(source, surviving: destination) { _ in }
        let clone = f.directory.appendingPathComponent("Restart/Tabs")
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.directory.appendingPathComponent("Tabs"), to: clone)
        let recovered = f.restored(at: clone)
        var acknowledged = false
        recovered.onDeleteProfile = { _, reconcileOnly, _, done in
            #expect(reconcileOnly)
            done(.cancelled(acknowledge: { acknowledged = true; return true }))
        }
        recovered.resumePendingProfileDeletion { _ in }
        #expect(acknowledged && recovered.device.pendingProfileDeletion == nil)
        #expect(recovered.tree.dataStoreID(for: space) == source && recovered.isProfileAvailable(source))
    }

    @Test func acceptedQuitPreservesAllSavedWindowsBeforeRegistryRetirement() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let other = BrowserWindowState(); other.spaceID = f.window.spaceID
        f.registry.register(other); f.tabs.attach(window: other, restoringSavedState: false)
        let request = f.host.creates.count
        _ = f.tabs.open(url: URL(string: "https://fixture.invalid/second")!, in: other, placement: .newTab)
        _ = f.host.finishCreate(request)
        let ids = Set([f.window.id, other.id]), tree = f.tabs.tree
        f.tabs.flushSync()
        #expect(Set(f.tabs.device.windows.map(\.id)) == ids)
        f.registry.onWindowClose = { id in if let window = f.registry.windows[id] { f.tabs.detach(window: window) } }
        f.registry.unregister(f.window.id); f.registry.unregister(other.id)
        #expect(Set(f.tabs.device.windows.map(\.id)) == ids && f.tabs.tree == tree)
        f.tabs.saveNow()
        let saved = TabStore(directory: f.directory.appendingPathComponent("Tabs")).load()
        #expect(Set(saved.device.windows.map(\.id)) == ids && saved.tree == tree)
    }

    @Test func lateQuitCancellationResumesNativeOperationsWithoutReplacingSavedItems() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        _ = f.host.finishCreate(0)
        let original = f.tabs.tree, selected = f.window.selectedItemID
        let other = BrowserWindowState(); other.spaceID = f.window.spaceID
        f.registry.register(other); f.tabs.attach(window: other, restoringSavedState: false)
        f.tabs.mirror(other)
        f.tabs.flushSync()
        f.tabs.resumeAfterCancelledTermination()
        #expect(f.tabs.tree == original && f.window.selectedItemID == selected)
        f.registry.onWindowClose = { id in if let window = f.registry.windows[id] { f.tabs.detach(window: window) } }
        f.registry.unregister(other.id)
        #expect(!f.tabs.device.windows.contains { $0.id == other.id })
        #expect(f.tabs.device.windows.contains { $0.id == f.window.id })
        let request = f.host.creates.count
        let id = try #require(f.tabs.open(url: URL(string: "https://fixture.invalid/resumed")!, in: f.window, placement: .newTab))
        #expect(f.host.creates.count == request + 1)
        _ = f.host.finishCreate(request)
        #expect(f.window.selectedItemID == id && f.tabs.session(for: id)?.navigation != nil)
        #expect(original.items.keys.allSatisfy { f.tabs.tree.item($0)?.url == original.item($0)?.url })
        #expect(f.host.closes.isEmpty)
    }

    @Test func nativeSwitcherCapturePrecedesHostSelectionAndNeverCreatesWebKit() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let first = try #require(f.tabs.selectedSession(in: f.window))
        let native = f.host.finishCreate(0)
        native.allowsThumbnails = true
        var capturedBeforeSelection = false
        f.host.onSelect = { _, _ in
            capturedBeforeSelection = native.thumbnailCompletions.count == 1
        }
        _ = f.tabs.open(url: URL(string: "about:blank")!, in: f.window, placement: .newTab)
        _ = f.host.finishCreate(1)
        #expect(capturedBeforeSelection && first.primaryWebView == nil)
        #expect(first.switcherCaptureInFlight != nil)
    }

    @Test func reentrantSwitcherCaptureCannotSelectSupersededTarget() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let first = try #require(f.tabs.selectedSession(in: f.window))
        let native = f.host.finishCreate(0)
        native.allowsThumbnails = true
        let selections = f.host.selectionCount
        native.onCapture = { f.tabs.select(first.itemID, in: f.window) }
        let second = try #require(f.tabs.open(url: URL(string: "about:blank#second")!,
            in: f.window, placement: .newTab))
        _ = f.host.finishCreate(1)
        #expect(f.window.selectedItemID == first.itemID && f.window.selectedItemID != second)
        #expect(f.host.selectionCount == selections + 1)
    }

    @Test func pendingSwitcherCaptureCannotReturnAfterRecentBudgetPrunesNilImage() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let first = try #require(f.tabs.selectedSession(in: f.window))
        let native = f.host.finishCreate(0)
        native.allowsThumbnails = true
        let generation = first.switcherSnapshotGeneration
        for index in 1...TabSwitcherState.maxItems {
            _ = f.tabs.open(url: URL(string: "about:blank#\(index)")!, in: f.window, placement: .newTab)
            _ = f.host.finishCreate(index)
        }
        #expect(first.switcherSnapshot == nil && native.thumbnailCompletions.count == 1)
        #expect(!f.tabs.recentItems(in: f.window).prefix(TabSwitcherState.maxItems).contains(first.itemID))
        #expect(first.switcherSnapshotGeneration != generation)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2,
            pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        native.thumbnailCompletions[0](bitmap.representation(using: .png, properties: [:]))
        #expect(first.switcherSnapshot == nil && first.switcherCaptureInFlight == nil)
    }

    @Test func switcherClearNavigationAndOwnerEndRejectLateThumbnails() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = try #require(f.tabs.selectedSession(in: f.window))
        let native = f.host.finishCreate(0)
        native.allowsThumbnails = true
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2,
            pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        page.captureSwitcherSnapshot(); page.captureSwitcherSnapshot()
        #expect(native.thumbnailCompletions.count == 1)
        page.switcherSnapshot = nil
        native.thumbnailCompletions[0](png)
        #expect(page.switcherSnapshot == nil && page.switcherCaptureInFlight == nil)
        page.captureSwitcherSnapshot()
        native.onEvent?(.started(URL(string: "about:blank")))
        native.thumbnailCompletions[1](png)
        #expect(page.switcherSnapshot == nil)
        page.captureSwitcherSnapshot()
        native.thumbnailCompletions[2](png)
        #expect(page.switcherSnapshot != nil)
        page.switcherSnapshot = nil
        page.captureSwitcherSnapshot()
        let late = native.thumbnailCompletions[3]
        page.nativeOwnerEnded()
        late(png)
        #expect(page.switcherSnapshot == nil && page.navigation == nil && page.primaryWebView == nil)
    }

    @Test func privateNativeAdoptionIsEphemeralAndOwnerEndNeverDeletesSavedState() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let a = f.privateWindow(), b = f.privateWindow()
        let page = NativeTestPage(profileID: try #require(a.ephemeralProfile?.id))
        let tree = f.tabs.tree, device = f.tabs.device, creates = f.host.creates.count
        var published = false
        withObservationTracking { _ = f.tabs.sessions; _ = f.tabs.miniPlayerPages(for: a) } onChange: {
            MainActor.assumeIsolated { published = true }
        }
        let id = try #require(f.tabs.adoptNativePage(page, through: f.host, in: a,
            spaceID: a.spaceID!, select: false))
        let session = try #require(f.tabs.session(for: id))
        #expect(published && session.isPrivate && session.profile === a.ephemeralProfile && session.navigation === page)
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: b,
            spaceID: b.spaceID!, select: false) == nil)
        f.host.nativeSelectedPage = page; f.host.nativeSelectedWindow = a.id
        #expect(f.tabs.reflectNativeSelection(id, in: a))
        #expect(a.selectedItemID == id && page.loaded.isEmpty && f.host.creates.count == creates)
        page.onEvent?(.ownerEnded)
        #expect(a.privateTree?.item(id) != nil && session.navigation == nil && page.invalidated)
        #expect(f.tabs.tree == tree && f.tabs.device == device && f.host.closes.isEmpty)
        f.tabs.detach(window: a); f.registry.unregister(a.id)
        #expect(a.privateTree == nil && a.privateSessions.isEmpty && f.tabs.device == device)
    }

    @Test func privateExistingAndTransferredSelectHonorsHostAdmission() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let source = f.privateWindow(), target = f.privateWindow(sharing: source.ephemeralProfile)
        let page = NativeTestPage(profileID: source.ephemeralProfile!.id)
        let id = try #require(f.tabs.adoptNativePage(page, through: f.host, in: source,
            spaceID: source.spaceID!, select: false))
        f.host.admitSelection = false
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: source,
            spaceID: source.spaceID!, select: true) == nil)
        #expect(source.selectedItemID == nil && f.host.selectionCount == 1)
        f.host.admitSelection = true
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: source,
            spaceID: source.spaceID!, select: true) == id)
        #expect(source.selectedItemID == id && f.host.selectionCount == 2)
        f.host.admitSelection = false
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: target,
            spaceID: target.spaceID!, select: true) == nil)
        #expect(source.privateSessions[id] != nil && target.privateSessions[id] == nil && source.selectedItemID == id)
        f.host.admitSelection = true
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: target,
            spaceID: target.spaceID!, select: true) == id)
        #expect(target.selectedItemID == id && source.selectedItemID == nil && f.host.selectionCount == 4)
        #expect(f.host.closes.isEmpty && page.loaded.isEmpty && !page.invalidated)
    }

    @Test func privateNewPagePublicationCannotOverwriteNewerSelection() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let window = f.privateWindow(), profile = window.ephemeralProfile!.id
        let first = NativeTestPage(profileID: profile), rejected = NativeTestPage(profileID: profile)
        let id = try #require(f.tabs.adoptNativePage(first, through: f.host, in: window,
            spaceID: window.spaceID!, select: false))
        let tree = try #require(window.privateTree)
        var observed = false
        withObservationTracking { _ = window.privateTree } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }; observed = true
                f.tabs.select(id, in: window)
            }
        }
        #expect(f.tabs.adoptNativePage(rejected, through: f.host, in: window,
            spaceID: window.spaceID!, select: true) == nil)
        #expect(observed && window.selectedItemID == id && window.privateTree == tree)
        #expect(window.privateSessions.count == 1 && window.privateSessions[id]?.navigation === first)
        #expect(rejected.onEvent == nil && rejected.onStateChanged == nil && !rejected.invalidated)
        #expect(f.host.closes.isEmpty && first.loaded.isEmpty && rejected.loaded.isEmpty)
    }

    @Test func backgroundPrivateTransferPreservesUnrelatedPendingDestinationSelection() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let source = f.privateWindow(), target = f.privateWindow(sharing: source.ephemeralProfile)
        let page = NativeTestPage(profileID: source.ephemeralProfile!.id)
        let id = try #require(f.tabs.adoptNativePage(page, through: f.host, in: source,
            spaceID: source.spaceID!, select: false))
        let request = f.host.creates.count
        let pending = f.tabs.open(url: URL(string: "https://fixture.invalid/pending")!, in: target, placement: .newTab)
        let generation = target.nativeSelectionGeneration, preparing = target.nativeSelectionSession
        #expect(generation != nil && preparing?.itemID == pending)
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: target,
            spaceID: target.spaceID!, select: false) == id)
        #expect(target.nativeSelectionGeneration == generation && target.nativeSelectionSession === preparing)
        #expect(!f.host.creates[request].cancelled && target.privateSessions[id]?.navigation === page)
        _ = f.host.finishCreate(request)
        #expect(target.selectedItemID == pending && target.privateSessions[id]?.navigation === page)
        #expect(f.host.closes.isEmpty && !page.invalidated)
    }

    @Test func privateDetachDoesNotTreatArbitraryMissingItemAsTransfer() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let window = f.privateWindow()
        let ownPage = NativeTestPage(profileID: window.ephemeralProfile!.id)
        let id = try #require(f.tabs.adoptNativePage(ownPage, through: f.host, in: window,
            spaceID: window.spaceID!, select: false))
        _ = try window.privateTree?.close(id)
        f.tabs.detach(window: window)
        #expect(f.host.closes.count == 1 && f.host.closes[0].page === ownPage)
    }

    @Test func privateTransferRetainsLivePageWhenSourceRetiresDuringPublication() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let source = f.privateWindow(), target = f.privateWindow(sharing: source.ephemeralProfile)
        let page = NativeTestPage(profileID: try #require(source.ephemeralProfile?.id))
        let id = try #require(f.tabs.adoptNativePage(page, through: f.host, in: source,
            spaceID: source.spaceID!, select: false))
        let session = try #require(f.tabs.session(for: id)), tree = f.tabs.tree, device = f.tabs.device
        f.registry.onWindowClose = { id in if let window = f.registry.windows[id] { f.tabs.detach(window: window) } }
        var observed = false
        withObservationTracking { _ = source.privateTree } onChange: {
            MainActor.assumeIsolated { guard !observed else { return }; observed = true; f.registry.unregister(source.id) }
        }
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: target,
            spaceID: target.spaceID!, select: false) == id)
        #expect(observed && f.registry.windows[source.id] == nil)
        #expect(target.privateSessions[id] === session && target.privateTree?.item(id) != nil)
        #expect(session.navigation === page && !page.invalidated && page.loaded.isEmpty)
        #expect(f.tabs.tree == tree && f.tabs.device == device && f.host.closes.isEmpty)
    }

    @Test func privateTransferAbortedDestinationRestoresSourceWithoutClosingPage() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let source = f.privateWindow(), target = f.privateWindow(sharing: source.ephemeralProfile)
        let page = NativeTestPage(profileID: try #require(source.ephemeralProfile?.id))
        let id = try #require(f.tabs.adoptNativePage(page, through: f.host, in: source,
            spaceID: source.spaceID!, select: false))
        let session = try #require(f.tabs.session(for: id)), tree = f.tabs.tree, device = f.tabs.device
        f.registry.onWindowClose = { id in if let window = f.registry.windows[id] { f.tabs.detach(window: window) } }
        var observed = false
        withObservationTracking { _ = source.privateTree } onChange: {
            MainActor.assumeIsolated { guard !observed else { return }; observed = true; f.registry.unregister(target.id) }
        }
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: target,
            spaceID: target.spaceID!, select: false) == nil)
        #expect(source.privateSessions[id] === session && source.privateTree?.item(id) != nil)
        #expect(session.navigation === page && !page.invalidated && f.host.closes.isEmpty)
        #expect(f.tabs.tree == tree && f.tabs.device == device)
    }

    @Test func privateOpenerPublicationCannotReclaimNewerTransferredPage() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.nestLinkTabsUnderOpener = false
        let source = f.privateWindow(), target = f.privateWindow(sharing: source.ephemeralProfile)
        let newer = f.privateWindow(sharing: source.ephemeralProfile)
        let parentPage = NativeTestPage(profileID: source.ephemeralProfile!.id)
        let parent = try #require(f.tabs.adoptNativePage(parentPage, through: f.host, in: source,
            spaceID: source.spaceID!, select: false))
        let page = NativeTestPage(profileID: source.ephemeralProfile!.id)
        let id = try #require(f.tabs.adoptNativePage(page, through: f.host, in: source,
            spaceID: source.spaceID!, from: parent, select: false))
        let session = try #require(f.tabs.session(for: id)), space = newer.spaceID!
        #expect(source.privateOpeners[id] == parent)
        var nested: UUID?, observed = false
        withObservationTracking { _ = source.privateOpeners } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }; observed = true
                f.host.nativeOwnerWindow = newer.id
                nested = f.tabs.adoptNativePage(page, through: f.host, in: newer, spaceID: space, select: false)
            }
        }
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: target,
            spaceID: target.spaceID!, select: false) == nil)
        #expect(observed && nested == id && newer.privateSessions[id] === session)
        #expect(f.tabs.isNativePageOwner(session, in: newer) && !f.tabs.isNativePageOwner(session, in: target))
        #expect(source.privateSessions[id] == nil && target.privateSessions[id] == nil)
        #expect(session.navigation === page && !page.invalidated && f.host.closes.isEmpty)
    }

    @Test func privateTransferPublicationCannotOverwriteNewerSameSessionOwner() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let source = f.privateWindow(), target = f.privateWindow(sharing: source.ephemeralProfile)
        let newer = f.privateWindow(sharing: source.ephemeralProfile)
        let page = NativeTestPage(profileID: try #require(source.ephemeralProfile?.id))
        let id = try #require(f.tabs.adoptNativePage(page, through: f.host, in: source,
            spaceID: source.spaceID!, select: false))
        let session = try #require(f.tabs.session(for: id)), newerSpace = try #require(newer.spaceID)
        #expect(f.tabs.adoptNativePage(page, through: f.host, in: target,
            spaceID: target.spaceID!, select: false) == id)
        f.host.nativeSelectedPage = page; f.host.nativeSelectedWindow = target.id
        var nested: UUID?, observed = false
        withObservationTracking { _ = target.selectedItemBySpace } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }; observed = true
                f.host.nativeOwnerWindow = newer.id
                f.host.nativeSelectedWindow = newer.id
                nested = f.tabs.adoptNativePage(page, through: f.host, in: newer, spaceID: newerSpace, select: false)
            }
        }
        #expect(!f.tabs.reflectNativeSelection(id, in: target))
        #expect(nested == id && newer.privateSessions[id] === session && newer.privateTree?.item(id) != nil)
        #expect(target.privateSessions[id] == nil && source.privateSessions[id] == nil)
        #expect(session.navigation === page && !page.invalidated && f.host.closes.isEmpty)
    }

    @Test func nativeTransferReusesSessionAndRepairsOnlySourceSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let page = fixture.host.finishCreate(0)
        let item = try #require(fixture.window.selectedItemID)
        let session = try #require(fixture.tabs.session(for: item))
        let space = try #require(fixture.window.spaceID)
        let otherSpace = try #require(fixture.tabs.createSpace(name: "Other", icon: "house", accentHex: "#123456",
            after: nil, sharingLoginsWith: space))
        let target = BrowserWindowState(); target.spaceID = otherSpace
        fixture.registry.register(target)
        fixture.tabs.attach(window: target, restoringSavedState: false)
        let tree = fixture.tabs.tree, loads = page.loaded.count, selections = fixture.host.selectionCount
        let admitted = fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: target, spaceID: space, select: false)
        #expect(admitted == item && fixture.tabs.session(for: item) === session && session.navigation === page)
        #expect(fixture.window.selectedItemID == nil && target.selectedItemID == nil && target.spaceID == otherSpace)
        #expect(fixture.tabs.tree == tree && page.loaded.count == loads && !page.invalidated)
        #expect(fixture.host.selectionCount == selections && fixture.host.closes.isEmpty && fixture.host.creates.count == 1)
        #expect(fixture.tabs.miniPlayerPages(for: target).count == 1)
        let device = fixture.tabs.device
        #expect(fixture.tabs.adoptNativePage(page, through: fixture.host, in: target, spaceID: space, select: false) == item)
        #expect(fixture.tabs.device == device)
    }

    @Test func sourceSelectionCallbackCannotPublishAnObsoleteTransfer() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let page = fixture.host.finishCreate(0)
        let item = try #require(fixture.window.selectedItemID), space = try #require(fixture.window.spaceID)
        let target = BrowserWindowState(), newer = BrowserWindowState()
        for window in [target, newer] {
            window.spaceID = space; fixture.registry.register(window)
            fixture.tabs.attach(window: window, restoringSavedState: false)
        }
        fixture.host.nativeOwnerWindow = target.id
        var nested: UUID?, observed = false
        withObservationTracking { _ = fixture.window.selectedItemBySpace } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }; observed = true
                fixture.host.nativeOwnerWindow = newer.id
                nested = fixture.tabs.adoptNativePage(page, through: fixture.host,
                    in: newer, spaceID: space, select: false)
            }
        }
        let obsolete = fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: target, spaceID: space, select: false)
        #expect(observed && obsolete == nil && nested == item)
        let session = try #require(fixture.tabs.session(for: item))
        #expect(fixture.tabs.isNativePageOwner(session, in: newer))
        #expect(!fixture.tabs.isNativePageOwner(session, in: target) && session.navigation === page)
        #expect(fixture.host.closes.isEmpty && !page.invalidated)
    }

    @Test func sourceUnregisterDuringTransferDoesNotRecreateItsSavedRecord() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let page = fixture.host.finishCreate(0)
        let item = try #require(fixture.window.selectedItemID), space = try #require(fixture.window.spaceID)
        let target = BrowserWindowState(); target.spaceID = space
        fixture.registry.register(target); fixture.tabs.attach(window: target, restoringSavedState: false)
        fixture.registry.onWindowClose = { id in
            if let source = fixture.registry.windows[id] { fixture.tabs.detach(window: source) }
        }
        var observed = false
        withObservationTracking { _ = fixture.window.selectedItemBySpace } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }; observed = true
                fixture.registry.unregister(fixture.window.id)
            }
        }
        let moved = fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: target, spaceID: space, select: false)
        #expect(observed && moved == item && fixture.registry.windows[fixture.window.id] == nil)
        #expect(!fixture.tabs.device.windows.contains { $0.id == fixture.window.id })
        let session = try #require(fixture.tabs.session(for: item))
        #expect(fixture.tabs.isNativePageOwner(session, in: target) && session.navigation === page)
        #expect(!page.invalidated && fixture.host.closes.isEmpty)
    }

    @Test func pendingNativeCloseRefusesTransferWithoutDeletingItem() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let page = fixture.host.finishCreate(0)
        let item = try #require(fixture.window.selectedItemID), space = try #require(fixture.window.spaceID)
        let target = BrowserWindowState(); target.spaceID = space
        fixture.registry.register(target); fixture.tabs.attach(window: target, restoringSavedState: false)
        fixture.tabs.close(item)
        #expect(fixture.tabs.adoptNativePage(page, through: fixture.host, in: target, spaceID: space, select: false) == nil)
        #expect(fixture.tabs.tree.item(item) != nil && !page.invalidated)
        fixture.host.finishClose(0, admitted: false)
        #expect(fixture.tabs.adoptNativePage(page, through: fixture.host, in: target, spaceID: space, select: false) == item)
    }

    @Test func engineCreatedWindowDoesNotClaimSavedRecordOrInventSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let space = try #require(fixture.window.spaceID)
        let item = try #require(fixture.window.selectedItemID)
        let saved = BrowserWindowState()
        saved.spaceID = space
        saved.selectedItemBySpace = [space: item]
        fixture.tabs.mirror(saved)
        let record = try #require(fixture.tabs.device.windows.first { $0.id == saved.id })
        let native = BrowserWindowState()
        native.spaceID = space
        native.selectedItemBySpace = [space: item]
        fixture.registry.register(native)
        let creates = fixture.host.creates.count
        fixture.tabs.attach(window: native, restoringSavedState: false)
        #expect(native.spaceID == space && native.selectedItemID == nil && native.selectedItemBySpace.isEmpty)
        #expect(fixture.tabs.device.windows.contains(record))
        #expect(!fixture.tabs.device.windows.contains { $0.id == native.id })
        fixture.registry.unregister(native.id) // Failed admission: no saved record is detached/preserved.
        #expect(fixture.tabs.device.windows.contains(record))
        #expect(fixture.host.creates.count == creates && fixture.host.selectionCount == 0)
        let restored = BrowserWindowState()
        fixture.registry.register(restored)
        fixture.tabs.attach(window: restored)
        #expect(restored.spaceID == space && restored.selectedItemID == item)
        #expect(!fixture.tabs.device.windows.contains { $0.id == saved.id })
    }

    @Test func engineCreatedWindowWithoutExplicitSpaceDoesNotBorrowDefaultProfile() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let native = BrowserWindowState()
        fixture.registry.register(native)
        fixture.tabs.attach(window: native, restoringSavedState: false)
        #expect(native.spaceID == nil && native.selectedItemID == nil)
    }

    @Test func adoptingExistingPagePreservesDocumentAndDeduplicatesPublishedAdmission() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let opener = try #require(fixture.window.selectedItemID)
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.tree.dataStoreID(for: space))
        let native = NativeTestPage(profileID: profile)
        let url = URL(string: "https://synthetic.invalid/existing")!
        native.state = PageNavigationState(url: url, title: "Live form", canGoBack: true, canGoForward: false)
        let originalState = native.state
        var publicationSawBoundPage = false
        var repeated: UUID?
        fixture.tabs.onTreeChanged = {
            let page = fixture.tabs.sessions.first { $0.navigation === native }
            publicationSawBoundPage = page != nil
            page?.loadWebViewIfNeeded()
            repeated = fixture.tabs.adoptNativePage(native, through: fixture.host,
                in: fixture.window, spaceID: space, from: opener, select: false)
        }
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, from: opener, select: false))
        fixture.tabs.onTreeChanged = nil
        let session = try #require(fixture.tabs.session(for: adopted))
        #expect(publicationSawBoundPage && repeated == adopted)
        #expect(session.navigation === native && session.profile?.id == profile)
        #expect(session.url == url && session.title == "Live form" && session.canGoBack)
        #expect(fixture.tabs.opener(of: adopted) == opener)
        #expect(fixture.window.selectedItemID == opener)
        #expect(native.loaded.isEmpty && native.stops == 0 && !native.invalidated)
        #expect(native.state == originalState && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
        native.onEvent?(.ownerEnded)
        #expect(session.isUnloaded && fixture.tabs.tree.item(adopted)?.url == url)
        #expect(fixture.host.closes.isEmpty)
    }

    @Test func reentrantSpaceCallbackCannotOverwriteNewerSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let selected = try #require(fixture.window.selectedItemID)
        fixture.host.finishCreate(0)
        let originalSpace = try #require(fixture.window.spaceID)
        let personal = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house", accentHex: "#123456", after: nil))
        let native = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: personal)))
        let delegate = RecordingCertificateDelegate()
        fixture.tabs.sessionDelegate = delegate
        delegate.onSpaceChanged = { _ in
            delegate.onSpaceChanged = nil
            fixture.tabs.select(selected, in: fixture.window)
        }
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: personal, select: true))
        #expect(fixture.window.selectedItemID == selected && fixture.window.spaceID == originalSpace)
        #expect(fixture.tabs.session(for: adopted)?.navigation === native)
        #expect(native.loaded.isEmpty && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func profileObserverReentryCannotReplaceAnAdmittedPageBinding() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.profile(forSpace: space))
        let native = NativeTestPage(profileID: profile.id)
        profile.name = "Stale metadata"
        var nested: UUID?
        var observed = false
        withObservationTracking {
            _ = profile.name
        } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }
                observed = true
                nested = fixture.tabs.adoptNativePage(native, through: fixture.host,
                    in: fixture.window, spaceID: space, select: false)
            }
        }
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        #expect(nested == adopted)
        let session = try #require(fixture.tabs.session(for: adopted))
        native.onEvent?(.ownerEnded)
        #expect(session.isUnloaded && fixture.tabs.tree.item(adopted) != nil)
        #expect(native.loaded.isEmpty && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func snapshotReentryReusesNewerBindingInsteadOfOverwritingCallbacks() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let native = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: space)))
        var nested: UUID?
        native.onReadState = {
            nested = fixture.tabs.adoptNativePage(native, through: fixture.host,
                in: fixture.window, spaceID: space, select: false)
        }
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        #expect(nested == adopted)
        let session = try #require(fixture.tabs.session(for: adopted))
        native.onEvent?(.ownerEnded)
        #expect(session.isUnloaded && fixture.tabs.tree.item(adopted) != nil)
        #expect(native.loaded.isEmpty && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func nativeBackWithoutHistorySelectsTheOpenerAndClosesOnlyAfterAcknowledgment() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let opener = try #require(fixture.window.selectedItemID)
        let source = fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let page = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: space)))
        let id = try #require(fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: fixture.window, spaceID: space, from: opener, select: true))
        let session = try #require(fixture.tabs.selectedSession(in: fixture.window))
        try #require(session.itemID == id && !session.canGoBack && session.canGoBackOrReturn)

        session.goBack()

        #expect(fixture.window.selectedItemID == opener)
        #expect(fixture.tabs.selectedSession(in: fixture.window)?.navigation === source)
        #expect(fixture.tabs.tree.item(id) != nil)
        try #require(fixture.host.closes.count == 1 && fixture.host.closes[0].page === page)
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.tabs.tree.item(id) == nil && page.invalidated)
        #expect(fixture.window.selectedItemID == opener && !source.invalidated)
    }

    @Test func selectedAdoptionBindsExistingResourceAndClosesOnlyAfterActualOutcome() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let delegate = NativeOnlyPageDelegate()
        fixture.tabs.sessionDelegate = delegate
        #expect(fixture.tabs.webKitSessionDelegate == nil)
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let native = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: space)))
        let selectedBefore = fixture.host.selectionCount
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: true))
        #expect(fixture.window.selectedItemID == adopted)
        #expect(fixture.host.selectionCount == selectedBefore + 1)
        #expect(native.loaded.isEmpty && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
        let session = try #require(fixture.tabs.session(for: adopted))
        let url = URL(string: "https://fixture.invalid/native-only")!
        native.onEvent?(.committed(url, sameDocument: false))
        native.onEvent?(.finished(url, title: "Native page", isReload: false))
        #expect(session.url == url && session.title == "Native page" && session.primaryWebView == nil)
        let retired = native.onEvent
        fixture.tabs.close(adopted)
        #expect(fixture.tabs.tree.item(adopted) != nil && fixture.host.closes.count == 1)
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.tabs.tree.item(adopted) == nil && native.invalidated)
        #expect(native.stops == 0 && fixture.host.closes.count == 1)
        #expect(delegate.cleanedZoom.filter { $0 == adopted } == [adopted])
        retired?(.titleChanged("Late native title"))
        #expect(session.title == "Native page")
    }

    @Test func chromiumSelectionKeepsActivationWithoutWebKitExtensionHooks() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let observer = RecordingWebKitTabEvents()
        fixture.tabs.tabEvents = observer
        let space = try #require(fixture.window.spaceID)
        let page = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: space)))
        let id = try #require(fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: fixture.window, spaceID: space, select: true))
        #expect(observer.activated == [id])
        let url = URL(string: "https://fixture.invalid/extension-observer")!
        page.onEvent?(.committed(url, sameDocument: false))
        page.onEvent?(.titleChanged("Native title"))
        fixture.tabs.close(id)
        fixture.host.finishClose(0, admitted: true)
        #expect(observer.opened.isEmpty && observer.changed.isEmpty &&
                observer.granted.isEmpty && observer.closed.isEmpty)
    }

    @Test func adoptionUsesExplicitInactiveProfileWithoutAnotherCreateOrLoad() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let selected = fixture.window.selectedItemID
        fixture.host.finishCreate(0)
        let personal = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house", accentHex: "#123456", after: nil))
        let profile = try #require(fixture.tabs.tree.dataStoreID(for: personal))
        let native = NativeTestPage(profileID: profile)
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: personal, select: false))
        #expect(fixture.tabs.session(for: adopted)?.profile?.id == profile)
        #expect(fixture.tabs.tree.spaceID(of: adopted) == personal && fixture.window.selectedItemID == selected)
        #expect(fixture.host.creates.count == 1 && native.loaded.isEmpty && fixture.host.closes.isEmpty)
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: personal, select: true) == adopted)
        #expect(fixture.window.selectedItemID == adopted && fixture.window.spaceID == personal)
        #expect(fixture.host.creates.count == 1 && native.loaded.isEmpty && fixture.host.closes.isEmpty)
    }

    @Test func refusedForeignStaleAndEndingAdoptionsLeaveNativeResourceUntouched() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.tree.dataStoreID(for: space))
        let native = NativeTestPage(profileID: profile)
        let foreign = NativeTestPage(profileID: UUID())
        let original = fixture.tabs.tree
        let selected = fixture.window.selectedItemID
        #expect(fixture.tabs.adoptNativePage(foreign, through: fixture.host,
            in: fixture.window, spaceID: space, select: true) == nil)
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: BrowserWindowState(), spaceID: space, select: false) == nil)
        fixture.host.admitSelection = false
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: true) == nil)
        fixture.host.admitSelection = true
        fixture.host.admitsAdoption = false
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: false) == nil)
        #expect(fixture.tabs.tree == original && fixture.window.selectedItemID == selected)
        #expect(native.onEvent == nil && native.loaded.isEmpty && native.stops == 0 && !native.invalidated)
        #expect(foreign.loaded.isEmpty && !foreign.invalidated && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func reentrantNewerSelectionPreventsPublishingAnObsoleteAdoption() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let selected = try #require(fixture.window.selectedItemID)
        let originalPage = fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let native = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: space)))
        let original = fixture.tabs.tree
        fixture.host.onSelect = { _, _ in fixture.tabs.select(selected, in: fixture.window) }
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: true) == nil)
        #expect(fixture.tabs.tree == original && fixture.window.selectedItemID == selected)
        #expect(fixture.tabs.sessions.allSatisfy { $0.navigation !== native })
        #expect(native.loaded.isEmpty && !native.invalidated && native.onEvent == nil)
        #expect(originalPage.loaded.count == 1 && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func nativeSelectionReflectionUpdatesBackgroundModelWithoutActivationOrLoading() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        _ = fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.profile(forSpace: space))
        let page = NativeTestPage(profileID: profile.id)
        let id = try #require(fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        let foreground = BrowserWindowState()
        fixture.registry.register(foreground)
        fixture.registry.setActive(foreground)
        fixture.host.nativeSelectedPage = page
        fixture.host.nativeSelectedWindow = fixture.window.id
        let selections = fixture.host.selectionCount, creates = fixture.host.creates.count
        #expect(fixture.tabs.reflectNativeSelection(id, in: fixture.window))
        #expect(fixture.window.selectedItemID == id)
        #expect(fixture.registry.activeWindowId == foreground.id)
        #expect(fixture.host.selectionCount == selections && fixture.host.creates.count == creates)
        #expect(page.loaded.isEmpty && fixture.host.closes.isEmpty)
        #expect(fixture.tabs.device.windows.first { $0.id == fixture.window.id }?.selectedItemBySpace[space] == id)
    }

    @Test func reflectionRefusesUnselectedPageAndReentrantHeaderSupersession() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let original = fixture.host.finishCreate(0)
        let previous = fixture.window.selectedItemID
        let space = try #require(fixture.window.spaceID)
        let page = NativeTestPage(profileID: original.profileID!)
        let id = try #require(fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        let selections = fixture.host.selectionCount
        #expect(!fixture.tabs.reflectNativeSelection(id, in: fixture.window))
        fixture.host.nativeSelectedPage = page
        fixture.host.nativeSelectedWindow = fixture.window.id
        fixture.host.onAcceptNativeSelection = { _, _ in fixture.host.nativeSelectedPage = original }
        #expect(!fixture.tabs.reflectNativeSelection(id, in: fixture.window))
        #expect(fixture.window.selectedItemID == previous && fixture.host.selectionCount == selections)
        #expect(page.loaded.isEmpty && fixture.host.closes.isEmpty)
    }

    @Test func newerNativeReflectionDuringPublicationWinsWithoutFocusOrRollback() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let original = fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let first = NativeTestPage(profileID: original.profileID!), newer = NativeTestPage(profileID: original.profileID!)
        let firstID = try #require(fixture.tabs.adoptNativePage(first, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        let newerID = try #require(fixture.tabs.adoptNativePage(newer, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        fixture.host.nativeSelectedPage = first
        fixture.host.nativeSelectedWindow = fixture.window.id
        let selections = fixture.host.selectionCount
        fixture.tabs.onLeavingTab = { _, window in
            fixture.tabs.onLeavingTab = nil
            fixture.host.nativeSelectedPage = newer
            #expect(fixture.tabs.reflectNativeSelection(newerID, in: window))
        }
        #expect(!fixture.tabs.reflectNativeSelection(firstID, in: fixture.window))
        #expect(fixture.window.selectedItemID == newerID && fixture.host.selectionCount == selections)
        #expect(first.loaded.isEmpty && newer.loaded.isEmpty && fixture.host.closes.isEmpty)
    }

    @Test func ownerEndDuringPendingClosePreservesSavedTabAndCancelsSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let native = fixture.host.finishCreate(0)
        let original = fixture.tabs.tree.item(id)
        let history = fixture.tabs.device.closed
        fixture.tabs.close(id)
        fixture.tabs.select(id, in: fixture.window)
        #expect(fixture.window.nativeSelectionGeneration != nil)
        fixture.host.finishOwnerEnd(0, eventFirst: false)
        #expect(page.isUnloaded && native.invalidated && native.stops == 0)
        #expect(fixture.tabs.tree.item(id) == original)
        #expect(fixture.tabs.device.closed == history)
        #expect(fixture.window.nativeSelectionGeneration == nil)
        #expect(fixture.host.creates.count == 1 && fixture.host.closes.count == 1)
        #expect(fixture.tabs.windowRegistry.windows[fixture.window.id] === fixture.window)
    }

    @Test func ownerEndDuringUnloadDoesNotResumeQueuedReturn() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let native = fixture.host.finishCreate(0)
        page.unload()
        fixture.tabs.select(id, in: fixture.window)
        fixture.host.finishOwnerEnd(0, eventFirst: true)
        #expect(page.isUnloaded && !page.nativeUnloadPending && !page.nativeIsEnding)
        #expect(native.invalidated && native.stops == 0)
        #expect(fixture.tabs.tree.item(id) != nil)
        #expect(fixture.host.creates.count == 1 && fixture.host.closes.count == 1)
    }

    @Test func unsolicitedOwnerEndPreservesMetadataAndIgnoresLateEvents() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let native = fixture.host.finishCreate(0)
        let original = fixture.tabs.tree.item(id)
        let late = native.onEvent
        var modelClosed = false
        page.onClose = { modelClosed = true }
        native.onEvent?(.ownerEnded)
        late?(.closed)
        late?(.started(URL(string: "https://late.invalid")!))
        #expect(page.isUnloaded && !modelClosed)
        #expect(fixture.tabs.tree.item(id) == original)
        #expect(fixture.host.closes.isEmpty && fixture.host.creates.count == 1)
        #expect(native.invalidated && native.stops == 0)
    }

    @Test func ownerEndCancelsPendingCreationWithoutRemovingItem() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        page.nativeOwnerEnded()
        #expect(fixture.host.creates[0].cancelled)
        #expect(fixture.window.nativeSelectionGeneration == nil)
        let late = fixture.host.finishCreate(0)
        #expect(late.loaded.isEmpty && page.isUnloaded)
        fixture.host.finishOwnerEnd(0, eventFirst: false)
        #expect(late.invalidated && fixture.tabs.tree.item(id) != nil)
        #expect(fixture.host.creates.count == 1 && fixture.host.closes.count == 1)
    }

    @Test func metadataEditsDoNotVisitNativeOwnership() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        for index in 0..<32 {
            _ = try #require(fixture.tabs.open(url: URL(string: "about:blank#\(index)")!,
                in: fixture.window, placement: .newTab, parent: .tabs(spaceID: space)))
            fixture.host.finishCreate(index + 1)
        }
        let pages = fixture.tabs.sessions
        #expect(pages.count >= 33)
        let visits = fixture.tabs.nativeOwnershipVisits
        for page in pages {
            _ = fixture.tabs.perform(.main, "metadata", undoable: false) {
                var change = try $0.setURL(page.itemID, URL(string: "about:blank#updated")!)
                change.merge(try $0.setPageTitle(page.itemID, "Updated"))
                return change
            }
        }
        #expect(fixture.tabs.nativeOwnershipVisits == visits)
        #expect(pages.allSatisfy { fixture.tabs.tree.item($0.itemID)?.pageTitle == "Updated" })
        let rejected = fixture.tabs.perform(.main, "ownership change") {
            try $0.setProfile(space, to: UUID(), name: nil, kept: [])
        }
        #expect(rejected == nil)
        #expect(fixture.tabs.nativeOwnershipVisits > visits,
            "The same counter must observe actual structural admission work")
    }

    @Test func bulkUnloadRetainsChromiumPagesWithUnknownActivity() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let visible = try #require(f.window.selectedItemID)
        f.host.finishCreate(0)
        let space = try #require(f.window.spaceID)
        func open(_ fragment: String, parent: Parent? = nil) throws -> (UUID, NativeTestPage) {
            let index = f.host.creates.count
            let id = try #require(f.tabs.open(url: URL(string: "about:blank#" + fragment)!, in: f.window,
                                              placement: .newTab, parent: parent ?? .tabs(spaceID: space)))
            return (id, f.host.finishCreate(index))
        }
        let (plain, plainPage) = try open("plain")
        let (refusing, refusingPage) = try open("refusing")
        let (audible, audiblePage) = try open("audible")
        let (videoPiP, videoPiPPage) = try open("video-pip")
        let (documentPiP, documentPiPPage) = try open("document-pip")
        let (pinned, pinnedPage) = try open("pinned", parent: .pinned(spaceID: space))
        f.tabs.select(visible, in: f.window)
        audiblePage.state.isAudible = true
        audiblePage.onStateChanged?(audiblePage.state)
        videoPiPPage.state.hasVideoPictureInPicture = true
        videoPiPPage.state.hasDocumentPictureInPicture = false
        videoPiPPage.onStateChanged?(videoPiPPage.state)
        documentPiPPage.state.hasVideoPictureInPicture = false
        documentPiPPage.state.hasDocumentPictureInPicture = true
        documentPiPPage.onStateChanged?(documentPiPPage.state)

        let hidden = try #require(f.tabs.session(for: plain))
        #expect(f.tabs.inactiveUnloadProtectionReason(for: hidden) == .unknownNativeActivity, "Automatic unloading has no capture signal")

        let result = f.tabs.unloadAllHidden()
        #expect(result.unloaded == 0 && result.kept == 7)
        #expect(result.retained == [.visible: 1, .unknownNativeActivity: 2, .audio: 1, .pictureInPicture: 2, .pinned: 1])
        #expect(f.host.closes.isEmpty && !hidden.isUnloaded)

        // An explicit single-tab action still requests that tab's close.
        f.tabs.unload(plain)
        f.tabs.unload(refusing)
        #expect(Set(f.host.closes.map { ObjectIdentifier($0.page) }) == [ObjectIdentifier(plainPage), ObjectIdentifier(refusingPage)])
        f.host.finishClose(try #require(f.host.closes.firstIndex { $0.page === plainPage }), admitted: true)
        f.host.finishClose(try #require(f.host.closes.firstIndex { $0.page === refusingPage }), admitted: false)
        #expect(hidden.isUnloaded, "A hidden page unloads")
        #expect(f.tabs.session(for: refusing)?.isUnloaded == false, "A page that refuses stays")
        for id in [visible, audible, videoPiP, documentPiP, pinned] {
            #expect(f.tabs.session(for: id)?.isUnloaded == false)
        }
        #expect(f.tabs.session(for: videoPiP)?.navigation === videoPiPPage && f.tabs.session(for: pinned)?.navigation === pinnedPage)
        #expect(f.window.selectedItemID == visible)
    }

    @Test func selectionCoalescesCreationAndUsesActualProfileIdentity() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        page.loadWebViewIfNeeded()
        page.loadWebViewIfNeeded()
        fixture.tabs.select(id, in: fixture.window)
        #expect(fixture.host.creates.count == 1)
        let target = URL(string: "https://synthetic.invalid/latest")!
        page.load(target)
        let navigation = fixture.host.finishCreate(0)
        #expect(navigation.loaded == [target])
        #expect(navigation.profileID == page.profile?.id)
        #expect(page.primaryWebView == nil)
        fixture.tabs.select(id, in: fixture.window)
        #expect(fixture.host.creates.count == 1 && navigation.loaded == [target])
        let space = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: nil))
        let other = try #require(fixture.tabs.open(url: URL(string: "about:blank#personal")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: space)))
        #expect(fixture.window.selectedItemID == id, "No model admission before native admission")
        let second = fixture.host.finishCreate(1)
        #expect(fixture.window.selectedItemID == other)
        #expect(second.profileID == fixture.tabs.profile(forSpace: space)?.id)
        #expect(second.profileID != navigation.profileID)
        #expect(!navigation.invalidated, "Inactive profile retains its live page")
    }

    @Test func deleteSpaceClosesLivePagesFirstAndARefusedCloseKeepsTheSpace() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = f.host.finishCreate(0)
        let work = try #require(f.window.spaceID), item = try #require(f.window.selectedItemID)
        let sibling = try #require(f.tabs.createSpace(name: "Sibling", icon: "", accentHex: "#123456", after: work, sharingLoginsWith: work))
        let other = BrowserWindowState(); other.spaceID = work
        f.registry.register(other); f.tabs.attach(window: other, restoringSavedState: false)
        var notices: [String] = []
        f.tabs.onSpaceDeletionNotice = { notices.append($0) }
        var wiped = false
        f.tabs.onDeleteProfile = { _, _, _, _ in wiped = true }

        f.tabs.deleteSpace(work)
        #expect(f.host.closes.count == 1 && f.host.closes.first?.page === page, "Live pages close through the host first")
        #expect(f.tabs.space(work) != nil && f.window.spaceID == work, "The space waits for the close")
        f.host.finishClose(0, admitted: false)
        #expect(f.tabs.space(work) != nil && f.window.spaceID == work && f.tabs.tree.item(item) != nil, "A refused close keeps the space")
        #expect(f.tabs.session(for: item)?.navigation === page)

        f.tabs.deleteSpace(work)
        #expect(f.host.closes.count == 2)
        f.host.finishClose(1, admitted: true)
        #expect(f.tabs.space(work) == nil && f.tabs.tree.item(item) == nil)
        #expect(f.window.spaceID == sibling && other.spaceID == sibling, "Windows showing it move on")
        #expect(f.tabs.device.closed.contains { $0.items.contains { $0.id == item } }, "Its tabs go to the reopen history")
        #expect(!wiped && notices.isEmpty, "The sibling keeps the profile")
    }

    @Test func deleteSpaceMovesASharedFavoriteWithoutClosingIt() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.host.finishCreate(0)
        let work = try #require(f.window.spaceID)
        let sibling = try #require(f.tabs.createSpace(name: "Sibling", icon: "", accentHex: "#123456", after: work, sharingLoginsWith: work))
        let next = f.host.creates.count
        let favorite = try #require(f.tabs.open(url: URL(string: "about:blank#favorite")!, in: f.window, placement: .newTab, parent: .favorites(spaceID: work)))
        let page = f.host.finishCreate(next)
        f.tabs.deleteSpace(work)
        #expect(!f.host.closes.contains { $0.page === page }, "A favorite the sibling shows stays live")
        for index in f.host.closes.indices { f.host.finishClose(index, admitted: true) }
        #expect(f.tabs.space(work) == nil)
        #expect(f.tabs.tree.item(favorite)?.parent == .favorites(spaceID: sibling))
        #expect(f.tabs.session(for: favorite)?.navigation === page)
    }

    @Test func deletingAProfilesLastSpaceClosesItsPagesAndKeepsTheProfile() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = f.host.finishCreate(0)
        let work = try #require(f.window.spaceID), item = try #require(f.window.selectedItemID)
        let store = try #require(f.tabs.tree.dataStoreID(for: work))
        let personal = try #require(f.tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: work))
        #expect(f.tabs.tree.dataStoreID(for: personal) != store)
        var notices: [String] = []
        f.tabs.onSpaceDeletionNotice = { notices.append($0) }
        var wiped = false
        f.tabs.onDeleteProfile = { _, _, _, _ in wiped = true }

        f.tabs.deleteSpace(work)
        #expect(f.host.closes.count == 1 && f.host.closes.first?.page === page && f.tabs.space(work) != nil, "Its pages close first")
        f.host.finishClose(0, admitted: true)
        #expect(f.tabs.space(work) == nil && f.tabs.tree.item(item) == nil && f.window.spaceID == personal)
        #expect(f.tabs.device.keptProfiles?.contains { $0.id == store } == true, "The profile stays in Settings > Profiles")
        #expect(f.tabs.profiles.contains { $0.id == store })
        #expect(!wiped && notices.isEmpty && f.tabs.device.pendingProfileDeletion == nil)
    }

    @Test func theOnlySpaceClosesNothing() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.host.finishCreate(0)
        let work = try #require(f.window.spaceID)
        let agent = try #require(f.tabs.ensureAgentSpace(loginsFrom: f.window))
        #expect(f.tabs.isLastRegularSpace(work) && !f.tabs.isLastRegularSpace(agent), "The Agent space never counts as a space left")
        var notices: [String] = []
        f.tabs.onSpaceDeletionNotice = { notices.append($0) }
        f.tabs.deleteSpace(work)
        #expect(f.host.closes.isEmpty && f.tabs.space(work) != nil)
        #expect(notices.count == 1, "It cannot go, and the person is told")
        let personal = try #require(f.tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: work))
        #expect(!f.tabs.isLastRegularSpace(work) && !f.tabs.isLastRegularSpace(personal))
    }

    @Test func deleteSpaceBlockedByAProfileChangeSaysWhy() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let page = f.host.finishCreate(0)
        let space = try #require(f.window.spaceID)
        let destination = try #require(f.tabs.createSpace(name: "Destination", icon: "", accentHex: "#123456", after: space))
        let target = try #require(f.tabs.tree.dataStoreID(for: destination))
        _ = try #require(f.tabs.createSpace(name: "Sibling", icon: "", accentHex: "#654321", after: space, sharingLoginsWith: space))
        f.tabs.onDeleteProfile = { _, _, _, _ in }
        f.tabs.setProfile(space, to: target)
        #expect(f.tabs.device.pendingProfileDeletion?.change?.spaceIDs.contains(space) == true)
        var notices: [String] = []
        f.tabs.onSpaceDeletionNotice = { notices.append($0) }
        let closes = f.host.closes.count
        f.tabs.deleteSpace(space)
        #expect(f.tabs.space(space) != nil && notices.count == 1 && f.host.closes.count == closes)
        _ = page
    }

    @Test func enteringEmptySpaceShowsItThenItsFirstTabSelects() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let native = fixture.host.finishCreate(0)
        let fresh = try #require(fixture.tabs.createSpace(name: "Fresh", icon: "house",
            accentHex: "#123456", after: nil))
        let creates = fixture.host.creates.count
        fixture.tabs.setSpace(fresh, in: fixture.window)
        #expect(fixture.window.spaceID == fresh && fixture.window.selectedItemID == nil)
        #expect(fixture.window.showsNativeEmptySpace)
        #expect(fixture.host.creates.count == creates, "An empty space opens no page of its own")
        #expect(!native.invalidated && fixture.tabs.session(for: id)?.navigation === native,
                "The other space keeps its live page")
        let opened = try #require(fixture.tabs.open(url: URL(string: "about:blank#fresh")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: fresh)))
        let page = fixture.host.finishCreate(fixture.host.creates.count - 1)
        #expect(fixture.window.selectedItemID == opened && !fixture.window.showsNativeEmptySpace)
        #expect(page.profileID == fixture.tabs.profile(forSpace: fresh)?.id)
    }

    @Test func closingLastTabLeavesItsSpaceEmptyAndIgnoresChromiumFallback() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let closing = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        fixture.host.finishCreate(0)
        let personal = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: nil))
        _ = try #require(fixture.tabs.open(url: URL(string: "about:blank#personal")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: personal)))
        fixture.host.finishCreate(fixture.host.creates.count - 1)
        fixture.tabs.select(closing, in: fixture.window)
        #expect(!fixture.tabs.nativeSelectionIsSettling(in: fixture.window))
        fixture.tabs.close(closing)
        #expect(fixture.tabs.nativeSelectionIsSettling(in: fixture.window), "Its page is closing")
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.window.spaceID == work && fixture.window.selectedItemID == nil)
        #expect(fixture.window.showsNativeEmptySpace)
        #expect(fixture.tabs.nativeSelectionIsSettling(in: fixture.window), "Nook shows the empty space")
    }

    @Test func failedSuccessorCoversThePageRatherThanShowAnotherProfile() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let closing = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        fixture.host.finishCreate(0)
        _ = try #require(fixture.tabs.open(url: URL(string: "about:blank#cold")!,
            in: fixture.window, placement: .background, parent: .tabs(spaceID: work)))
        let personal = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: nil))
        _ = try #require(fixture.tabs.open(url: URL(string: "about:blank#personal")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: personal)))
        fixture.host.finishCreate(fixture.host.creates.count - 1)
        fixture.tabs.select(closing, in: fixture.window)
        fixture.tabs.close(closing)
        fixture.host.finishClose(0, admitted: true)
        fixture.host.failCreate(fixture.host.creates.count - 1)
        #expect(fixture.window.spaceID == work && fixture.window.selectedItemID == nil)
        #expect(fixture.window.showsNativeEmptySpace)
    }

    @Test func failedSelectionKeepsTheSelectedPageUncovered() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        fixture.host.finishCreate(0)
        let cold = try #require(fixture.tabs.open(url: URL(string: "about:blank#cold")!,
            in: fixture.window, placement: .background, parent: .tabs(spaceID: work)))
        fixture.tabs.select(cold, in: fixture.window)
        fixture.host.failCreate(fixture.host.creates.count - 1)
        #expect(fixture.window.selectedItemID == id && !fixture.window.showsNativeEmptySpace)
    }

    @Test func closingShownPageNamesItsLiveSuccessorAndStaysShown() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let first = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        fixture.host.finishCreate(0)
        let second = try #require(fixture.tabs.open(url: URL(string: "about:blank#second")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: work)))
        let successor = fixture.host.finishCreate(fixture.host.creates.count - 1)
        fixture.tabs.select(first, in: fixture.window)
        #expect(fixture.window.selectedItemID == first)
        fixture.tabs.close(first)
        #expect(fixture.host.closes.last?.successor === successor, "The engine shows Nook's pick, not its neighbour")
        #expect(fixture.window.selectedItemID == first, "Shown until it actually closes, as while Leave site? asks")
        #expect(fixture.tabs.isCloseSuccessor(second, in: fixture.window))
        fixture.host.finishClose(fixture.host.closes.count - 1, admitted: true)
        #expect(fixture.window.selectedItemID == second && fixture.tabs.item(first) == nil)
        #expect(fixture.window.nativeCloseSuccessor == nil)
    }

    @Test func refusedCloseKeepsThePageAndForgetsItsSuccessor() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let first = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        fixture.host.finishCreate(0)
        let second = try #require(fixture.tabs.open(url: URL(string: "about:blank#second")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: work)))
        let successor = fixture.host.finishCreate(fixture.host.creates.count - 1)
        fixture.tabs.select(first, in: fixture.window)
        fixture.tabs.close(first)
        fixture.host.finishClose(fixture.host.closes.count - 1, admitted: false)
        #expect(fixture.window.selectedItemID == first && fixture.tabs.item(first) != nil)
        #expect(fixture.window.nativeCloseSuccessor == nil && !fixture.tabs.isCloseSuccessor(second, in: fixture.window))
        fixture.tabs.close(first)
        #expect(fixture.host.closes.last?.successor === successor)
    }

    @Test func pageAnotherWindowShowsIsAPlaceholderUntilThatWindowLetsGo() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let space = try #require(f.window.spaceID)
        f.host.finishCreate(0)
        _ = try #require(f.tabs.open(url: URL(string: "about:blank#second")!,
            in: f.window, placement: .background, parent: .tabs(spaceID: space)))
        let order = f.tabs.displayOrder(in: f.window)
        let first = try #require(order.first), second = try #require(order.last)
        if f.tabs.session(for: first)?.navigation == nil {
            f.tabs.select(first, in: f.window)
            f.host.finishCreate(f.host.creates.count - 1)
        }
        f.tabs.select(first, in: f.window)
        #expect(f.window.selectedItemID == first)
        let other = BrowserWindowState()
        f.registry.register(other); f.tabs.attach(window: other)
        #expect(other.selectedItemID == first, "New Window selects the first tab, as in WebKit mode")
        #expect(f.tabs.showsPageElsewhere(in: other) && !f.tabs.showsPageElsewhere(in: f.window))
        #expect(f.tabs.nativeSelectionIsSettling(in: other), "Chromium's page there is no one's choice")
        let selections = f.host.selectionCount
        f.tabs.showSelectedPageHere(in: other)
        #expect(f.host.selectionCount == selections, "The page stays in the window that shows it")

        f.tabs.takeControl(first, in: other)
        #expect(f.tabs.pageOwnerWindow(of: first) === other)
        #expect(f.tabs.showsPageElsewhere(in: f.window) && !f.tabs.showsPageElsewhere(in: other))
        f.tabs.takeControl(first, in: f.window)
        #expect(f.tabs.showsPageElsewhere(in: other) && !f.tabs.showsPageElsewhere(in: f.window))

        // The window holding the page moves on, so the other one shows the page itself.
        f.tabs.select(second, in: f.window)
        if f.tabs.session(for: second)?.navigation == nil { f.host.finishCreate(f.host.creates.count - 1) }
        #expect(f.window.selectedItemID == second && !f.tabs.showsPageElsewhere(in: other))
        let before = f.host.selectionCount
        f.tabs.showSelectedPageHere(in: other)
        #expect(f.host.selectionCount == before + 1 && f.tabs.pageOwnerWindow(of: first) === other)
    }

    @Test func placeholderUpdatesWhenTheHoldingWindowCloses() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.host.finishCreate(0)
        let other = BrowserWindowState()
        f.registry.register(other); f.tabs.attach(window: other)
        #expect(f.tabs.showsPageElsewhere(in: other))
        var changed = false
        _ = withObservationTracking { f.tabs.showsPageElsewhere(in: other) } onChange: { changed = true }
        f.registry.unregister(f.window.id)
        #expect(changed, "The window showing the placeholder learns that the holding window closed")
        #expect(!f.tabs.showsPageElsewhere(in: other))
    }

    @Test func coldSuccessorIsNotNamed() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let first = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        fixture.host.finishCreate(0)
        _ = try #require(fixture.tabs.open(url: URL(string: "about:blank#cold")!,
            in: fixture.window, placement: .background, parent: .tabs(spaceID: work)))
        fixture.tabs.close(first)
        let close = try #require(fixture.host.closes.last)
        #expect(close.successor == nil && fixture.window.nativeCloseSuccessor == nil)
    }

    @Test func refusedCloseEndsSettlingOnTheSamePage() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        fixture.host.finishCreate(0)
        fixture.tabs.close(id)
        #expect(fixture.tabs.nativeSelectionIsSettling(in: fixture.window))
        fixture.host.finishClose(0, admitted: false)
        #expect(fixture.window.selectedItemID == id)
        #expect(!fixture.tabs.nativeSelectionIsSettling(in: fixture.window))
        #expect(!fixture.window.showsNativeEmptySpace)
    }

    @Test func closingSelectedTabStaysInItsSpaceWhenAnotherSpaceRetainsAPage() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let closing = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        fixture.host.finishCreate(0)
        let cold = try #require(fixture.tabs.open(url: URL(string: "about:blank#cold")!,
            in: fixture.window, placement: .background, parent: .tabs(spaceID: work)))
        let personal = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: nil))
        let retained = try #require(fixture.tabs.open(url: URL(string: "about:blank#personal")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: personal)))
        fixture.host.finishCreate(fixture.host.creates.count - 1)
        #expect(fixture.window.selectedItemID == retained && fixture.window.spaceID == personal)
        fixture.tabs.select(closing, in: fixture.window)
        #expect(fixture.window.selectedItemID == closing && fixture.window.spaceID == work)
        fixture.tabs.close(closing)
        #expect(fixture.tabs.nativeSelectionIsSettling(in: fixture.window))
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.tabs.nativeSelectionIsSettling(in: fixture.window), "The next tab is still being created")
        fixture.host.finishCreate(fixture.host.creates.count - 1)
        #expect(!fixture.tabs.nativeSelectionIsSettling(in: fixture.window))
        #expect(fixture.window.spaceID == work)
        #expect(fixture.window.selectedItemID == cold)
    }

    @Test func moveToAnotherProfileClosesPageThenMovesAndReloadsThere() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        let page = try #require(fixture.tabs.session(for: id))
        let native = fixture.host.finishCreate(0)
        let target = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: nil))
        fixture.tabs.move(id, to: .tabs(spaceID: target), after: nil)
        #expect(fixture.tabs.tree.spaceID(of: id) == work && !native.invalidated,
                "The item waits until the old profile's page has closed")
        #expect(fixture.host.closes.count == 1)
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.tabs.tree.spaceID(of: id) == target)
        #expect(native.invalidated && page.isUnloaded)
        let created = fixture.host.creates.count
        fixture.tabs.select(id, in: fixture.window)
        let reloaded = fixture.host.finishCreate(created)
        #expect(reloaded.profileID == fixture.tabs.profile(forSpace: target)?.id)
        #expect(reloaded.profileID != native.profileID)
    }

    @Test func refusedCloseKeepsTabAndPageInItsProfile() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        let page = try #require(fixture.tabs.session(for: id))
        let native = fixture.host.finishCreate(0)
        let target = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: nil))
        fixture.tabs.move(id, to: .tabs(spaceID: target), after: nil)
        fixture.host.finishClose(0, admitted: false)
        #expect(fixture.tabs.tree.spaceID(of: id) == work)
        #expect(page.navigation === native && !native.invalidated)
        #expect(fixture.window.selectedItemID == id)
    }

    @Test func moveWithinOneProfileKeepsLivePage() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        let native = fixture.host.finishCreate(0)
        let profile = try #require(fixture.tabs.tree.dataStoreID(for: work))
        let target = try #require(fixture.tabs.createSpace(name: "Second", icon: "house",
            accentHex: "#123456", after: nil))
        #expect(fixture.tabs.perform(.main, "shareProfile", undoable: false) { try $0.setProfile(target, to: profile) } != nil)
        fixture.tabs.move(id, to: .tabs(spaceID: target), after: nil)
        #expect(fixture.tabs.tree.spaceID(of: id) == target)
        #expect(fixture.host.closes.isEmpty && !native.invalidated)
    }

    @Test func folderMovedToAnotherProfileReleasesItsLoadedTabs() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let work = try #require(fixture.window.spaceID)
        let native = fixture.host.finishCreate(0)
        let folder = try #require(fixture.tabs.createFolder(title: "Moved", in: .tabs(spaceID: work), after: nil))
        fixture.tabs.move(id, to: .folder(itemID: folder), after: nil)
        let target = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: nil))
        fixture.tabs.move(folder, to: .tabs(spaceID: target), after: nil)
        #expect(fixture.tabs.tree.spaceID(of: folder) == work && fixture.host.closes.count == 1)
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.tabs.tree.spaceID(of: folder) == target && fixture.tabs.tree.spaceID(of: id) == target)
        #expect(native.invalidated)
    }

    @Test func closeOfPendingItemReleasesLateCreateWithoutRevival() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        fixture.tabs.close(id)
        #expect(fixture.host.creates[0].cancelled)
        #expect(fixture.tabs.tree.item(id) == nil)
        let late = fixture.host.finishCreate(0)
        #expect(late.loaded.isEmpty)
        #expect(fixture.host.closes.count == 1)
        fixture.host.finishClose(0, admitted: true)
        #expect(late.invalidated)
        #expect(fixture.tabs.session(for: id) == nil && fixture.tabs.tree.item(id) == nil)
    }

    @Test func cancellationKeepsPageAndCloseCommitsMetadataOnlyOnce() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let navigation = fixture.host.finishCreate(0)
        let closedBefore = fixture.tabs.device.closed.count
        fixture.tabs.close(id)
        #expect(fixture.tabs.tree.item(id) != nil && page.navigation === navigation)
        fixture.host.finishClose(0, admitted: false)
        #expect(fixture.tabs.tree.item(id) != nil && fixture.tabs.session(for: id) === page)
        #expect(!navigation.invalidated && !page.isUnloaded)
        fixture.tabs.close(id)
        fixture.host.finishClose(1, admitted: true)
        #expect(fixture.tabs.tree.item(id) == nil)
        #expect(fixture.tabs.device.closed.count == closedBefore + 1)
        #expect(navigation.invalidated && navigation.stops == 0)
        #expect(fixture.host.closes.count == 2, "CLOSED must not recursively dispatch close")
    }

    @Test func unloadKeepsItemAndReturnDuringReleaseRestoresWithoutSecondClick() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let navigation = fixture.host.finishCreate(0)
        let original = fixture.tabs.tree.item(id)
        let closedBefore = fixture.tabs.device.closed.count
        page.unload()
        page.unload()
        #expect(fixture.host.closes.count == 1)
        fixture.tabs.select(id, in: fixture.window)
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.tabs.tree.item(id) == original)
        #expect(fixture.tabs.device.closed.count == closedBefore)
        #expect(navigation.invalidated)
        #expect(fixture.host.creates.count == 2, "Queued return resumes after actual release")
        let replacement = fixture.host.finishCreate(1)
        #expect(fixture.window.selectedItemID == id && !page.isUnloaded)
        #expect(replacement.loaded.count == 1)
    }

    @Test func refusedSelectionAndFailedPreparationKeepPreviousItemAndSpace() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let initial = try #require(fixture.window.selectedItemID)
        _ = fixture.host.finishCreate(0)
        let previousSpace = fixture.window.spaceID
        let space = try #require(fixture.tabs.createSpace(name: "Other", icon: "house",
            accentHex: "#123456", after: nil))
        let other = try #require(fixture.tabs.open(url: URL(string: "about:blank#other")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: space)))
        fixture.host.admitSelection = false
        _ = fixture.host.finishCreate(1)
        #expect(fixture.window.selectedItemID == initial && fixture.window.spaceID == previousSpace)
        #expect(fixture.tabs.tree.item(other) != nil)
        fixture.host.admitSelection = true
        fixture.tabs.select(other, in: fixture.window)
        #expect(fixture.window.selectedItemID == other && fixture.window.spaceID == space)
        let third = try #require(fixture.tabs.open(url: URL(string: "about:blank#fails")!,
            in: fixture.window, placement: .newTab))
        fixture.host.failCreate(2)
        #expect(fixture.window.selectedItemID == other && fixture.tabs.tree.item(third) != nil)
    }

    @Test func profileChangeAndWindowRemovalCancelPendingCreation() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let space = try #require(fixture.window.spaceID)
        // Actual tree-edit path models an incoming sync edit; the user-facing
        // native reassignment action remains intentionally unavailable.
        _ = fixture.tabs.perform(.main, "incoming profile change") {
            try $0.setProfile(space, to: UUID(), name: nil, kept: [])
        }
        #expect(fixture.host.creates[0].cancelled)
        #expect(fixture.tabs.session(for: id)?.loadingState == .idle)
        let late = fixture.host.finishCreate(0)
        #expect(late.loaded.isEmpty && fixture.tabs.session(for: id)?.isUnloaded == true)
        fixture.host.finishClose(0, admitted: true)
        fixture.tabs.select(id, in: fixture.window)
        fixture.registry.unregister(fixture.window.id)
        #expect(fixture.host.creates[1].cancelled)
        let afterWindow = fixture.host.finishCreate(1)
        #expect(afterWindow.loaded.isEmpty)
        fixture.host.finishClose(1, admitted: true)
        #expect(afterWindow.invalidated)
    }

    @Test func destructiveSpaceAndUndoPathsDoNotBypassNativeAdmission() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let space = try #require(fixture.window.spaceID)
        let navigation = fixture.host.finishCreate(0)
        let shared = try #require(fixture.tabs.createSpace(name: "Shared", icon: "folder",
            accentHex: "#123456", after: space, sharingLoginsWith: space))
        fixture.tabs.deleteSpace(space)
        #expect(fixture.tabs.tree.space(space) != nil && fixture.tabs.tree.item(id) != nil)
        #expect(fixture.window.selectedItemID == id && !navigation.invalidated)
        #expect(fixture.host.closes.count == 1, "Deleting asks the page to close before any model change")
        fixture.host.finishClose(0, admitted: false)
        var proposed = fixture.tabs.tree
        let deletion = try proposed.close(id, promotingChildren: true).change
        fixture.tabs.apply(deletion)
        #expect(fixture.tabs.tree.item(id) != nil && fixture.window.selectedItemID == id)
        _ = fixture.tabs.perform(.main, "external destructive replacement") {
            try $0.close(id, promotingChildren: true).change
        }
        #expect(fixture.tabs.tree.item(id) != nil)
        fixture.tabs.deleteSpace(shared)
        #expect(fixture.tabs.tree.space(shared) == nil)
        #expect(fixture.host.closes.count == 1, "A space with no live page has nothing to close")
    }

    @Test func newerSelectionCancelsOlderPendingPages() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        _ = fixture.host.finishCreate(0)
        let oldSelection = fixture.window.selectedItemID
        let second = try #require(fixture.tabs.open(url: URL(string: "about:blank#second")!,
            in: fixture.window, placement: .newTab))
        let third = try #require(fixture.tabs.open(url: URL(string: "about:blank#third")!,
            in: fixture.window, placement: .newTab))
        #expect(fixture.host.creates[1].cancelled)
        #expect(fixture.window.selectedItemID == oldSelection)
        _ = fixture.host.finishCreate(2)
        #expect(fixture.window.selectedItemID == third)
        let obsolete = fixture.host.finishCreate(1)
        #expect(obsolete.loaded.isEmpty && fixture.window.selectedItemID != second)
        fixture.host.finishClose(0, admitted: true)
        #expect(obsolete.invalidated)
    }

    @Test func reentrantRefusedSelectionCannotEraseNewerIntent() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        _ = fixture.host.finishCreate(0)
        let initial = fixture.window.selectedItemID
        _ = fixture.tabs.open(url: URL(string: "about:blank#second")!,
            in: fixture.window, placement: .newTab)
        let third = try #require(fixture.tabs.open(url: URL(string: "about:blank#third")!,
            in: fixture.window, placement: .background))
        fixture.host.admitSelection = false
        fixture.host.onSelect = { _, _ in
            fixture.tabs.select(third, in: fixture.window)
            fixture.host.admitSelection = true
        }
        _ = fixture.host.finishCreate(1)
        #expect(fixture.window.nativeSelectionGeneration != nil)
        #expect(fixture.window.selectedItemID == initial)
        _ = fixture.host.finishCreate(2)
        #expect(fixture.window.selectedItemID == third)
    }

    @Test func cancellationReentryPreservesNewestSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let initial = try #require(fixture.window.selectedItemID)
        _ = fixture.host.finishCreate(0)
        _ = fixture.tabs.open(url: URL(string: "about:blank#pending")!,
            in: fixture.window, placement: .newTab)
        let newest = try #require(fixture.tabs.open(url: URL(string: "about:blank#newest")!,
            in: fixture.window, placement: .background))
        fixture.host.onCancel = {
            fixture.tabs.select(newest, in: fixture.window)
        }
        fixture.tabs.select(initial, in: fixture.window)
        #expect(fixture.window.nativeSelectionGeneration != nil)
        _ = fixture.host.finishCreate(2)
        #expect(fixture.window.selectedItemID == newest)
        let late = fixture.host.finishCreate(1)
        #expect(late.loaded.isEmpty)
        fixture.host.finishClose(0, admitted: true)
    }

    @Test func refusalCompletionCanStartNewReleaseWithoutLosingGuard() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        _ = fixture.host.finishCreate(0)
        var secondAdmitted = false
        page.requestNativeRelease { admitted in
            if admitted == .cancelled {
                page.requestNativeRelease { secondAdmitted = $0 == .closed }
            }
        }
        fixture.host.finishClose(0, admitted: false)
        #expect(page.nativeIsEnding && page.nativeRelease != nil)
        #expect(fixture.host.closes.count == 2)
        fixture.host.finishClose(1, admitted: true)
        #expect(secondAdmitted && page.isUnloaded)
        #expect(fixture.tabs.tree.item(id) != nil)
    }

    @Test func synchronousCreateCompletionDoesNotCancelAcceptedPage() throws {
        let fixture = try NativeModelFixture(synchronous: true)
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        #expect(fixture.host.creates.count == 1)
        #expect(!fixture.host.creates[0].cancelled)
        #expect(fixture.tabs.session(for: id)?.isUnloaded == false)
        #expect(fixture.host.closes.isEmpty)
    }
}

@MainActor
@Suite(.serialized)
struct NativeVaultFormTests {
    private func agentCallbacks() async { for _ in 0..<40 { await Task.yield() } }
    @Test func vaultLockDuringLookupUpdatesStatusImmediately() async throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let transport = SyntheticVaultRequests()
        let vault = VaultService(settings: fixture.tabs.settings, client: transport, pawlEnabledAtLaunch: true)
        #expect(await vault.refresh() == .connected)
        await transport.availability("locked")
        await #expect(throws: VaultClientError.server(.locked, "synthetic")) {
            try await vault.send(VaultLogins(origin: "https://vault.synthetic.invalid", profile: nil))
        }
        #expect(vault.status == .locked)
        #expect(!vault.isConnected)
    }

    @Test(arguments: [false, true])
    func providerPreferenceAppliesAtNextLaunch(pawlAtLaunch: Bool) async throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let settings = fixture.tabs.settings
        settings.pawlVaultEnabled = pawlAtLaunch
        let transport = SyntheticVaultRequests()
        let service = VaultService(settings: settings, client: transport,
                                   pawlEnabledAtLaunch: NookSettingsService.savedPawlVaultSelection(in: fixture.defaults))
        settings.pawlVaultEnabled = !pawlAtLaunch
        #expect(service.isEnabled == pawlAtLaunch)
        #expect((await service.refresh() == .connected) == pawlAtLaunch)
        #expect((await transport.methods.contains("hello")) == pawlAtLaunch)
        let relaunched = VaultService(settings: settings, client: SyntheticVaultRequests(),
                                      pawlEnabledAtLaunch: NookSettingsService.savedPawlVaultSelection(in: fixture.defaults))
        #expect(relaunched.isEnabled == !pawlAtLaunch)
    }

    @Test(arguments: [false, true])
    func secretIsFetchedOnlyAfterPickerAndUsesExactOriginProfile(code: Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault
        _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.focusVault(code:code)
        await agentCallbacks()
        #expect(presenter.items.count == 1)
        let before = await transport.methods
        #expect(before.contains("logins") && !before.contains("password") && !before.contains("code"))
        presenter.pick()
        await agentCallbacks()
        #expect(native.vaultFills.count == 1)
        #expect(native.vaultFills.first?.1 == (code ? "" : "synthetic-user"))
        #expect(native.vaultFills.first?.2 == (code ? "123456" : "synthetic-password"))
        let calls = await transport.contexts
        #expect(calls.allSatisfy { $0.0 == "https://vault.synthetic.invalid" && $0.1 == native.profileID?.uuidString })
    }

    @Test(arguments: [false, true])
    func pickerOmitsUnaddressableLoginsBeforeFilteringForCodes(code: Bool) async throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.tabs.settings.pawlVaultEnabled = true
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.tree.dataStoreID(for: space))
        let aliasedID = "d4fc54f2-114a-4394-8cad-08163983ee91"
        let transport = VerificationVault(origin: "https://vault.synthetic.invalid", profile: profile, logins: [
            .init(id: "shared", username: "first", title: "Shared", hasCode: true),
            .init(id: aliasedID, username: "one", title: "Same UUID", hasCode: true),
            .init(id: "", username: "missing-id", title: "Missing", hasCode: true),
            .init(id: "unique", username: "reachable", title: "Available", hasCode: true),
            .init(id: "shared", username: "second", title: "Other", hasCode: false),
            .init(id: aliasedID.uppercased(), username: "two", title: "Same UUID", hasCode: false),
        ])
        let presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings: fixture.tabs.settings, client: transport)
        vault.presenter = presenter
        fixture.tabs.vault = vault
        _ = await vault.refresh()
        let native = fixture.host.finishCreate(0)
        native.focusVault(code: code)
        await agentCallbacks()
        try #require(presenter.items.map(\.id) == [code ? "code:unique" : "login:unique"])
        presenter.pick()
        await agentCallbacks()
        #expect(native.vaultFills.count == 1)
        #expect(native.vaultFills.first?.2 == (code ? "246810" : "fixture-password"))
    }

    @Test func nativePasswordReplyMustMatchTheRawSelectedUsername() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let listed = "synthetic-\u{200B}user"
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        await transport.passwordUsers(listed:listed, reply:"synthetic-user")
        native.focusVault(); await agentCallbacks()
        try #require(presenter.items.count == 1 && presenter.nativeCompletion != nil)
        presenter.pick(); await agentCallbacks()
        #expect(await transport.methods.filter { $0 == "password" }.count == 1)
        #expect(native.vaultFills.isEmpty)

        native.vaultFills.removeAll()
        await transport.passwordUsers(listed:listed, reply:listed)
        native.focusVault(); await agentCallbacks()
        try #require(presenter.nativeCompletion != nil)
        presenter.pick(); await agentCallbacks()
        #expect(await transport.methods.filter { $0 == "password" }.count == 2)
        #expect(native.vaultFills.count == 1 && native.vaultFills.first?.1 == listed)
    }

    @Test(arguments:[false,true])
    func nativePickerCannotFetchAnUnofferedLoginOrCode(isCode:Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.focusVault(code:isCode); await agentCallbacks()
        let select = try #require(presenter.nativeCompletion)
        #expect(presenter.items.map(\.id) == [isCode ? "code:synthetic" : "login:synthetic"])
        let unoffered = VaultLogin(id:"unoffered",username:"synthetic-user",title:"Fixture",hasCode:true)
        select(.selected(isCode ? VaultPickerItem(code:unoffered) : VaultPickerItem(unoffered)))
        await agentCallbacks()
        let methods = await transport.methods
        #expect(!methods.contains("password") && !methods.contains("code"))
        #expect(native.vaultFills.isEmpty)
    }

    @Test(arguments: ["blur", "navigation", "close", "disconnect", "profile"])
    func pendingSecretCannotFillAfterAuthorityEnds(change: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault
        _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.focusVault(); await agentCallbacks()
        await transport.holdSecret()
        presenter.pick()
        for await _ in transport.started.stream { break }
        switch change {
        case "disconnect": await transport.disconnect(); _ = await vault.refresh()
        case "close": native.onEvent?(.closed)
        case "navigation": native.vaultDocumentCurrent = false; native.vaultCurrent = false; native.vaultFocus?(nil)
        case "profile":
            let selected = try #require(f.window.selectedItemID)
            let page = try #require(f.tabs.session(for:selected))
            page.detachedProfile = Profile.createEphemeral(id:UUID(),engine:.chromium)
        default: native.vaultCurrent = false; native.vaultFocus?(nil)
        }
        await transport.releaseSecret()
        await agentCallbacks()
        #expect(native.vaultFills.isEmpty)
        if change == "blur" || change == "navigation" {
            let page = try #require(f.window.selectedItemID.flatMap { f.tabs.session(for:$0) })
            #expect((page.nativeVaultNotice != nil) == (change == "blur"))
        }
    }

    @Test(arguments:[true,false])
    func exactPickerMayRestoreButCannotFetchWithoutNativeFocus(restored:Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.focusVault(); await agentCallbacks()
        native.vaultCurrent = false; native.vaultFocus?(nil)
        #expect(presenter.nativeCompletion != nil)
        presenter.restore = { native.vaultCurrent = restored; return restored }
        presenter.pick(); await agentCallbacks()
        let methods = await transport.methods
        #expect(methods.contains("password") == restored)
        #expect(native.vaultFills.count == (restored ? 1 : 0))
        if !restored {
            let page = try #require(f.window.selectedItemID.flatMap { f.tabs.session(for:$0) })
            #expect(page.nativeVaultNotice != nil)
        }
    }

    @Test func otherWindowOrNewFieldCannotUseOldPicker() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.focusVault(); await agentCallbacks()
        let oldChoice = presenter.nativeCompletion, oldValidation = presenter.nativeValidation
        native.focusVault(code:true); await agentCallbacks()
        #expect(oldValidation?() == false)
        oldChoice?(.selected(try #require(presenter.items.first)))
        #expect(presenter.nativeCompletion != nil)
        presenter.owns = false; native.vaultCurrent = false; native.vaultFocus?(nil)
        presenter.pick(); await agentCallbacks()
        let methods = await transport.methods
        #expect(!methods.contains("password") && !methods.contains("code"))
        #expect(native.vaultFills.isEmpty)
    }

    @Test(arguments:["otherWindow","applicationInactive"])
    func windowTransitionCancelsSecretWithoutFocusingOrLateFill(change:String) async throws {
        _ = NSApplication.shared
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        let owner = NSWindow(contentRect:CGRect(x:0,y:0,width:640,height:480),styleMask:.borderless,backing:.buffered,defer:true)
        owner.isReleasedWhenClosed = false; owner.contentView = native.vaultView
        defer { owner.close() }
        native.focusVault(); await agentCallbacks()
        await transport.holdSecret(); presenter.pick()
        for await _ in transport.started.stream { break }
        if change == "otherWindow" {
            let other = NSWindow(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:true)
            other.isReleasedWhenClosed = false
            NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:other)
            other.close()
        } else {
            NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:NSApplication.shared)
        }
        await transport.releaseSecret(); await agentCallbacks()
        #expect(native.vaultFills.isEmpty)
        let page = try #require(f.window.selectedItemID.flatMap { f.tabs.session(for:$0) })
        #expect(page.nativeVaultNotice != nil)
        #expect(!owner.isVisible)
    }

    @Test func lateSuccessfulSecretCannotCancelNewerFocusedRequest() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.focusVault(); await agentCallbacks()
        await transport.holdSecret(); presenter.pick()
        for await _ in transport.started.stream { break }
        native.focusVault(code:true); await agentCallbacks()
        #expect(presenter.nativeCompletion != nil)
        await transport.releaseSecret(); await agentCallbacks()
        #expect(presenter.nativeCompletion != nil && native.vaultFocus != nil)
        #expect(native.vaultFills.isEmpty)
        presenter.pick(); await agentCallbacks()
        #expect(native.vaultFills.count == 1 && native.vaultFills.first?.2 == "123456")
    }

    @Test func stoppedOldAttachmentDeinitCannotDetachReplacementOnSamePage() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        let page = try #require(f.window.selectedItemID.flatMap { f.tabs.session(for:$0) })
        var stopOld: (@MainActor () -> Void)? = vault.attach(to:native,session:page)
        native.focusVault(); await agentCallbacks()
        await transport.holdSecret(); presenter.pick()
        for await _ in transport.started.stream { break }
        stopOld?(); stopOld = nil
        let stopNew = vault.attach(to:native,session:page); defer { stopNew() }
        native.focusVault(code:true); await agentCallbacks()
        await transport.releaseSecret(); await agentCallbacks()
        #expect(native.vaultFocus != nil && presenter.nativeCompletion != nil)
        #expect(native.vaultFills.isEmpty)
        presenter.pick(); await agentCallbacks()
        #expect(native.vaultFills.count == 1 && native.vaultFills.first?.2 == "123456")
    }

    @Test(arguments:["notRunning", "locked"])
    func refocusingAfterVaultRecoveryRestoresFillSaveAndPasskeys(initial:String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        await transport.availability(initial)
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault
        _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        #expect(native.vaultFocus != nil && native.vaultSave == nil && native.passkeyCallback == nil)
        native.focusVault(); await agentCallbacks()
        #expect(presenter.nativeCompletion == nil && native.vaultFills.isEmpty)
        let before = await transport.methods
        #expect(!before.contains("logins") && !before.contains("password") && !before.contains("code"))
        // Stay on the same page. The next field gesture must discover the unlocked vault.
        await transport.availability("available")
        native.focusVault(); await agentCallbacks()
        #expect(vault.isConnected && presenter.nativeCompletion != nil)
        #expect(native.vaultSave != nil && native.passkeyCallback != nil)
        let metadataOnly = await transport.methods
        #expect(!metadataOnly.contains("password") && !metadataOnly.contains("code"))
        presenter.pick(); await agentCallbacks()
        #expect(native.vaultFills.count == 1 && native.vaultFills.first?.2 == "synthetic-password")
        native.submitVault(); await agentCallbacks()
        #expect(presenter.loginAction == .create && presenter.saveCompletion != nil)
        #expect(await transport.saves.isEmpty)
        presenter.saveCompletion?(false)
        native.requestPasskey(operation: 1); await agentCallbacks()
        #expect(presenter.nativeCompletion != nil && native.passkeyReplies.isEmpty)
        presenter.pick(); await agentCallbacks()
        #expect(await transport.assertedCredentials == ["AQ"])
        #expect(native.passkeyReplies.count == 1 && native.passkeyReplies.first?.1 != nil)
    }

    @Test func nativeNavigationUsesExistingThrottledVaultStatusRefresh() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault
        _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        await agentCallbacks()
        let before = await transport.methods.filter { $0 == "hello" }.count
        native.onEvent?(.started(URL(string:"https://vault.synthetic.invalid/one")))
        await agentCallbacks()
        let once = await transport.methods.filter { $0 == "hello" }.count
        #expect(once == before + 1)
        native.onEvent?(.started(URL(string:"https://vault.synthetic.invalid/two")))
        await agentCallbacks()
        let twice = await transport.methods.filter { $0 == "hello" }.count
        #expect(twice == once)
    }

    @Test(.timeLimit(.minutes(1))) func leavingFieldDuringVaultRecoverySkipsSiteLookup() async throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        await transport.availability("locked")
        let vault = VaultService(settings: fixture.tabs.settings, client: transport, pawlEnabledAtLaunch: true)
        vault.presenter = presenter
        fixture.tabs.vault = vault
        #expect(await vault.refresh() == .locked)
        let page = fixture.host.finishCreate(0)
        await agentCallbacks()
        await transport.availability("available")
        await transport.holdNextHello()
        page.focusVault()
        for await _ in transport.helloStarted.stream { break }
        page.vaultDocumentCurrent = false
        await transport.resumeHello()
        await agentCallbacks()
        #expect(vault.isConnected && page.passkeyCallback != nil && page.vaultSave != nil)
        #expect(presenter.nativeCompletion == nil && page.vaultFills.isEmpty)
        let methods = await transport.methods
        #expect(!methods.contains("logins") && !methods.contains("password"))
    }

    @Test func validatedSaveSurvivesRedirectAndRequiresConsent() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.submitVault(); await agentCallbacks()
        #expect(presenter.saveCompletion != nil)
        NotificationCenter.default.post(name:Notification.Name("NookVaultNativeStateChanged"),object:vault)
        await agentCallbacks()
        #expect(presenter.saveCompletion != nil && native.vaultSaveValid)
        let before = await transport.methods
        #expect(presenter.loginAction == .create)
        #expect(before.contains("prepareLoginWrite") && !before.contains("commitLoginWrite") && !before.contains("save"))
        // A login redirect replaces the document, not Chromium's accepted submission.
        native.vaultDocumentCurrent = false
        native.onEvent?(.started(URL(string:"https://redirect.synthetic.invalid/done")))
        native.onEvent?(.committed(URL(string:"https://redirect.synthetic.invalid/done")))
        await agentCallbacks()
        let answer = presenter.saveCompletion; presenter.saveCompletion = nil; answer?(true)
        await agentCallbacks()
        let saves = await transport.saves
        #expect(saves.count == 1)
        #expect(saves.first?.0 == "https://vault.synthetic.invalid")
        #expect(saves.first?.1 == "new-synthetic-user" && saves.first?.2 == "typed-synthetic-password")
        #expect(saves.first?.3 == native.profileID?.uuidString)
    }

    @Test func vaultLauncherUsesEffectiveProvider() throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let transport = SyntheticVaultRequests()
        var launches = 0
        let launch: @MainActor () -> Bool = { launches += 1; return true }
        f.tabs.settings.pawlVaultEnabled = true
        let disabled = VaultService(settings: f.tabs.settings, client: transport, pawlEnabledAtLaunch: false,
                                    openPawlApplication: launch)
        #expect(!disabled.openPawlVault() && launches == 0)
        f.tabs.settings.pawlVaultEnabled = false
        let enabled = VaultService(settings: f.tabs.settings, client: transport, pawlEnabledAtLaunch: true,
                                   openPawlApplication: launch)
        #expect(enabled.openPawlVault() && launches == 1)
    }

    @Test(arguments: ["open", "decline", "stale", "private", "ephemeral", "unavailable"])
    func legacyVaultOnlyOffersManualManagement(action: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        await transport.advertiseConditionalWrites(false)
        var launches = 0
        let vault = VaultService(settings: f.tabs.settings, client: transport, openPawlApplication: {
            launches += 1
            return action != "unavailable"
        })
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native: NativeTestPage
        if action == "private" {
            let window = f.privateWindow()
            _ = try #require(f.tabs.open(url: URL(string: "https://vault.synthetic.invalid")!,
                                          in: window, placement: .newTab))
            native = f.host.finishCreate(f.host.creates.count - 1)
        } else {
            native = f.host.finishCreate(0)
        }
        if action == "ephemeral" { f.tabs.selectedSession(in: f.window)?.profile?.isEphemeral = true }
        native.submitVault(username: "synthetic-user")
        await agentCallbacks()
        if action == "private" || action == "ephemeral" {
            #expect(presenter.loginAction == nil && presenter.saveCompletion == nil)
            #expect(!(await transport.methods).contains("logins"))
        } else {
            #expect(presenter.loginAction == .manageExisting && launches == 0)
            let answer = try #require(presenter.saveCompletion)
            if action == "stale" {
                native.vaultSaveValid = false
                native.vaultSave?(nil)
            }
            answer(action != "decline")
            answer(true)
        }
        #expect(!native.vaultSaveValid)
        #expect(launches == (action == "open" || action == "unavailable" ? 1 : 0))
        #expect(await transport.saves.isEmpty)
        let methods = await transport.methods
        #expect(!methods.contains("password") && !methods.contains("save") && !methods.contains("commitLoginWrite"))
        if action == "unavailable" {
            #expect(f.tabs.selectedSession(in: f.window)?.nativeVaultNotice ==
                    "Open Pawl Vault directly to update this password.")
        }
    }

    @Test(arguments: [true, false])
    func oldVaultCannotOverwriteAnAccountCreatedAfterLookup(exclusiveSDK: Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let space = try #require(f.window.spaceID)
        let profile = try #require(f.tabs.tree.dataStoreID(for: space))
        let origin = "https://vault.synthetic.invalid"
        let transport = VerificationVault(origin: origin, profile: profile, conditionalLoginWrites: false)
        let presenter = SyntheticVaultPresenter()
        var launches = 0
        let vault = VaultService(settings: f.tabs.settings, client: transport, pawlEnabledAtLaunch: exclusiveSDK ? true : nil,
                                 openPawlApplication: { launches += 1; return true })
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.submitVault(); await agentCallbacks()
        #expect(presenter.loginAction == .manageNew)
        let answer = try #require(presenter.saveCompletion)
        let external = try await transport.send(VaultSave(origin: origin, username: "new-synthetic-user",
                                                           password: "external-edit", profile: profile.uuidString))
        answer(true); answer(true); await agentCallbacks()
        let existing = try await transport.send(VaultPassword(id: external.id, origin: origin, profile: profile.uuidString))
        #expect(existing.password == "external-edit" && launches == 1 && !native.vaultSaveValid)
    }

    @Test(arguments: ["approved", "ambiguous", "conflict", "lostReply", "invalidTicket", "unsupported", "stale"])
    func checkedUpdateCommitsOnlyTheApprovedTicket(result: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        await transport.checkedWriteScenario(result)
        var launches = 0
        let vault = VaultService(settings: f.tabs.settings, client: transport, pawlEnabledAtLaunch: true,
                                 openPawlApplication: { launches += 1; return true })
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.submitVault(username: "synthetic-user"); await agentCallbacks()
        if result == "invalidTicket" || result == "unsupported" {
            #expect(presenter.saveCompletion == nil)
        } else {
            #expect(presenter.loginAction == (result == "ambiguous" ? .manageExisting : .update))
            let answer = try #require(presenter.saveCompletion)
            if result == "stale" { native.vaultSaveValid = false }
            answer(true); answer(true); await agentCallbacks()
        }
        let methods = await transport.methods
        #expect(!methods.contains("save") && !methods.contains("password") && !methods.contains("logins"))
        let commits = methods.filter { $0 == "commitLoginWrite" }
        #expect(commits.count == (["approved", "conflict", "lostReply"].contains(result) ? 1 : 0))
        #expect(await transport.saves.count == (["approved", "lostReply"].contains(result) ? 1 : 0))
        #expect(launches == (result == "ambiguous" ? 1 : 0))
        if result == "conflict" || result == "lostReply" {
            let notice = f.tabs.selectedSession(in: f.window)?.nativeVaultNotice
            #expect(notice == (result == "conflict" ? "Review this login in Pawl Vault before saving again."
                                                    : "Save unconfirmed. Check this login in Pawl Vault."))
        }
    }

    @Test(arguments:["decline", "replacement", "owner", "profile", "disable", "disconnect", "window"])
    func endedSaveCannotWriteOrDismissNewerOffer(change:String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.submitVault(); await agentCallbacks()
        let old = try #require(presenter.saveCompletion)
        switch change {
        case "decline": presenter.saveCompletion = nil; old(false)
        case "replacement": native.submitVault(); await agentCallbacks()
        case "owner": native.vaultSaveValid = false; native.vaultSave?(nil)
        case "profile": native.vaultProfileOverride = UUID()
        case "disable": f.tabs.settings.pawlVaultEnabled = false
        case "window":
            let other = NSWindow(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:true)
            other.isReleasedWhenClosed = false
            other.contentView?.addSubview(native.vaultView)
            old(true)
            #expect(presenter.saveCompletion == nil && !native.vaultSaveValid)
            other.close()
        default: await transport.disconnect(); _ = await vault.refresh()
        }
        old(true); await agentCallbacks()
        #expect(await transport.saves.isEmpty)
        if change == "replacement" {
            #expect(presenter.saveCompletion != nil)
            presenter.saveCompletion?(true); await agentCallbacks()
            #expect(await transport.saves.count == 1)
        }
    }

    @Test func dispatchedSaveReplyCannotDismissReplacementSubmission() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.submitVault(); await agentCallbacks()
        await transport.holdNextSave()
        presenter.saveCompletion?(true)
        for await _ in transport.saveStarted.stream { break }
        native.submitVault(); await agentCallbacks()
        let replacement = try #require(presenter.saveCompletion)
        await transport.releaseSave(); await agentCallbacks()
        #expect(presenter.saveCompletion != nil && native.vaultSaveValid)
        replacement(false); await agentCallbacks()
        #expect(await transport.saves.count == 1)
    }

    @Test(arguments:[Int32(0),Int32(1)])
    func nativePasskeyConsentUsesChromiumHashAndExactProfile(operation:Int32) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.requestPasskey(operation:operation); await agentCallbacks()
        #expect(await transport.ceremonies.isEmpty)
        if operation == 0 {
            #expect(presenter.creationConsent != nil)
            let reply = presenter.creationConsent; presenter.creationConsent = nil; reply?(true)
        } else {
            #expect(presenter.nativeCompletion != nil)
            presenter.pick()
        }
        await agentCallbacks()
        let calls = await transport.ceremonies
        #expect(calls.count == 1 && calls.first?.0 == (operation == 0 ? "register" : "assert"))
        #expect(calls.first?.1 == "vault.synthetic.invalid")
        #expect(calls.first?.2 == Base64URL.encode(Data(repeating:0,count:32)))
        #expect(calls.first?.3 == "https://vault.synthetic.invalid")
        #expect(calls.first?.4 == native.profileID?.uuidString)
        #expect(native.passkeyReplies.filter { $0.1 != nil }.count == 1)
    }

    @Test(arguments: ["returnsToOwner", "switchesWindow", "changesDocument"])
    func nativePasskeyWaitsForExactChooserHandoff(change: String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        var activeKey: NSWindow?
        let vault = VaultService(settings: f.tabs.settings, client: transport,
                                 passkeyKeyWindow: { activeKey })
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        let owner = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        owner.isReleasedWhenClosed = false
        owner.contentView = native.vaultView
        defer { owner.close() }
        let child = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        child.isReleasedWhenClosed = false
        owner.addChildWindow(child, ordered: .above)
        defer { owner.removeChildWindow(child); child.close() }
        activeKey = child

        native.requestPasskey(operation: 0)
        #expect(presenter.creationConsent == nil)
        #expect(native.passkeyReplies.isEmpty)
        #expect(await transport.ceremonies.isEmpty)

        if change == "changesDocument" { native.passkeyValid = false }
        let nextKey = change == "switchesWindow" ? NSWindow() : owner
        nextKey.isReleasedWhenClosed = false
        defer { if nextKey !== owner { nextKey.close() } }
        activeKey = nextKey
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nextKey)
        if change == "returnsToOwner" {
            let confirm = try #require(presenter.creationConsent)
            confirm(false)
        } else {
            #expect(presenter.creationConsent == nil)
        }
        #expect(await transport.ceremonies.isEmpty)
        #expect(native.passkeyReplies.count == 1 && native.passkeyReplies.first?.1 == nil)
    }

    @Test(arguments:["decline","document","owner","profile","disable","disconnect","badHash","badOperation",
                     "window","otherKeyWindow","closedWindow","hiddenView"])
    func nativePasskeyRefusalNeverDispatchesOrCompletesStaleRequest(change:String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.requestPasskey(operation:change == "emptyAllow" ? 1 : change == "badOperation" ? 9 : 0,
            badHash:change == "badHash",emptyAllow:change == "emptyAllow")
        await agentCallbacks()
        let answer = presenter.creationConsent
        let other = NSWindow(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        switch change {
        case "document","owner": native.passkeyValid = false; native.passkeyCallback?(nil)
        case "profile": native.vaultProfileOverride = UUID()
        case "window": other.contentView?.addSubview(native.vaultView)
        case "otherKeyWindow": NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        case "closedWindow": NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: native.vaultView.window)
        case "hiddenView":
            native.vaultView.isHidden = true
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: native.vaultView.window)
        case "disable": f.tabs.settings.pawlVaultEnabled = false
        case "disconnect": await transport.disconnect(); _ = await vault.refresh()
        default: break
        }
        answer?(change != "decline"); await agentCallbacks()
        #expect(await transport.ceremonies.isEmpty)
        #expect(native.passkeyReplies.filter { $0.1 != nil }.isEmpty)
        if ["window","otherKeyWindow","closedWindow","hiddenView"].contains(change) {
            #expect(native.passkeyReplies.count == 1 && presenter.creationConsent == nil)
        }
    }

    @Test(arguments:[false,true])
    func latePawlAuthenticationCannotCompleteCancelledRequestOrDismissNewConsent(switchSpace:Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        await transport.holdNextCeremony()
        native.requestPasskey(operation:0); await agentCallbacks()
        presenter.creationConsent?(true)
        for await _ in transport.ceremonyStarted.stream { break }
        if switchSpace {
            let frame = try #require(native.vaultView.superview)
            frame.isHidden = true
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: native.vaultView.window)
            #expect(!native.passkeyValid && presenter.creationConsent == nil)
            frame.isHidden = false
        } else {
            native.passkeyValid = false; native.passkeyCallback?(nil)
        }
        native.requestPasskey(operation:0); await agentCallbacks()
        #expect(presenter.creationConsent != nil)
        await transport.releaseCeremony(); await agentCallbacks()
        #expect(presenter.creationConsent != nil && native.passkeyValid)
        #expect(native.passkeyReplies.filter { $0.1 != nil }.isEmpty)
        presenter.creationConsent?(false)
    }

    @Test(arguments:[false,true])
    func fieldFocusCannotReplacePasskeyConsentOrAuthentication(authenticating:Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        if authenticating { await transport.holdNextCeremony() }
        native.requestPasskey(operation:0); await agentCallbacks()
        if authenticating {
            presenter.creationConsent?(true)
            for await _ in transport.ceremonyStarted.stream { break }
        }
        native.focusVault(); await agentCallbacks()
        let during = await transport.methods
        #expect(!during.contains("logins") && !during.contains("password") && !during.contains("code"))
        #expect(presenter.nativeCompletion == nil)
        native.passkeyValid = false; native.passkeyCallback?(nil)
        if authenticating { await transport.releaseCeremony() }
        await agentCallbacks()
        native.focusVault(); await agentCallbacks()
        #expect(presenter.nativeCompletion != nil)
        presenter.pick(); await agentCallbacks()
        #expect(native.vaultFills.count == 1)
    }

    @Test func queuedCeremonyCancelledBehindEarlierRpcNeverDispatchesAndCannotClearNewTask() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0); await agentCallbacks()
        await transport.holdEarlierRpc()
        let earlier = Task { try await transport.send(VaultLogins(origin:"https://earlier.synthetic.invalid",profile:nil)) }
        for await _ in transport.earlierStarted.stream { break }
        native.requestPasskey(operation:0); await agentCallbacks()
        presenter.creationConsent?(true)
        for await _ in transport.queuedStarted.stream { break }
        native.passkeyValid = false; native.passkeyCallback?(nil)
        native.requestPasskey(operation:0); await agentCallbacks()
        let newer = try #require(presenter.creationConsent)
        await transport.releaseEarlierRpc(); _ = try await earlier.value
        await agentCallbacks()
        #expect(await transport.ceremonies.isEmpty)
        #expect(presenter.creationConsent != nil && native.passkeyValid)
        newer(true); await agentCallbacks()
        #expect(await transport.ceremonies.count == 1)
        #expect(native.passkeyReplies.filter { $0.1 != nil }.count == 1)
    }

    @Test(arguments:["AQ", "", "missing"])
    func modalResidentAssertionUsesVaultPickerAndRealUserHandle(handle:String) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        await transport.assertionHandle(handle == "missing" ? nil : handle)
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        native.requestPasskey(operation:1,emptyAllow:true); await agentCallbacks()
        #expect(await transport.passkeyAllowed == [[]])
        #expect(presenter.nativeCompletion != nil)
        #expect(await transport.ceremonies.isEmpty)
        presenter.pick(); await agentCallbacks()
        let results = native.passkeyReplies.compactMap { $0.1 }
        #expect(results.count == (handle == "AQ" ? 1 : 0))
        if let result = results.first {
            let object = try #require(try JSONSerialization.jsonObject(with:Data(result.utf8)) as? [String:Any])
            #expect(object["userHandle"] as? String == handle)
            #expect(object["credentialId"] as? String == "AQ")
        }
    }

    @Test(arguments:[false,true])
    func nativeAssertionReplyMustMatchTheSelectedCredential(emptyAllow:Bool) async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        for returnedID in ["Ag", "AQ"] {
            // Aw repeats, BA and BB encode the same bytes, and BR lacks a canonical row.
            await transport.assertionCredentials(listed:["AQ","Aw","BA","","Ag","BB","Aw","BR"], reply:returnedID)
            native.requestPasskey(operation:1,emptyAllow:emptyAllow,allowed:["AQ","Ag"])
            await agentCallbacks()
            try #require(presenter.items.map(\.id) == ["passkey:AQ","passkey:Ag"])
            try #require(presenter.nativeCompletion != nil)
            let count = native.passkeyReplies.count
            presenter.pick(); await agentCallbacks()
            #expect(native.passkeyReplies.count == count + 1)
            let result = native.passkeyReplies.last?.1
            if returnedID == "AQ" {
                let payload = try #require(result)
                let object = try #require(try JSONSerialization.jsonObject(with:Data(payload.utf8)) as? [String:Any])
                #expect(object["credentialId"] as? String == "AQ")
            } else {
                #expect(result == nil)
            }
        }
        #expect(await transport.assertedCredentials == ["AQ","AQ"])
        #expect(await transport.passkeyAllowed == Array(repeating:emptyAllow ? [] : ["AQ","Ag"],count:2))
    }

    @Test func disconnectedNativePasskeysLeaveStockProviderPathAvailable() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(); await transport.disconnect()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        #expect(native.passkeyCallback == nil)
    }

    @Test func disabledVaultNeverRegistersSaveConsumer() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault
        let native = f.host.finishCreate(0)
        #expect(native.vaultSave == nil)
        native.submitVault(); await agentCallbacks()
        let saves = await transport.saves
        #expect(presenter.saveCompletion == nil && saves.isEmpty)
    }

    @Test func oldLookupFailureCannotDismissNewerPicker() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        f.tabs.settings.pawlVaultEnabled = true
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault; _ = await vault.refresh()
        let native = f.host.finishCreate(0)
        await transport.holdNextLookup()
        native.focusVault()
        for await _ in transport.lookupStarted.stream { break }
        native.focusVault(code:true); await agentCallbacks()
        #expect(presenter.completion != nil)
        await transport.failLookup(); await agentCallbacks()
        #expect(presenter.completion != nil)
        presenter.pick(); await agentCallbacks()
        #expect(native.vaultFills.first?.2 == "123456")
    }

    @Test func disconnectedAndUnsafeOriginNeverOpenPickerOrFetchSecrets() async throws {
        let f = try NativeModelFixture(); defer { f.cleanup() }
        let transport = SyntheticVaultRequests(), presenter = SyntheticVaultPresenter()
        let vault = VaultService(settings:f.tabs.settings,client:transport)
        vault.presenter = presenter; f.tabs.vault = vault
        let native = f.host.finishCreate(0)
        #expect(native.vaultFocus == nil)
        f.tabs.settings.pawlVaultEnabled = true; _ = await vault.refresh()
        native.focusVault(origin:"http://remote.synthetic.invalid"); await agentCallbacks()
        #expect(presenter.items.isEmpty)
        let methods = await transport.methods
        #expect(!methods.contains("logins") && !methods.contains("password") && !methods.contains("code"))
    }
}

@MainActor
private final class SyntheticVaultPresenter: VaultPresenter {
    var items: [VaultPickerItem] = []
    var completion: ((VaultPickerItem?) -> Void)?
    func presentPicker(host:String,items:[VaultPickerItem],anchor:CGRect,in view:NSView,completion:@escaping(VaultPickerItem?)->Void) {
        self.items = items; self.completion = completion
    }
    var nativeValidation: (@MainActor () -> Bool)?
    var nativeCompletion: ((VaultNativePickerResult) -> Void)?
    var restore: (() -> Bool)?
    var owns = true
    func presentNativePicker(host:String,items:[VaultPickerItem],anchor:CGRect,in view:NSView,
                             validateSelection:@escaping @MainActor ()->Bool,
                             completion:@escaping(VaultNativePickerResult)->Void) {
        self.items = items; nativeValidation = validateSelection; nativeCompletion = completion
        self.completion = { _ in }
    }
    func ownsNativePicker(in view:NSView)->Bool { owns && nativeCompletion != nil }
    func pick() {
        if let done = nativeCompletion {
            let valid = nativeValidation?() == true
            nativeCompletion = nil; completion = nil
            guard valid else { done(.cancelled); return }
            guard restore?() ?? true else { done(.focusUnavailable); return }
            if let item = items.first { done(.selected(item)) } else { done(.cancelled) }
        } else { let done = completion; completion = nil; done?(items.first) }
    }
    func dismissPicker(in view:NSView) {
        let native = nativeCompletion; nativeCompletion = nil
        let done = completion; completion = nil
        native?(.cancelled); done?(nil)
    }
    var creationConsent: ((Bool)->Void)?
    weak var creationView: NSView?
    func confirmNativePasskeyCreation(rpId:String,userName:String,in view:NSView,completion:@escaping(Bool)->Void) {
        creationView = view; creationConsent = completion
    }
    func dismissNativePasskey(in view:NSView) {
        dismissPicker(in:view)
        guard creationView === view else { return }
        let done = creationConsent; creationConsent = nil; creationView = nil; done?(false)
    }
    var saveCompletion: ((Bool)->Void)?
    var loginAction: VaultLoginOffer?
    weak var saveView: NSView?
    func offerNativeLogin(_ action: VaultLoginOffer, host: String, username: String, itemID: UUID,
                          in view: NSView, completion: @escaping (Bool) -> Void) {
        let old = saveCompletion; saveCompletion = nil; old?(false)
        loginAction = action
        saveView = view; saveCompletion = completion
    }
    func dismissSave(in view:NSView) {
        guard saveView === view else { return }
        let old = saveCompletion; saveCompletion = nil; saveView = nil; old?(false)
    }
    func offerSave(host:String,username:String,in view:NSView,completion:@escaping(Bool)->Void) { completion(false) }
    func confirmPasskeyCreation(rpId:String,userName:String,in view:NSView,completion:@escaping(Bool)->Void) { completion(false) }
}

private actor SyntheticVaultRequests: VaultRequests {
    var methods: [String] = []
    private var holdHello = false
    private var pendingHello: CheckedContinuation<Void, Never>?
    nonisolated let helloStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    func holdNextHello() { holdHello = true }
    func resumeHello() { pendingHello?.resume(); pendingHello = nil }
    var conditionalWrites = true
    var writeScenario = "approved"
    func advertiseConditionalWrites(_ enabled: Bool) { conditionalWrites = enabled }
    func checkedWriteScenario(_ value: String) { writeScenario = value }
    var contexts: [(String,String?)] = []
    var holdEarlier = false
    var earlierPending = false
    var earlierContinuation: CheckedContinuation<Void,Never>?
    var queuedContinuation: CheckedContinuation<Void,Never>?
    let earlierStarted = AsyncStream.makeStream(of:Void.self)
    let queuedStarted = AsyncStream.makeStream(of:Void.self)
    func holdEarlierRpc() { holdEarlier = true }
    func releaseEarlierRpc() {
        earlierPending = false
        earlierContinuation?.resume(); earlierContinuation = nil
        queuedContinuation?.resume(); queuedContinuation = nil
    }
    var listedUsername = "synthetic-user"
    var passwordUsername = "synthetic-user"
    func passwordUsers(listed:String, reply:String) { listedUsername = listed; passwordUsername = reply }
    var listedCredentials = ["AQ"]
    var assertionCredential = "AQ"
    var assertedCredentials: [String] = []
    func assertionCredentials(listed:[String], reply:String) { listedCredentials = listed; assertionCredential = reply }
    var passkeyAllowed: [[String]] = []
    var assertionUserHandle: String? = "AQ"
    func assertionHandle(_ value:String?) { assertionUserHandle = value }
    var ceremonies: [(String,String,String,String,String?)] = []
    var heldCeremony = false
    var pendingCeremony: CheckedContinuation<Void,Never>?
    let ceremonyStarted = AsyncStream.makeStream(of:Void.self)
    func holdNextCeremony() { heldCeremony = true }
    func releaseCeremony() { pendingCeremony?.resume(); pendingCeremony = nil }
    var heldSave = false
    var pendingSave: CheckedContinuation<Void,Never>?
    let saveStarted = AsyncStream.makeStream(of:Void.self)
    func holdNextSave() { heldSave = true }
    func releaseSave() { pendingSave?.resume(); pendingSave = nil }
    var saves: [(String,String,String,String?)] = []
    var connected = true
    var locked = false
    func availability(_ state:String) { connected = state != "notRunning"; locked = state == "locked" }
    var held = false
    var pending: CheckedContinuation<Void,Never>?
    var holdLookup = false
    var lookupPending: CheckedContinuation<Void,Error>?
    nonisolated let lookupStarted = AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingOldest(1))
    func holdNextLookup() { holdLookup = true }
    func failLookup() { lookupPending?.resume(throwing:VaultClientError.server(.badRequest,"synthetic")); lookupPending = nil }
    nonisolated let started = AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingOldest(1))
    func holdSecret() { held = true }
    func releaseSecret() { held = false; pending?.resume(); pending = nil }
    func disconnect() { connected = false }
    func send<C:VaultCall>(_ call:C) async throws -> C.Reply {
        if C.method == "hello", holdHello {
            holdHello = false
            await withCheckedContinuation { continuation in
                pendingHello = continuation
                helloStarted.continuation.yield(())
            }
        }
        if C.method == "logins", holdEarlier {
            holdEarlier = false; earlierPending = true; earlierStarted.continuation.yield(())
            await withCheckedContinuation { earlierContinuation = $0 }
        }
        if (C.method == "register" || C.method == "assert"), earlierPending {
            queuedStarted.continuation.yield(())
            await withCheckedContinuation { queuedContinuation = $0 }
        }
        // Models VaultClient's actor-entry guard before any native connect/write.
        try Task.checkCancellation()
        methods.append(C.method)
        guard connected else { throw VaultClientError.connectionClosed }
        let params = try JSONSerialization.jsonObject(with:JSONEncoder().encode(call)) as! [String:Any]
        if let origin = params["origin"] as? String { contexts.append((origin,params["profile"] as? String)) }
        if locked && C.method != "hello" { throw VaultClientError.server(.locked,"synthetic") }
        if C.method == "logins", holdLookup {
            holdLookup = false
            lookupStarted.continuation.yield(())
            try await withCheckedThrowingContinuation { lookupPending = $0 }
        }
        if C.method == "password" || C.method == "code" {
            started.continuation.yield(())
            if held { await withCheckedContinuation { pending = $0 } }
        }
        if C.method == "register" || C.method == "assert" {
            ceremonies.append((C.method,params["rpId"] as! String,params["clientDataHash"] as! String,
                params["origin"] as! String,params["profile"] as? String))
            if heldCeremony {
                heldCeremony = false; ceremonyStarted.continuation.yield(())
                await withCheckedContinuation { pendingCeremony = $0 }
            }
        }
        let result: [String:Any]
        switch C.method {
        case "hello":
            var hello: [String: Any] = ["vault": "synthetic", "version": 1, "paired": true, "unlocked": !locked]
            if conditionalWrites { hello["capabilities"] = ["conditionalLoginWrites"] }
            result = hello
        case "prepareLoginWrite":
            guard conditionalWrites && writeScenario != "unsupported" else { throw VaultClientError.server(.badRequest, "") }
            if writeScenario == "ambiguous" {
                result = ["disposition": "ambiguous"]
            } else {
                let exists = (params["username"] as? String) == "synthetic-user"
                result = ["disposition": exists ? "update" : "create", "ticket": writeScenario == "invalidTicket" ? "" : "test-ticket"]
            }
        case "logins": result = ["logins":[["id":"synthetic","username":listedUsername,"title":"Fixture","hasCode":true]]]
        case "passkeys":
            passkeyAllowed.append(params["allowCredentials"] as? [String] ?? [])
            result = ["passkeys":listedCredentials.map { ["credentialId":$0,"userName":"synthetic-user","title":"Synthetic"] }]
        case "register": result = ["credentialId":"AQ","attestationObject":"AA","authenticatorData":"AA","publicKeyAlgorithm":-7]
        case "assert":
            assertedCredentials.append(params["credentialId"] as! String)
            var assertion: [String:Any] = ["credentialId":assertionCredential,"authenticatorData":"AA","signature":"AA"]
            if let handle = assertionUserHandle { assertion["userHandle"] = handle }
            result = assertion
        case "commitLoginWrite":
            guard conditionalWrites, params["ticket"] as? String == "test-ticket" else { throw VaultClientError.malformedResponse }
            if writeScenario == "conflict" { result = ["outcome": "conflict"]; break }
            if heldSave {
                heldSave = false; saveStarted.continuation.yield(())
                await withCheckedContinuation { pendingSave = $0 }
            }
            saves.append((params["origin"] as! String,params["username"] as! String,params["password"] as! String,params["profile"] as? String))
            if writeScenario == "lostReply" { throw VaultClientError.connectionClosed }
            result = ["outcome": "saved"]
        case "password": result = ["username":passwordUsername,"password":"synthetic-password"]
        case "code": result = ["code":"123456","period":30,"remaining":20]
        default: throw VaultClientError.malformedResponse
        }
        return try JSONDecoder().decode(C.Reply.self,from:JSONSerialization.data(withJSONObject:result))
    }
}

@MainActor
private final class NativeModelFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite = "NookNativePageTests-\(UUID().uuidString)"
    let tabs: TabsController
    let registry = WindowRegistry()
    let window = BrowserWindowState()
    let host = ControlledNativeHost()
    init(synchronous: Bool = false, nativeBlocking: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = NookSettingsService(kagiTokenStore: NativeNoTokenStore(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: directory.appendingPathComponent("Boosts.json")))
        tabs = TabsController(settings: settings, windowRegistry: registry,
            blocker: ContentBlockerManager(settings: settings, storageDirectory: directory.appendingPathComponent("Blocker"),
                nativeNetworkBlocking: nativeBlocking), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium,
            directory: directory.appendingPathComponent("Tabs"))
        registry.register(window)
        registry.setActive(window)
        tabs.attach(window: window)
        host.synchronous = synchronous
        tabs.nativePageHost = host
    }
    func privateWindow(sharing profile: Profile? = nil) -> BrowserWindowState {
        let window = BrowserWindowState(); window.isIncognito = true
        window.ephemeralProfile = profile ?? Profile.createEphemeral(id: UUID(), engine: .chromium)
        registry.register(window); tabs.attach(window: window, restoringSavedState: false)
        return window
    }
    func restored(at directory: URL) -> TabsController {
        let settings = NookSettingsService(kagiTokenStore: NativeNoTokenStore(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: directory.appendingPathComponent("Boosts.json")))
        return TabsController(settings: settings, windowRegistry: WindowRegistry(),
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium, directory: directory)
    }
    func cleanup() {
        tabs.settings.flushBoosts()
        for index in host.creates.indices where host.creates[index].completion != nil { host.failCreate(index) }
        for index in host.closes.indices where host.closes[index].completion != nil { host.finishClose(index, admitted: true) }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct NativeNoTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@MainActor
private final class DetachedNativeOwner: NativePageResourceOwner {
    var requests = 0
    var completion: (@MainActor (PageCloseOutcome) -> Void)?
    func closePage(_ page: any PageNavigation, completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        requests += 1
        self.completion = completion
    }
    func complete(_ outcome: PageCloseOutcome) {
        let callback = completion
        completion = nil
        callback?(outcome)
    }
}

@MainActor
private final class ControlledNativeHost: NativePageHost {
    final class Creation {
        let profileID: UUID
        var cancelled = false
        var completion: (@MainActor (Result<any PageNavigation, Error>) -> Void)?
        init(profileID: UUID, completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void) {
            self.profileID = profileID
            self.completion = completion
        }
    }
    final class Closing {
        let page: NativeTestPage
        let successor: NativeTestPage?
        var completion: (@MainActor (PageCloseOutcome) -> Void)?
        init(page: NativeTestPage, successor: NativeTestPage? = nil,
             completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
            self.page = page
            self.successor = successor
            self.completion = completion
        }
    }
    var creates: [Creation] = []
    var closes: [Closing] = []
    var synchronous = false
    var admitSelection = true
    var onSelect: ((any PageNavigation, BrowserWindowState) -> Void)?
    var onCancel: (() -> Void)?
    func createPage(for session: PageSession, profile: Profile, in window: BrowserWindowState,
                    completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void) -> (@MainActor () -> Void) {
        let request = Creation(profileID: profile.id, completion: completion)
        creates.append(request)
        if synchronous { _ = finishCreate(creates.count - 1) }
        return { [weak self, weak request] in
            if request?.completion != nil {
                request?.cancelled = true
                let callback = self?.onCancel
                self?.onCancel = nil
                callback?()
            }
        }
    }
    private(set) var selectionCount = 0
    var admitsAdoption = true
    var nativeOwnerWindow: UUID?
    func canAdoptPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        admitsAdoption && (nativeOwnerWindow == nil || nativeOwnerWindow == window.id) && !(page as! NativeTestPage).invalidated
    }
    func selectPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        selectionCount += 1
        let admitted = admitSelection
        let callback = onSelect
        onSelect = nil
        callback?(page, window)
        return admitted
    }
    var nativeSelectedPage: NativeTestPage?
    var nativeSelectedWindow: UUID?
    private var nativeHeaderPage: NativeTestPage?
    var onAcceptNativeSelection: ((any PageNavigation, BrowserWindowState) -> Void)?
    func acceptNativeSelection(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard canAdoptPage(page, in: window), nativeSelectedPage === page,
              nativeSelectedWindow == window.id else { return false }
        let callback = onAcceptNativeSelection
        onAcceptNativeSelection = nil
        callback?(page, window)
        guard canAdoptPage(page, in: window), nativeSelectedPage === page,
              nativeSelectedWindow == window.id else { return false }
        nativeHeaderPage = page as? NativeTestPage
        return true
    }
    func isNativeSelection(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        canAdoptPage(page, in: window) && nativeSelectedPage === page &&
            nativeSelectedWindow == window.id && nativeHeaderPage === page
    }
    var admitSplit = true
    var splitCount = 0
    var actualSplit: SplitRecord?
    var actualSplitActive: UUID?
    var onSplit: (() -> Void)?
    func applySplit(_ record: SplitRecord?, replacing previous: SplitRecord?,
                    pages: [UUID: PageSession], activeItemID: UUID?,
                    in window: BrowserWindowState, isCurrent: () -> Bool) -> Bool {
        splitCount += 1
        let callback = onSplit; onSplit = nil; callback?()
        guard admitSplit, isCurrent() else { return false }
        actualSplit = record; actualSplitActive = activeItemID
        if let activeItemID, let page = pages[activeItemID]?.navigation as? NativeTestPage {
            nativeSelectedPage = page; nativeSelectedWindow = window.id; nativeHeaderPage = page
        }
        return true
    }
    func isSplit(_ record: SplitRecord?, pages: [UUID: PageSession],
                 activeItemID: UUID?, in window: BrowserWindowState) -> Bool {
        actualSplit == record && actualSplitActive == activeItemID
    }
    var onClose: (() -> Void)?
    func closePage(_ page: any PageNavigation, completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        closes.append(Closing(page: page as! NativeTestPage, completion: completion))
        onClose?()
    }
    func closePage(_ page: any PageNavigation, showing successor: any PageNavigation,
                   completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        closes.append(Closing(page: page as! NativeTestPage, successor: successor as? NativeTestPage,
                              completion: completion))
        onClose?()
    }
    @discardableResult func finishCreate(_ index: Int, loading: Bool = false) -> NativeTestPage {
        let request = creates[index]
        let page = NativeTestPage(profileID: request.profileID)
        if loading { page.state = PageNavigationState(url: URL(string: "about:blank"), isLoading: true,
                                                      canGoBack: false, canGoForward: false) }
        let done = request.completion
        request.completion = nil
        done?(.success(page))
        return page
    }
    func failCreate(_ index: Int) {
        let request = creates[index]
        let done = request.completion
        request.completion = nil
        done?(.failure(URLError(.cancelled)))
    }
    func finishOwnerEnd(_ index: Int, eventFirst: Bool) {
        let request = closes[index]
        let done = request.completion
        request.completion = nil
        let event = request.page.onEvent
        if eventFirst { event?(.ownerEnded) }
        done?(.ownerEnded)
        if !eventFirst { event?(.ownerEnded) }
    }
    func finishClose(_ index: Int, admitted: Bool) {
        let request = closes[index]
        let done = request.completion
        request.completion = nil
        if admitted { request.page.onEvent?(.closed) }
        done?(admitted ? .closed : .cancelled)
    }
}

@MainActor
private final class NativeTestPage: PageNavigation, VaultNativePage {
    var passkeyCallback: (@MainActor (VaultNativePasskeyRequest?) -> Void)?
    var passkeyValid = false
    var passkeySerial: UInt64 = 0
    var passkeyReplies: [(UInt64,String?)] = []
    func observeVaultPasskeys(_ callback: (@MainActor (VaultNativePasskeyRequest?) -> Void)?) {
        passkeyCallback = callback
    }
    func vaultPasskeyIsCurrent(_ token: UInt64) -> Bool { passkeyValid && passkeySerial == token }
    func completeVaultPasskey(_ token: UInt64, result: String?) -> Bool {
        guard token == passkeySerial else { return false }
        let current = passkeyValid; passkeyValid = false
        passkeyReplies.append((token,current ? result : nil)); return current
    }
    private lazy var vaultWindow: NSWindow = {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:640,height:480),
            styleMask:.borderless,backing:.buffered,defer:true)
        window.isReleasedWhenClosed = false
        return window
    }()
    private func mountVaultView() {
        if vaultView.window == nil { vaultWindow.contentView?.addSubview(vaultView) }
        precondition(vaultView.window != nil)
    }
    func requestPasskey(operation:Int32,badHash:Bool = false,emptyAllow:Bool = false,allowed:[String] = ["AQ"]) {
        mountVaultView()
        passkeySerial += 1; passkeyValid = true
        let args: [String:Any] = ["rpId":"vault.synthetic.invalid","rpName":"Synthetic",
            "origin":"https://vault.synthetic.invalid", "clientDataHash":badHash ? "AQ" : Base64URL.encode(Data(repeating:0,count:32)),
            "user":["id":"AQ","name":"synthetic-user","displayName":"Synthetic"],
            "pubKeyCredParams":[-7],"excludeCredentials":[],"allowCredentials":emptyAllow ? [] : allowed]
        let json = String(data:try! JSONSerialization.data(withJSONObject:args),encoding:.utf8)!
        passkeyCallback?(VaultNativePasskeyRequest(token:passkeySerial,operation:operation,arguments:json,view:vaultView))
    }
    var vaultSave: (@MainActor (VaultNativeSubmission?) -> Void)?
    var vaultSaveSerial: UInt64 = 0
    var vaultSaveValid = false
    func observeVaultSave(_ callback: (@MainActor (VaultNativeSubmission?) -> Void)?) {
        vaultSave = callback; vaultSaveValid = false
    }
    func vaultSaveIsCurrent(_ token: UInt64) -> Bool { vaultSaveValid && token == vaultSaveSerial }
    func cancelVaultSave(_ token: UInt64) { if token == vaultSaveSerial { vaultSaveValid = false } }
    func submitVault(username: String = "new-synthetic-user") {
        mountVaultView()
        vaultSaveSerial += 1; vaultSaveValid = true
        vaultSave?(VaultNativeSubmission(token:vaultSaveSerial,origin:"https://vault.synthetic.invalid",
            username:username,password:"typed-synthetic-password",view:vaultView))
    }
    var vaultProfileOverride: UUID?
    var vaultProfileID: UUID? { vaultProfileOverride ?? profileID }
    var vaultFocus: (@MainActor (VaultNativeFocus?) -> Void)?
    var vaultCurrent = false
    var vaultDocumentCurrent = false
    var vaultSerial: UInt64 = 0
    func vaultFieldIsCurrent(_ token: UInt64) -> Bool { vaultDocumentCurrent && token == vaultSerial }
    func cancelVaultFocus(_ token: UInt64) { if token == vaultSerial { vaultDocumentCurrent = false; vaultCurrent = false } }
    var vaultFills: [(UInt64, String, String)] = []
    let vaultView = NSView(frame: CGRect(x:0,y:0,width:640,height:480))
    func observeVault(_ callback: (@MainActor (VaultNativeFocus?) -> Void)?) {
        // Chromium retires the existing field token when its observer is replaced.
        vaultCurrent = false
        vaultDocumentCurrent = false
        vaultFocus = callback
    }
    func vaultFocusIsCurrent(_ token: UInt64) -> Bool { vaultCurrent && vaultFieldIsCurrent(token) }
    func fillVault(_ token: UInt64, username: String, secret: String) -> Bool {
        guard vaultFocusIsCurrent(token) else { return false }
        vaultCurrent = false; vaultFills.append((token,username,secret)); return true
    }
    func focusVault(code: Bool = false, origin: String = "https://vault.synthetic.invalid") {
        vaultCurrent = true; vaultDocumentCurrent = true; vaultSerial += 1
        mountVaultView()
        vaultFocus?(VaultNativeFocus(token:vaultSerial,origin:origin,isCode:code,view:vaultView,anchor:CGRect(x:10,y:10,width:150,height:24)))
    }

    var blockingPolicies: [ContentBlockerManager.NetworkPagePolicy] = []
    var acceptsBlockingPolicy = true
    func applyBlockingPolicy(_ policy: ContentBlockerManager.NetworkPagePolicy) -> Bool {
        blockingPolicies.append(policy); return acceptsBlockingPolicy
    }
    var pageTextCaptures = 0
    var holdPageText = false
    var onPageTextCapture: (() -> Void)?
    var pendingPageText: CheckedContinuation<(title: String, body: String)?, Never>?
    private var capturedText: (title: String, body: String) {
        ("Article", String(repeating: "chromiummarker ", count: 20))
    }
    func capturePageText() async -> (title: String, body: String)? {
        pageTextCaptures += 1
        if !holdPageText { return capturedText }
        return await withCheckedContinuation { completion in
            pendingPageText = completion
            let started = onPageTextCapture; onPageTextCapture = nil; started?()
        }
    }
    func completePageText() {
        let pending = pendingPageText; pendingPageText = nil
        pending?.resume(returning: capturedText)
    }

    var acceptsCacheFlush = true
    var cacheFlushes = 0
    func clearBackForwardCache() -> Bool { cacheFlushes += 1; return acceptsCacheFlush }

    let profileID: UUID?
    private var snapshot = PageNavigationState(url: URL(string: "about:blank")!, canGoBack: false, canGoForward: false)
    var onReadState: (() -> Void)?
    var state: PageNavigationState {
        get {
            let callback = onReadState
            onReadState = nil
            callback?()
            return snapshot
        }
        set { snapshot = newValue }
    }
    var onStateChanged: ((PageNavigationState) -> Void)?
    var onEvent: ((PageNavigationEvent) -> Void)?
    var searched: [String] = []
    var searchTokens: [String?] = []
    func search(_ query: String, kagiSessionToken: String?) -> Bool {
        searched.append(query); searchTokens.append(kagiSessionToken); return true
    }
    var loaded: [URL] = []
    var allowsThumbnails = false
    var onCapture: (() -> Void)?
    var thumbnailCompletions: [@MainActor (Data?) -> Void] = []
    func captureThumbnail(completion: @escaping @MainActor (Data?) -> Void) -> Bool {
        guard allowsThumbnails else { return false }
        thumbnailCompletions.append(completion)
        let callback = onCapture; onCapture = nil; callback?()
        return true
    }
    var supportsTranslation = false
    var onTranslationNodes: (([PageTranslationNode]?) -> Void)?
    var translations: [(command: PageTranslationCommand, completion: @MainActor (PageTranslationResult?) -> Void)] = []
    func translate(_ command: PageTranslationCommand,
                   completion: @escaping @MainActor (PageTranslationResult?) -> Void) -> Bool {
        guard supportsTranslation, !invalidated else { return false }
        translations.append((command, completion)); return true
    }
    var supportsUserCSS = false
    var completeStyles = true
    var supportsElementPicker = false
    var picks: [CheckedContinuation<String?, Never>] = []
    var pickerCancels = 0
    func pickElement() async -> String? {
        await withCheckedContinuation { picks.append($0) }
    }
    func cancelElementPicker() { pickerCancels += 1 }
    var styles: [(css: String, url: URL, completion: @MainActor (Bool) -> Void)] = []
    func setUserCSS(_ css: String, for committedURL: URL,
                    completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard supportsUserCSS, !invalidated else { return false }
        styles.append((css, committedURL, completion))
        if completeStyles { completion(true) }
        return true
    }
    var playbackRequests: [Bool] = []
    var trackRequests: [Bool] = []
    func setPlaybackPaused(_ paused: Bool) -> Bool { playbackRequests.append(paused); return false }
    func skipTrack(forward: Bool) -> Bool { trackRequests.append(forward); return false }
    var allowsPiP = false
    var pipRequests = 0
    func requestPictureInPicture() -> Bool { pipRequests += 1; return allowsPiP && !invalidated }
    var invalidated = false
    var stops = 0
    init(profileID: UUID) { self.profileID = profileID }
    func load(_ url: URL) { loaded.append(url) }
    func goBack() -> Bool { false }
    func goForward() -> Bool { false }
    var blockerReloads = 0
    var reloadResult = false
    var onReload: (() -> Void)?
    func reload() -> Bool { blockerReloads += 1; onReload?(); return reloadResult }
    func stop() { stops += 1 }
    func invalidate() { invalidated = true; onStateChanged = nil; onEvent = nil }
}
#endif

@MainActor
private final class NativeOnlyPageDelegate: PageSessionDelegate {
    var currentProfile: Profile? { nil }
    private(set) var cleanedZoom: [UUID] = []
    func windowSpaceChanged(_ window: BrowserWindowState) {}
    func presentPeek(url: URL, from session: PageSession) {}
    func cleanupZoom(for itemID: UUID) { cleanedZoom.append(itemID) }
    func setMuteState(_ muted: Bool, for itemID: UUID) {}
}
