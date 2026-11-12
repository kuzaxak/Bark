// Licensed under GPL-3.0. See LICENSE.
import BarcChromium
import Foundation
import NookBlocker
import NookWeb

/// Compile with the actual PageNavigation.swift contract and app adapter.
/// Exercises ownership/callback ordering without a browser or user data.
@MainActor
private enum Native {
    static let profile = UUID(uuidString: "9fc28221-b340-4c80-94ef-89a2cf4db441")!
    static var callback: BarcTabCallback?
    static var context: UnsafeMutableRawPointer?
    static var observed = 0
    static var cancelled: [UInt64] = []
    static var commands: [(String, Int32, Int32)] = []
    static var mediaCallback: BarcMediaCallback?
    static var enableMedia = false
    static var mediaActions: [(Int32, Int32, Int32)] = []
    static var acceptsMedia = true
    static var acceptsCommands = true
    static var acceptsObserver = true
    static var pageCommands: [(Int32, Int32, Int32)] = []
    static var thumbnailCallback: BarcTabThumbnailCallback?
    static var fileCalls: [(UInt64, String, String, BarcFileCallback?)] = []
    static var fileCancelled: [UInt64] = []
    static var acceptsFile = true
    static var returnedProfile: UUID?
    static var screenshotWidths: [Int32] = []
    static var captureCancelled: [UInt64] = []
    static var thumbnailRequest: UInt64 = 0
    static var thumbnailAccepts = true
    static var siteDataCallback: BarcSiteDataCallback?
    static var siteDataRequest: UInt64 = 0
    static var siteDataActions: [Int32] = []
    static var acceptsSiteData = true
    static var muteRequests: [(Int32, Int32, Int32)] = []
    static var styles: [(request: UInt64, url: String, css: String, callback: BarcStyleCallback?)] = []
    static var acceptStyles = true
    static var peekRequests: [Int32] = []
    static var peekCapabilities: [Int32] = []
    static var translationCalls: [(generation: UInt64, request: UInt64, operation: Int32,
        payload: String, callback: BarcTranslationCallback?)] = []
    static var acceptsTranslation = true
    static var scriptCalls: [(request: UInt64, mode: Int32, world: Int32, source: String,
        callback: BarcScriptCallback?)] = []
    static var scriptCancelled: [UInt64] = []
    static var pickerCalls: [(UInt64, BarcPickerCallback?)] = []
    static var pickerCancelled: [UInt64] = []
    static func pickReply(_ index: Int, _ selector: String) {
        let call = pickerCalls[index]
        selector.withCString { call.1?(context, 41, call.0, $0, selector.utf8.count) }
    }
    static var acceptsScript = true
    static var policies: [(Int32, Int32, Int32, String?, UInt64)] = []
    static var acceptsPolicy = true
    static func scriptReply(_ index: Int, status: Int32, text: String = "", json: String = "", isString: Bool = false) {
        let call = scriptCalls[index]
        let strlenSafeLength = text.utf8.count, jsonSafeLength = json.utf8.count
        text.withCString { text in json.withCString { json in
            call.callback?(context, 41, call.request, status, text, strlenSafeLength, json, jsonSafeLength, isString ? 1 : 0)
        } }
    }



    static func reset() {
        fileCalls = [];fileCancelled = [];acceptsFile = true
        returnedProfile = nil; screenshotWidths = []; captureCancelled = []
        policies = []; acceptsPolicy = true
        scriptCalls = []; scriptCancelled = []; acceptsScript = true
        pickerCalls = []; pickerCancelled = []
        callback = nil; context = nil; observed = 0; cancelled = []; commands = []
        acceptsCommands = true; acceptsObserver = true; pageCommands = []; muteRequests = []
        mediaCallback = nil; enableMedia = false; mediaActions = []; acceptsMedia = true
        styles = []; acceptStyles = true; peekRequests = []; peekCapabilities = []; translationCalls = []; acceptsTranslation = true
    }

    static func emit(_ event: Int32, window: Int32 = 10, tab: Int32 = 20,
                     url: String = "https://fixture.test/committed", title: String = "Fixture",
                     error: Int32 = 0, flags: UInt32 = 0) {
        url.withCString { url in
            title.withCString { title in
                callback?(context, 41, event, window, tab, url, title, error, flags)
            }
        }
    }

    static func command(_ name: String, _ window: Int32, _ tab: Int32) -> Int32 {
        commands.append((name, window, tab))
        return acceptsCommands ? 1 : 0
    }

    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.tab_observe = { _, _, callback, context in
            MainActor.assumeIsolated {
                Native.observed += 1
                guard Native.acceptsObserver else { return 0 }
                Native.callback = callback; Native.context = context
                Native.emit(0, flags: 2 | 4096)
                return 41
            }
        }
        bridge.tab_unobserve = { token in MainActor.assumeIsolated { Native.cancelled.append(token) } }
        bridge.tab_navigate = { window, tab, url in
            MainActor.assumeIsolated { Native.command(String(cString: url!), window, tab) }
        }
        bridge.tab_go_back = { window, tab in MainActor.assumeIsolated { Native.command("back", window, tab) } }
        bridge.tab_go_forward = { window, tab in MainActor.assumeIsolated { Native.command("forward", window, tab) } }
        bridge.tab_reload = { window, tab in MainActor.assumeIsolated { Native.command("reload", window, tab) } }
        bridge.tab_stop = { window, tab in MainActor.assumeIsolated { Native.command("stop", window, tab) } }
        bridge.tab_select = { window, tab in MainActor.assumeIsolated { Native.command("select", window, tab) } }
        bridge.tab_close = { window, tab in MainActor.assumeIsolated { Native.command("close", window, tab) } }
        bridge.tab_capture_thumbnail = { _, request, callback in MainActor.assumeIsolated {
            Native.thumbnailRequest = request; Native.thumbnailCallback = callback
            return Native.thumbnailAccepts ? 1 : 0
        } }
        bridge.tab_clear_site_data = { _, request, action, callback in MainActor.assumeIsolated {
            Native.siteDataRequest = request; Native.siteDataActions.append(action)
            Native.siteDataCallback = callback; return Native.acceptsSiteData ? 1 : 0
        } }
        bridge.window_profile_uuid = { _, buffer, capacity in
            MainActor.assumeIsolated {
                let bytes = Array((Native.returnedProfile ?? Native.profile).uuidString.lowercased().utf8CString)
                if let buffer, capacity >= bytes.count {
                    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                }
                return bytes.count
            }
        }
        bridge.window_private_session_uuid = { _, _, _ in 0 }
        bridge.tab_download_file = { _, request, url, directory, callback in MainActor.assumeIsolated {
            Native.fileCalls.append((request,String(cString:url!),String(cString:directory!),callback))
            return Native.acceptsFile ? 1:0
        } }
        bridge.tab_cancel_file = { _, request in MainActor.assumeIsolated { Native.fileCancelled.append(request);return 1 } }
        bridge.tab_capture_screenshot = { _, request, width, callback in MainActor.assumeIsolated {
            Native.screenshotWidths.append(width)
            Native.thumbnailRequest = request; Native.thumbnailCallback = callback
            return Native.thumbnailAccepts ? 1 : 0
        } }
        bridge.tab_cancel_capture = { _, request in MainActor.assumeIsolated {
            Native.captureCancelled.append(request); return 1
        } }
        bridge.tab_execute_command = { window, tab, command in MainActor.assumeIsolated {
            Native.pageCommands.append((window, tab, command)); return Native.acceptsCommands ? 1 : 0
        } }
        bridge.tab_set_muted = { window, tab, muted in MainActor.assumeIsolated {
            Native.muteRequests.append((window, tab, muted)); return Native.acceptsCommands ? 1 : 0
        } }
        bridge.tab_observe_media = { _, callback in MainActor.assumeIsolated {
            guard Native.enableMedia else { return 1 }
            Native.mediaCallback = callback; return Native.acceptsMedia ? 1 : 0
        } }
        bridge.tab_media_action = { window, tab, action in MainActor.assumeIsolated {
            Native.mediaActions.append((window, tab, action)); return Native.acceptsCommands ? 1 : 0
        } }
        bridge.tab_set_user_css = { _, request, url, css, callback in MainActor.assumeIsolated {
            Native.styles.append((request, url.map(String.init(cString:)) ?? "", css.map(String.init(cString:)) ?? "", callback))
            return Native.acceptStyles ? 1 : 0
        } }
        bridge.tab_translate = { _, generation, request, operation, pairs, callback in MainActor.assumeIsolated {
            Native.translationCalls.append((generation, request, operation,
                pairs.map(String.init(cString:)) ?? "", callback))
            return Native.acceptsTranslation ? 1 : 0
        } }
        bridge.tab_evaluate_script = { _, request, mode, world, source, callback in MainActor.assumeIsolated {
            Native.scriptCalls.append((request, mode, world, source.map(String.init(cString:)) ?? "", callback))
            return Native.acceptsScript ? 1 : 0
        } }
        bridge.tab_cancel_script = { _, request in MainActor.assumeIsolated {
            Native.scriptCancelled.append(request); return 1
        } }
        bridge.tab_start_boost_picker = { _, request, callback in MainActor.assumeIsolated {
            Native.pickerCalls.append((request, callback)); return 1
        } }
        bridge.tab_cancel_boost_picker = { _, request in MainActor.assumeIsolated {
            Native.pickerCancelled.append(request); return 1
        } }
        bridge.tab_create_peek = { observation, request, admission, context in MainActor.assumeIsolated {
            precondition(observation == 41)
            Native.peekRequests.append(request)
            return admission?(context, 12, 30) ?? 0
        } }
        bridge.tab_enable_peek = { token, enabled in MainActor.assumeIsolated {
            precondition(token == 41); Native.peekCapabilities.append(enabled); return 1
        } }
        bridge.blocker_set_tab_policy = { window, tab, oauth, host, milliseconds in MainActor.assumeIsolated {
            Native.policies.append((window, tab, oauth, host.map(String.init(cString:)), milliseconds))
            return Native.acceptsPolicy ? 1 : 0
        } }
        bridge.tab_observe_vault = { _, _ in 1 }
        bridge.tab_observe_vault_save = { _, _ in 1 }
        bridge.tab_observe_vault_passkeys = { _, _ in 1 }
        return bridge
    }

    static func emitMedia(_ flags: UInt32, window: Int32 = 10, title: String = "Track",
                          artist: String = "Artist", album: String = "Album") {
        title.withCString { title in artist.withCString { artist in album.withCString { album in
            mediaCallback?(context, 41, window, 20, flags, title, artist, album)
        } } }
    }

    static func page() throws -> ChromiumPageNavigation {
        try ChromiumPageNavigation(profileID: profile, window: 10, tab: 20, bridge: bridge)
    }
}

@MainActor
private enum SearchNative {
    static var asksForSeed = true
    static var calls: [(String, Int32, Int32, Bool, Bool)] = []
    static var commands: [(Int32, Int32, String, String?)] = []
    static let state = ProfileSearchState(version: "v", selected: "native", name: "Native", controlled: false,
        managed: false, providers: [], suggestions: "kagi", kagiSession: true)
    static var api: ChromiumProfileSearch {
        var bridge = trappingBridge
        bridge.profile_search_state = { uuid, owner, kind, seed, selection, choices, callback, context in
            MainActor.assumeIsolated {
                SearchNative.calls.append((String(cString: uuid!), owner, kind, seed != nil, choices != 0))
                if SearchNative.asksForSeed && seed == nil { callback?(context, Int32(BARC_SEARCH_NEEDS_SEED.rawValue), nil); return }
                SearchNative.asksForSeed = false
                let json = String(data: try! JSONEncoder().encode(SearchNative.state), encoding: .utf8)!
                json.withCString { callback?(context, Int32(BARC_SEARCH_OK.rawValue), $0) }
            }
        }
        return ChromiumProfileSearch(bridge: bridge)
    }
}

@MainActor private func drainMain() async {
    for _ in 0..<4 { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
}

@main
private enum NavigationChecks {
    @MainActor static func main() async throws {
        Native.reset()
        do {
            _ = try ChromiumPageNavigation(profileID: UUID(), window: 10, tab: 20, bridge: Native.bridge)
            preconditionFailure("A mislabeled native profile was admitted")
        } catch ChromiumNavigationError.profileMismatch {}
        precondition(Native.observed == 0)

        var page: ChromiumPageNavigation? = try Native.page()
        precondition(page?.state.title == "Fixture" && page?.state.canGoBack == true)
        precondition(page?.state.url?.path == "/committed" && page?.state.isLoading == false)
        precondition(page!.performNativePageCommand(.find))
        precondition(Native.pageCommands.last?.2 == 0 && Native.pageCommands.count == 1)
        precondition(ShortcutAction.pickElement.pageCommand == .pickElement && PageCommand.pickElement.supportsNativePage)
        precondition(page!.performNativePageCommand(.pickElement))
        precondition(Native.pageCommands.last?.2 == 9 && Native.pageCommands.last?.0 == 10 && Native.pageCommands.last?.1 == 20)
        precondition(page!.state.hasVideoPictureInPicture == false && page!.state.hasDocumentPictureInPicture == false)
        precondition(page!.performNativePageCommand(.pictureInPicture) && Native.pageCommands.last?.2 == 10)
        precondition(page!.state.hasVideoPictureInPicture == false, "Accepted dispatch invented active PiP")
        Native.emit(6, flags: 1024 | 4096)
        precondition(page!.state.hasVideoPictureInPicture == true && page!.state.hasDocumentPictureInPicture == false)
        Native.emit(6, flags: 2048 | 4096)
        precondition(page!.state.hasVideoPictureInPicture == false && page!.state.hasDocumentPictureInPicture == true)
        Native.emit(6)
        precondition(page!.state.hasVideoPictureInPicture == nil && page!.state.hasDocumentPictureInPicture == nil)
        Native.emit(6, flags: 4096)
        for panel in [PageCommand.developerConsole, .developerNetwork, .developerPerformance] {
            Native.acceptsCommands = false
            precondition(!page!.performNativePageCommand(panel), "Native panel refusal must propagate")
            precondition(Native.pageCommands.last?.0 == 10 && Native.pageCommands.last?.1 == 20)
            Native.acceptsCommands = true
            precondition(page!.performNativePageCommand(panel))
        }
        Native.acceptsCommands = false
        precondition(!page!.requestPictureInPicture())
        precondition(!page!.performNativePageCommand(.pickElement))
        precondition(!page!.performNativePageCommand(.print))
        precondition(!page!.setAudioMuted(true) && page!.state.isAudioMuted == false)
        Native.acceptsCommands = true
        precondition(page!.setAudioMuted(true) && page!.state.isAudioMuted == false,
                     "Dispatch acceptance is not mute state")
        Native.emit(6, flags: 256 | 512)
        precondition(page!.state.isAudioMuted == true && page!.state.isAudible == true)
        precondition(page!.performNativePageCommand(.hardReload) && Native.pageCommands.last?.2 == 8)
        let commandsBeforeCacheFlush = Native.commands.count
        let stateBeforeCacheFlush = page!.state
        let ownerBeforeCacheFlush = page!.nativeWindowID, tabBeforeCacheFlush = page!.nativeTabID
        precondition(page!.clearBackForwardCache() && Native.pageCommands.last?.2 == 11)
        precondition(Native.pageCommands.last?.0 == ownerBeforeCacheFlush && Native.pageCommands.last?.1 == tabBeforeCacheFlush)
        Native.acceptsCommands = false
        precondition(!page!.clearBackForwardCache())
        Native.acceptsCommands = true
        precondition(Native.commands.count == commandsBeforeCacheFlush && page!.state == stateBeforeCacheFlush)

        var events: [PageNavigationEvent] = []
        page?.onEvent = { events.append($0) }
        Native.emit(6, window: 11, flags: 6)
        precondition(events.isEmpty, "A binding/state snapshot invented a visit")
        precondition(page!.performNativePageCommand(.zoomIn))
        precondition(Native.pageCommands.last?.0 == 11 && Native.pageCommands.last?.1 == 20)
        precondition(page!.setAudioMuted(false) && Native.muteRequests.last?.0 == 11)
        precondition(page!.goBack() && page!.goForward() && page!.reload())
        page?.load(URL(string: "https://fixture.test/new")!)
        page?.stop()
        precondition(Native.commands.map { $0.0 } == ["back", "forward", "reload", "https://fixture.test/new", "stop"])
        precondition(Native.commands.allSatisfy { $0.1 == 11 && $0.2 == 20 })
        Native.acceptsCommands = false
        precondition(!page!.reload())
        page?.load(URL(string: "https://fixture.test/rejected")!)
        guard case .failed(_, provisional: true, committedURL: let retained) = events.last else {
            preconditionFailure("A rejected command left the page loading")
        }
        precondition(retained?.path == "/committed")
        events.removeAll()

        Native.emit(2, window: 11, url: "https://fixture.test/committed#section", flags: 16)
        guard case .committed(let url, sameDocument: true) = events.last else {
            preconditionFailure("Same-document identity was lost")
        }
        precondition(url?.fragment == "section")
        Native.emit(4, window: 11, error: -3, flags: 32 | 64)
        guard case .cancelled(committedURL: let displayed) = events.last else {
            preconditionFailure("Cancellation became a user-visible failure")
        }
        precondition(displayed?.path == "/committed")
        Native.emit(4, window: 11, error: -105, flags: 32)
        guard case .failed(let error, provisional: true, committedURL: let committed) = events.last else {
            preconditionFailure("Navigation failure lost its lifecycle")
        }
        precondition((error as NSError).code == -105 && committed?.path == "/committed")

        Native.emit(7, window: 11)
        precondition(events.count == 3 && page!.isClosed, "CLOSED reaches the app after the native callback returns")
        await drainMain()
        precondition(events.count == 4)
        guard case .closed = events.last else { preconditionFailure("Missing close notification") }
        precondition(!page!.goBack())
        let commandsAfterClose = Native.pageCommands.count, muteAfterClose = Native.muteRequests.count
        precondition(!page!.performNativePageCommand(.webInspector) && !page!.performNativePageCommand(.pickElement) && !page!.requestPictureInPicture() && !page!.setAudioMuted(true))
        precondition(!page!.clearBackForwardCache())
        precondition(Native.pageCommands.count == commandsAfterClose && Native.muteRequests.count == muteAfterClose)
        Native.emit(3, window: 11)
        precondition(events.count == 4, "A closed page was revived")
        page = nil
        precondition(Native.cancelled.isEmpty, "Terminal close double-unsubscribed")

        Native.reset()
        page = try Native.page()
        events = []
        page?.onEvent = { events.append($0) }
        page?.onStateChanged = { [weak page] _ in page?.invalidate() }
        Native.emit(2, flags: 3)
        precondition(events.isEmpty, "Lifecycle callout continued after reentrant invalidation")
        precondition(Native.cancelled == [41])
        page?.invalidate()
        page = nil
        precondition(Native.cancelled == [41])

        Native.reset()
        page = try Native.page()
        weak var released = page
        page = nil
        precondition(released == nil && Native.cancelled == [41], "Observation retained its page")
        released = nil

        Native.reset()
        Native.acceptsObserver = false
        do {
            _ = try Native.page()
            preconditionFailure("Rejected observation was usable")
        } catch ChromiumNavigationError.observationRejected {}
        precondition(Native.cancelled.isEmpty)
        Native.reset()
        page = try Native.page()
        let sourceState = page!.state
        var peekLinks: [URL] = []
        page!.onEvent = { if case .peekRequested(let url) = $0 { peekLinks.append(url) } }
        Native.emit(9, url: "https://fixture.test/disabled", error: 1)
        precondition(peekLinks.isEmpty && Native.peekCapabilities.isEmpty)
        precondition(page!.setNativePeekCapability(true))
        Native.emit(9, url: "https://fixture.test/peek", title: "Not the source title", error: 1, flags: 1)
        precondition(peekLinks == [URL(string: "https://fixture.test/peek")!] && page!.state == sourceState,
                     "Peek intent mutated the source navigation snapshot")
        Native.emit(9, url: "https://fixture.test/rejected", error: 0)
        precondition(peekLinks.count == 1)
        precondition(page!.createNativePeek(request: 1, admission: { _, _, _ in 1 }, context: nil))
        precondition(!page!.createNativePeek(request: 1, admission: { _, _, _ in 1 }, context: nil) && Native.peekRequests == [1])
        Native.emit(9, error: 2)
        let dismissingOldPeek = page!.pendingPeekRequestID!
        Native.emit(9, error: 3)
        precondition(!page!.createNativePeek(request: dismissingOldPeek, admission: { _, _, _ in 1 }, context: nil),
                     "Old dismissal consumed a newer Peek request")
        precondition(page!.pendingPeekRequestID == 3 && Native.peekRequests == [1])
        Native.emit(1)
        precondition(!page!.createNativePeek(request: 1, admission: { _, _, _ in 1 }, context: nil))
        Native.emit(9, error: 3)
        Native.emit(6, window: 12)
        precondition(!page!.createNativePeek(request: 1, admission: { _, _, _ in 1 }, context: nil))
        page!.invalidate()
        Native.reset()
        page = try Native.page()
        var outcomes: [PageCloseOutcome] = []
        var order: [String] = []
        page!.onNativeCloseOutcome = { admitted in
            outcomes.append(admitted)
            if admitted == .closed { order.append("host"); page?.invalidate() }
        }
        page!.onEvent = { event in if case .closed = event { order.append("page") } }
        Native.emit(6, window: 12)
        precondition(page!.selectNativePage())
        precondition(Native.commands.last?.1 == 12)
        precondition(page!.requestPictureInPicture() && Native.pageCommands.last?.0 == 12 && Native.pageCommands.last?.2 == 10)
        precondition(page!.performNativePageCommand(.pickElement) && Native.pageCommands.last?.0 == 12 && Native.pageCommands.last?.1 == 20 && Native.pageCommands.last?.2 == 9)
        precondition(page!.requestNativeClose())
        precondition(outcomes.isEmpty, "Dispatch acceptance completed close")
        Native.emit(8, window: 12)
        precondition(outcomes == [.cancelled] && page!.goBack())
        precondition(page!.requestNativeClose())
        Native.emit(7, window: 12)
        precondition(outcomes == [.cancelled] && page!.isClosed)
        await drainMain()
        precondition(outcomes == [.cancelled, .closed] && order == ["host", "page"])
        precondition(page!.isClosed && !page!.requestNativeClose())
        Native.emit(7, window: 12)
        precondition(outcomes.count == 2 && Native.cancelled.isEmpty)
        page = try Native.page()
        var ownerOrder: [String] = []
        page!.onNativeCloseOutcome = {
            precondition($0 == .ownerEnded)
            ownerOrder.append("host")
        }
        page!.onEvent = {
            if case .ownerEnded = $0 { ownerOrder.append("page") }
            else { preconditionFailure("Owner teardown was reported as tab deletion") }
        }
        Native.emit(7, flags: 128)
        precondition(ownerOrder == ["host", "page"] && page!.nativeCloseOutcome == .ownerEnded)

        page = nil

        Native.reset()
        let thumbnailPage = try Native.page()
        var thumbnailResults: [Data?] = []
        precondition(thumbnailPage.captureThumbnail { thumbnailResults.append($0) })
        precondition(!thumbnailPage.captureThumbnail { _ in preconditionFailure() })
        let firstCapture = Native.thumbnailCallback, firstRequest = Native.thumbnailRequest
        Native.emit(1)
        precondition(thumbnailResults.count == 1 && thumbnailResults[0] == nil)
        firstCapture?(Native.context, 41, firstRequest, nil, 0)
        precondition(thumbnailResults.count == 1)
        precondition(thumbnailPage.captureThumbnail { thumbnailResults.append($0) })
        let secondRequest = Native.thumbnailRequest
        let png = Data([137, 80, 78, 71])
        png.withUnsafeBytes { bytes in
            firstCapture?(Native.context, 41, firstRequest, bytes.bindMemory(to: UInt8.self).baseAddress, png.count)
            precondition(thumbnailResults.count == 1)
            Native.thumbnailCallback?(Native.context, 41, secondRequest, bytes.bindMemory(to: UInt8.self).baseAddress, png.count)
        }
        precondition(thumbnailResults.count == 2 && thumbnailResults[1] == png)
        precondition(thumbnailPage.captureThumbnail { thumbnailResults.append($0) })
        let transferCapture = Native.thumbnailCallback, transferRequest = Native.thumbnailRequest
        Native.emit(0, window: 11)
        precondition(thumbnailResults.count == 3 && thumbnailResults[2] == nil)
        transferCapture?(Native.context, 41, transferRequest, nil, 0)
        precondition(thumbnailResults.count == 3)
        precondition(thumbnailPage.captureThumbnail { thumbnailResults.append($0) })
        let stoppedCapture = Native.thumbnailCallback, stoppedRequest = Native.thumbnailRequest
        let stoppedContext = Native.context
        thumbnailPage.invalidate()
        precondition(thumbnailResults.count == 4 && thumbnailResults[3] == nil)
        stoppedCapture?(stoppedContext, 41, stoppedRequest, nil, 0)
        precondition(thumbnailResults.count == 4)
        Native.reset()
        let screenshotPage = try Native.page()
        for width in [Double.nan, .infinity, 0, -1, 1.5, 4097] {
            do { _ = try await screenshotPage.captureScreenshot(maxWidth: width); preconditionFailure() }
            catch ChromiumNavigationError.screenshotBounds {} catch { preconditionFailure() }
        }
        precondition(Native.screenshotWidths.isEmpty)
        let jpeg = Data([255, 216, 255, 217])
        let screenshot = Task { try await screenshotPage.captureScreenshot() }
        await Task.yield()
        precondition(Native.screenshotWidths == [1200])
        precondition(!screenshotPage.captureThumbnail { _ in preconditionFailure() })
        let firstScreenshot = Native.thumbnailRequest
        jpeg.withUnsafeBytes { bytes in
            Native.thumbnailCallback?(Native.context, 41, firstScreenshot,
                bytes.bindMemory(to: UInt8.self).baseAddress, jpeg.count)
        }
        let screenshotBytes = try await screenshot.value
        precondition(screenshotBytes == jpeg)
        for event in [1, 2, 0, 7] {
            let task = Task { try await screenshotPage.captureScreenshot(maxWidth: 2048) }
            await Task.yield()
            let oldRequest = Native.thumbnailRequest, oldCallback = Native.thumbnailCallback
            Native.emit(Int32(event), window: event == 0 ? 11 : 10)
            do { _ = try await task.value; preconditionFailure() } catch {}
            precondition(Native.captureCancelled.contains(oldRequest))
            oldCallback?(Native.context, 41, oldRequest, nil, 0)
            if event == 7 { break }
        }
        Native.reset()
        let cancellationPage = try Native.page()
        let cancelledCapture = Task { try await cancellationPage.captureScreenshot() }
        await Task.yield()
        let cancelledID = Native.thumbnailRequest, cancelledCallback = Native.thumbnailCallback
        cancelledCapture.cancel()
        do { _ = try await cancelledCapture.value; preconditionFailure() } catch {}
        precondition(Native.captureCancelled == [cancelledID])
        let nextCapture = Task { try await cancellationPage.captureScreenshot(maxWidth: 4096) }
        await Task.yield()
        let nextID = Native.thumbnailRequest
        cancelledCallback?(Native.context, 41, cancelledID, nil, 0)
        jpeg.withUnsafeBytes { bytes in
            Native.thumbnailCallback?(Native.context, 41, nextID,
                bytes.bindMemory(to: UInt8.self).baseAddress, jpeg.count)
        }
        let nextBytes = try await nextCapture.value
        precondition(nextBytes == jpeg && Native.captureCancelled == [cancelledID])
        Native.thumbnailAccepts = false
        do { _ = try await cancellationPage.captureScreenshot(); preconditionFailure() } catch {}
        Native.thumbnailAccepts = true
        let tooLarge = Task { try await cancellationPage.captureScreenshot() }
        await Task.yield()
        jpeg.withUnsafeBytes { bytes in
            Native.thumbnailCallback?(Native.context, 41, Native.thumbnailRequest,
                bytes.bindMemory(to: UInt8.self).baseAddress, 8_388_609)
        }
        do { _ = try await tooLarge.value; preconditionFailure() } catch {}
        let wrongProfile = Task { try await cancellationPage.captureScreenshot() }
        await Task.yield()
        Native.returnedProfile = UUID()
        Native.emit(0, window: 12)
        precondition(cancellationPage.nativeWindowID == 10)
        // A foreign owner callback is rejected; the original native capture
        // completes unavailable after its own exact-membership revalidation.
        Native.thumbnailCallback?(Native.context, 41, Native.thumbnailRequest, nil, 0)
        do { _ = try await wrongProfile.value; preconditionFailure() } catch {}
        cancellationPage.invalidate()
        print("Native screenshot adapter:1200/JPEG,finite bounds,single slot,document/owner/profile/close,cancellation and stale callbacks passed")
        Native.reset()
        Native.reset()
        let filePage = try Native.page()
        let downloadURL = URL(string:"https://fixture.test/file.bin")!
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("devmcp-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let requests = (0..<6).map { _ in Task { try await filePage.downloadFile(downloadURL,directory:directory) } }
        for _ in 0..<8 { await Task.yield() }
        precondition(Native.fileCalls.count == 6)
        do { _ = try await filePage.downloadFile(downloadURL,directory:directory);preconditionFailure() } catch {}
        for (index,call) in Native.fileCalls.enumerated() {
            precondition(call.1 == downloadURL.absoluteString && call.2 == DevMCPFiles.nativeDirectory(directory)!.path)
            let path = DevMCPFiles.nativeDirectory(directory)!.appendingPathComponent(".devmcp-\(index)").path
            path.withCString { path in "application/octet-stream".withCString { mime in
                call.3?(Native.context,41,call.0,0,200,path,mime,3,open(directory.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC))
            } }
        }
        for request in requests { let result = try await request.value;precondition(result.status == 200 && result.bytes == 3 && result.temporary?.url.deletingLastPathComponent().path == DevMCPFiles.nativeDirectory(directory)!.path) }
        let tooLargeFile = Task { try await filePage.downloadFile(downloadURL,directory:directory) }
        await Task.yield()
        Native.fileCalls.last!.3?(Native.context,41,Native.fileCalls.last!.0,3,200,nil,nil,104_923_136,-1)
        let tooLargeResult = try await tooLargeFile.value
        precondition(tooLargeResult.result == 3 && tooLargeResult.temporary == nil)
        let fileCancel = Task { try await filePage.downloadFile(downloadURL,directory:directory) }
        await Task.yield();let cancelledFile = Native.fileCalls.last!
        fileCancel.cancel()
        do { _ = try await fileCancel.value;preconditionFailure() } catch {}
        precondition(Native.fileCancelled == [cancelledFile.0])
        cancelledFile.3?(Native.context,41,cancelledFile.0,1,0,nil,nil,0,-1)
        let replaced = Task { try await filePage.downloadFile(downloadURL,directory:directory) }
        await Task.yield();let replacedFile = Native.fileCalls.last!
        Native.emit(1)
        do { _ = try await replaced.value;preconditionFailure() } catch {}
        precondition(Native.fileCancelled.contains(replacedFile.0))
        let moved = Task { try await filePage.downloadFile(downloadURL,directory:directory) }
        await Task.yield();Native.emit(0,window:11)
        do { _ = try await moved.value;preconditionFailure() } catch {}
        Native.acceptsFile = false
        do { _ = try await filePage.downloadFile(downloadURL,directory:directory);preconditionFailure() } catch {}
        filePage.invalidate();Native.reset()
        var ownerlessPage:ChromiumPageNavigation?=try Native.page()
        weak var goneOwner=ownerlessPage
        let heldContext=Unmanaged<AnyObject>.fromOpaque(Native.context!).takeUnretainedValue()
        let pointer=Native.context
        let orphaned=Task { [weak ownerlessPage] in
            try await ownerlessPage?.downloadFile(downloadURL,directory:directory)
        }
        await Task.yield();let ownerlessCall=Native.fileCalls.last!
        ownerlessPage?.invalidate()
        _=try? await orphaned.value
        ownerlessPage=nil
        precondition(goneOwner==nil)
        let orphanPath=directory.appendingPathComponent(".devmcp-orphan")
        try Data("owned".utf8).write(to:orphanPath)
        let orphanDescriptor=open(directory.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        withExtendedLifetime(heldContext) {
            orphanPath.path.withCString { path in
                ownerlessCall.3?(pointer,41,ownerlessCall.0,0,200,path,nil,5,orphanDescriptor)
            }
        }
        // Cleanup runs on a utility task; yielding is not a completion barrier.
        let cleanupDeadline = ContinuousClock.now + .seconds(2)
        while FileManager.default.fileExists(atPath:orphanPath.path) || fcntl(orphanDescriptor,F_GETFD) != -1 {
            if ContinuousClock.now >= cleanupDeadline { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!FileManager.default.fileExists(atPath:orphanPath.path))
        precondition(fcntl(orphanDescriptor,F_GETFD)==(-1))
        Native.reset()
        print("Native download adapter:6 slots,exact URL/directory,stream status/limit,cancel/document/owner/refusal and late callbacks passed")
        let dataPage = try Native.page()
        var dataResults: [ChromiumSiteDataOutcome] = []
        precondition(dataPage.performNativePageCommand(.clearSiteCookies) { dataResults.append($0) })
        precondition(Native.siteDataActions.last == 0 && dataResults.isEmpty)
        precondition(!dataPage.performNativePageCommand(.clearSiteCache) { _ in preconditionFailure() })
        Native.siteDataCallback?(Native.context, 41, Native.siteDataRequest, 0)
        precondition(dataResults == [.completed])
        precondition(dataPage.performNativePageCommand(.clearSiteCache) { dataResults.append($0) })
        precondition(Native.siteDataActions.last == 1)
        Native.siteDataCallback?(Native.context, 41, Native.siteDataRequest, 2)
        precondition(dataResults == [.completed, .failed])
        precondition(dataPage.performNativePageCommand(.clearCookiesAndReload) { dataResults.append($0) })
        Native.emit(1, url: "https://fixture.test/superseding")
        // Native document validation owns completion and conditional reload;
        // Swift never reloads after a cookie callback itself.
        Native.siteDataCallback?(Native.context, 41, Native.siteDataRequest, 1)
        precondition(dataResults.last == .cancelled && Native.commands.isEmpty)
        precondition(dataPage.performNativePageCommand(.clearSiteCookies) { dataResults.append($0) })
        let transferred = Native.siteDataCallback, transferredRequest = Native.siteDataRequest
        Native.emit(0, window: 11)
        precondition(dataResults.count == 4 && dataResults.last == .cancelled)
        transferred?(Native.context, 41, transferredRequest, 0)
        precondition(dataResults.count == 4)
        precondition(dataPage.performNativePageCommand(.clearSiteCache) { dataResults.append($0) })
        let closing = Native.siteDataCallback, closingRequest = Native.siteDataRequest
        let context = Native.context
        dataPage.invalidate()
        closing?(context, 41, closingRequest, 0)
        precondition(dataResults.count == 5 && dataResults.last == .cancelled)
        Native.reset(); Native.enableMedia = true
        page = try Native.page()
        precondition(page!.state.media == nil)
        Native.emitMedia(1 | 2 | 4 | 8 | 16 | 32 | 64 | 128)
        precondition(page!.state.media?.isPlaying == true && page!.state.media?.isAudible == false)
        precondition(page!.state.media?.title == "Track" && page!.state.title == "Fixture")
        precondition(page!.state.media?.artist == "Artist" && page!.state.media?.album == "Album")
        precondition(page!.state.url?.path == "/committed")
        var mediaChanges = 0
        page!.onEvent = { if case .mediaChanged = $0 { mediaChanges += 1 } }
        Native.emitMedia(1 | 2 | 4 | 8 | 16 | 32 | 64 | 128)
        precondition(mediaChanges == 0)
        Native.acceptsCommands = false
        precondition(!page!.setPlaybackPaused(true) && page!.state.media?.isPlaying == true)
        Native.acceptsCommands = true
        Native.emit(6, window: 12)
        precondition(page!.setPlaybackPaused(true) && page!.skipTrack(forward: true))
        precondition(page!.state.media?.isPlaying == true, "Accepted transport invented playback completion")
        precondition(Native.mediaActions.last?.0 == 12 && Native.mediaActions.last?.1 == 20 && Native.mediaActions.last?.2 == 3)
        precondition(!Native.commands.contains { $0.0 == "select" })
        Native.emitMedia(1 | 2 | 64, window: 12, title: "Paused track")
        precondition(page!.state.media?.isPlaying == false && page!.state.media?.title == "Paused track")
        Native.emit(2, window: 12, url: "https://fixture.test/new-media-document")
        precondition(page!.state.media == nil, "Initial rebind snapshot retained prior-document media")
        let lateMedia = Native.mediaCallback, lateContext = Native.context
        page!.invalidate()
        lateMedia?(lateContext, 41, 12, 20, 1 | 2 | 4, nil, nil, nil)
        precondition(page!.state.media == nil && !page!.setPlaybackPaused(false))
        page = nil
        Native.reset(); Native.enableMedia = true; Native.acceptsMedia = false
        do { _ = try Native.page(); preconditionFailure("Refused media registration was admitted") }
        catch ChromiumNavigationError.observationRejected {}
        precondition(Native.cancelled == [41])
        Native.reset()
        let styled = try Native.page()
        let doc = URL(string: "https://fixture.invalid/committed")!
        var styleResults: [Bool] = []
        precondition(styled.supportsUserCSS)
        precondition(styled.setUserCSS("body{color:red}", for: doc) { styleResults.append($0) })
        let firstStyle = Native.styles.last!
        precondition(styled.setUserCSS("body{color:blue}", for: doc) { styleResults.append($0) })
        precondition(styleResults == [false])
        firstStyle.callback?(Native.context, 41, firstStyle.request, 0)
        precondition(styleResults == [false], "Superseded CSS reply changed current completion")
        let secondStyle = Native.styles.last!
        secondStyle.callback?(Native.context, 41, secondStyle.request, 0)
        precondition(styleResults == [false, true] && Native.commands.isEmpty)
        precondition(Native.styles.last?.url == doc.absoluteString)
        Native.acceptStyles = false
        precondition(!styled.setUserCSS("", for: doc) { styleResults.append($0) })
        let refusedStyle = Native.styles.last!
        refusedStyle.callback?(Native.context, 41, refusedStyle.request, 0)
        precondition(styleResults == [false, true], "Refused dispatch published CSS success")
        Native.acceptStyles = true
        precondition(styled.setUserCSS("pending", for: doc) { applied in
            styleResults.append(applied)
            if !applied {
                precondition(styled.setUserCSS("nested", for: doc) { styleResults.append($0) })
            }
        })
        precondition(!styled.setUserCSS("outer superseded", for: doc) { styleResults.append($0) })
        precondition(Native.styles.last?.css == "nested")
        let nestedStyle = Native.styles.last!
        nestedStyle.callback?(Native.context, 41, nestedStyle.request, 0)
        precondition(styleResults == [false, true, false, true])
        let beforeNul = Native.styles.count
        precondition(!styled.setUserCSS("a\0b", for: doc) { styleResults.append($0) })
        precondition(Native.styles.count == beforeNul)
        precondition(styled.setUserCSS("transfer pending", for: doc) { styleResults.append($0) })
        let transferredStyle = Native.styles.last!
        Native.emit(6, window: 30)
        precondition(styled.nativeWindowID == 30 && styleResults.last == false)
        let resultCount = styleResults.count
        transferredStyle.callback?(Native.context, 41, transferredStyle.request, 0)
        precondition(styleResults.count == resultCount)
        precondition(styled.setUserCSS("end pending", for: doc) { styleResults.append($0) })
        let endedStyle = Native.styles.last!
        styled.invalidate()
        precondition(!styled.supportsUserCSS && styleResults.last == false)
        let endedCount = styleResults.count
        endedStyle.callback?(Native.context, 41, endedStyle.request, 0)
        precondition(styleResults.count == endedCount && Native.commands.isEmpty)
        precondition(PageCommand.translate.supportsNativePage && PageCommand.translate.nativeBrowserCommand == nil)
        Native.reset()
        let translated = try Native.page()
        var translationResults: [PageTranslationResult?] = []
        var batches: [[PageTranslationNode]] = []
        translated.onTranslationNodes = { if let nodes = $0 { batches.append(nodes) } }
        precondition(translated.translate(.sample) { translationResults.append($0) })
        let sampleCall = Native.translationCalls.last!
        let sampleJSON = "{\"text\":\"bonjour\",\"lang\":\"fr\",\"nodes\":[]}"
        sampleJSON.withCString { sampleCall.callback?(Native.context, 41, sampleCall.generation, sampleCall.request, 0, $0) }
        precondition(translationResults.last!?.text == "bonjour")
        precondition(translated.translate(.start) { translationResults.append($0) })
        let startCall = Native.translationCalls.last!
        let nodesJSON = "{\"text\":\"\",\"lang\":\"\",\"nodes\":[{\"id\":\"1\",\"text\":\"salut\"}]}"
        nodesJSON.withCString { startCall.callback?(Native.context, 41, startCall.generation, 0, 0, $0) }
        precondition(batches == [[PageTranslationNode(id: "1", text: "salut")]])
        nodesJSON.withCString { startCall.callback?(Native.context, 41, startCall.generation, startCall.request, 0, $0) }
        precondition(translated.translate(.apply([.init(id: "1", text: "hello")])) { translationResults.append($0) })
        let pendingTranslation = Native.translationCalls.last!
        precondition(pendingTranslation.operation == 2 && pendingTranslation.payload.contains("hello"))
        Native.emit(2, url: "https://fixture.test/new-document")
        precondition(translationResults.last! == nil)
        let countBeforeLate = translationResults.count
        nodesJSON.withCString { pendingTranslation.callback?(Native.context, 41, pendingTranslation.generation, pendingTranslation.request, 0, $0) }
        nodesJSON.withCString { startCall.callback?(Native.context, 41, startCall.generation, 0, 0, $0) }
        precondition(translationResults.count == countBeforeLate && batches.count == 1)
        Native.acceptsTranslation = false
        precondition(!translated.translate(.sample) { translationResults.append($0) })
        precondition(translationResults.count == countBeforeLate)
        Native.acceptsTranslation = true
        precondition(translated.translate(.sample) { translationResults.append($0) })
        let endTranslation = Native.translationCalls.last!
        translated.invalidate()
        precondition(translationResults.last! == nil && !translated.supportsTranslation)
        let endedTranslationCount = translationResults.count
        sampleJSON.withCString { endTranslation.callback?(Native.context, 41, endTranslation.generation, endTranslation.request, 0, $0) }
        precondition(translationResults.count == endedTranslationCount && Native.commands.isEmpty)
        Native.reset()
        let scripted = try Native.page()
        let first = Task { try await scripted.evaluateScript("var n=40;n+2", mode: .expression, world: .page) }
        while Native.scriptCalls.isEmpty { await Task.yield() }
        precondition(Native.scriptCalls[0].mode == 0 && Native.scriptCalls[0].world == 0)
        Native.scriptReply(0, status: 0, text: "42", json: "42")
        let firstResult = try await first.value
        precondition(firstResult.browserToolText == "42")
        let nul = Task { try await scripted.evaluateScript("'a\\0b'", mode: .expression, world: .page) }
        while Native.scriptCalls.count < 2 { await Task.yield() }
        Native.scriptReply(1, status: 0, text: "a\0b", json: "\"a\\u0000b\"", isString: true)
        let nulResult = try await nul.value
        precondition(nulResult.text.utf8.count == 3 && nulResult.text == "a\0b")
        Native.scriptCalls.removeLast()
        let pending = Task { try await scripted.evaluateScript("await new Promise(()=>{})", mode: .asyncBody, world: .isolated) }
        while Native.scriptCalls.count < 2 { await Task.yield() }
        do { _ = try await scripted.evaluateScript("newer", mode: .expression, world: .page); preconditionFailure("busy") }
        catch ChromiumPageNavigation.ScriptError.busy { }
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("cancelled") } catch { }
        precondition(Native.scriptCancelled == [Native.scriptCalls[1].request])
        let newer = Task { try await scripted.evaluateScript("return 'newer'", mode: .asyncBody, world: .isolated) }
        while Native.scriptCalls.count < 3 { await Task.yield() }
        Native.scriptReply(1, status: 0, text: "late old", json: "42")
        Native.scriptReply(2, status: 1)
        let undefined = try await newer.value
        precondition(undefined.isUndefined && undefined.devMCPText == "undefined")
        let rejected = Task { try await scripted.evaluateScript("throw Error('no')", mode: .asyncBody, world: .page) }
        while Native.scriptCalls.count < 4 { await Task.yield() }
        Native.scriptReply(3, status: 3, text: "Error: no")
        do { _ = try await rejected.value; preconditionFailure("rejected") }
        catch ChromiumPageNavigation.ScriptError.rejected(let text) { precondition(text == "Error: no") }
        let transferredScript = Task { try await scripted.evaluateScript("pending", mode: .expression, world: .page) }
        while Native.scriptCalls.count < 5 { await Task.yield() }
        Native.emit(6, window: 30)
        do { _ = try await transferredScript.value; preconditionFailure("transfer cancelled") } catch { }
        Native.scriptReply(4, status: 0, text: "late transfer")
        let navigating = Task { try await scripted.evaluateScript("pending", mode: .expression, world: .page) }
        while Native.scriptCalls.count < 6 { await Task.yield() }
        Native.emit(1, window: 30, url: "https://fixture.test/new")
        do { _ = try await navigating.value; preconditionFailure("navigation cancelled") } catch { }
        let ended = Task { try await scripted.evaluateScript("pending", mode: .expression, world: .page) }
        while Native.scriptCalls.count < 7 { await Task.yield() }
        scripted.invalidate()
        do { _ = try await ended.value; preconditionFailure("invalidation cancelled") } catch { }
        precondition(Native.commands.isEmpty && Native.scriptCancelled.count == 4)
        Native.reset()
        let historyPage = try Native.page()
        let historyText = Task { await historyPage.capturePageText() }
        while Native.scriptCalls.isEmpty { await Task.yield() }
        precondition(Native.scriptCalls[0].mode == 0 && Native.scriptCalls[0].world == 1)
        let body = String(repeating: "Synthetic history text ", count: 10)
        let encoded = String(decoding: try JSONEncoder().encode(["Article", body]), as: UTF8.self)
        Native.scriptReply(0, status: 0, json: encoded)
        let capturedText = await historyText.value
        precondition(capturedText?.title == "Article" && capturedText?.body == body)
        for parts in [["missing body"], ["title", String(repeating: "x", count: 20001)],
                      [String(repeating: "x", count: 4097), "body"]] {
            let index = Native.scriptCalls.count
            let invalid = Task { await historyPage.capturePageText() }
            while Native.scriptCalls.count == index { await Task.yield() }
            Native.scriptReply(index, status: 0,
                json: String(decoding: try JSONEncoder().encode(parts), as: UTF8.self))
            let invalidResult = await invalid.value
            precondition(invalidResult == nil)
        }
        let historyCount = Native.scriptCalls.count
        Native.emit(6, flags: 1)
        let loadingText = await historyPage.capturePageText()
        precondition(loadingText == nil && Native.scriptCalls.count == historyCount)
        Native.emit(6)
        let cancelledText = Task { await historyPage.capturePageText() }
        while Native.scriptCalls.count == historyCount { await Task.yield() }
        cancelledText.cancel()
        let cancelledTextResult = await cancelledText.value
        precondition(cancelledTextResult == nil)
        precondition(Native.scriptCancelled == [Native.scriptCalls.last!.request])
        historyPage.invalidate()
        Native.reset()
        let blockedPage = try Native.page()
        let displayedBeforeBlock = blockedPage.state
        var denied: [URL] = [], continued: [URL] = []
        blockedPage.onEvent = {
            if case .nativeBlocked(let url) = $0 { denied.append(url) }
            if case .continueNativeBlock(let url) = $0 { continued.append(url) }
        }
        Native.emit(4, error: -20)
        precondition(denied.isEmpty && continued.isEmpty)
        let blockedState = blockedPage.state
        Native.emit(10, url: "https://blocked.test/target", title: "Untrusted rejected title")
        Native.emit(11, url: "https://blocked.test/target", title: "Untrusted rejected title")
        Native.emit(10, url: "chrome://settings/")
        precondition(denied.map(\.host) == ["blocked.test"] && continued == denied)
        precondition(blockedPage.state == blockedState && blockedPage.state.url == displayedBeforeBlock.url)
        blockedPage.invalidate()
        Native.reset()
        let policyPage = try Native.page()
        let policy = ContentBlockerManager.NetworkPagePolicy(isOAuthFlow: true,
            continuedHost: "blocked.test", disabledUntil: Date().addingTimeInterval(60))
        precondition(policyPage.applyBlockingPolicy(policy))
        precondition(Native.policies.last?.0 == 10 && Native.policies.last?.1 == 20 &&
            Native.policies.last?.2 == 1 && Native.policies.last?.3 == "blocked.test")
        precondition((59_000...60_000).contains(Native.policies.last!.4))
        Native.emit(6, window: 11)
        precondition(policyPage.applyBlockingPolicy(policy) && Native.policies.last?.0 == 11)
        Native.acceptsPolicy = false
        precondition(!policyPage.applyBlockingPolicy(policy))
        policyPage.invalidate()
        let policyCalls = Native.policies.count
        precondition(!policyPage.applyBlockingPolicy(policy) && Native.policies.count == policyCalls)
        Native.reset()
        var searchAPI = Native.bridge
        searchAPI.tab_search = { window, tab, query, token in
            MainActor.assumeIsolated {
                SearchNative.commands.append((window, tab, String(cString: query!), token.map { String(cString: $0) }))
                return 1
            }
        }
        let searchPage = try ChromiumPageNavigation(profileID: Native.profile, window: 10, tab: 20, bridge: searchAPI)
        precondition(searchPage.search("a query", kagiSessionToken: "synthetic-session"))
        precondition(SearchNative.commands.last?.0 == 10 && SearchNative.commands.last?.2 == "a query" &&
            SearchNative.commands.last?.3 == "synthetic-session")
        Native.emit(6, window: 11)
        precondition(searchPage.search("second", kagiSessionToken: nil))
        precondition(SearchNative.commands.last?.0 == 11 && SearchNative.commands.last?.3 == nil)
        searchPage.invalidate()
        precondition(!searchPage.search("closed", kagiSessionToken: nil) && SearchNative.commands.count == 2)
        var seedCalls = 0, replies = 0
        let service = SearchNative.api
        let seed: @MainActor () -> String? = { seedCalls += 1; return "{\"selected\":\"kagi\",\"engines\":[]}" }
        service.read(profile: Native.profile, page: nil, seed: seed, selection: nil, includeChoices: false) {
            precondition(try! $0.get() == SearchNative.state); replies += 1
        }
        precondition(seedCalls == 1 && replies == 1 && SearchNative.calls.count == 2)
        precondition(SearchNative.calls.allSatisfy { $0.0 == Native.profile.uuidString.lowercased() && $0.1 == 0 && $0.2 == 0 && !$0.4 })
        service.read(profile: Native.profile, page: nil, seed: seed, selection: nil, includeChoices: false) {
            precondition(try! $0.get() == SearchNative.state); replies += 1
        }
        precondition(seedCalls == 1 && replies == 2 && SearchNative.calls.count == 3 && !SearchNative.calls.last!.3)
        Native.reset()
        let picking = try Native.page()
        let selected = Task { await picking.pickElement() }
        while Native.pickerCalls.count < 1 { await Task.yield() }
        Native.pickReply(0, "#chosen")
        let selectedResult = await selected.value
        precondition(selectedResult == "#chosen")
        let oldPick = Task { await picking.pickElement() }
        while Native.pickerCalls.count < 2 { await Task.yield() }
        picking.cancelElementPicker()
        let oldPickResult = await oldPick.value
        precondition(oldPickResult == nil)
        let newPick = Task { await picking.pickElement() }
        while Native.pickerCalls.count < 3 { await Task.yield() }
        Native.pickReply(1, "#stale")
        Native.pickReply(2, "#current")
        let newPickResult = await newPick.value
        precondition(newPickResult == "#current")
        let navigatingPick = Task { await picking.pickElement() }
        while Native.pickerCalls.count < 4 { await Task.yield() }
        Native.emit(2)
        let navigatingPickResult = await navigatingPick.value
        precondition(navigatingPickResult == nil)
        Native.pickReply(3, "#outgoing")
        let endingPick = Task { await picking.pickElement() }
        while Native.pickerCalls.count < 5 { await Task.yield() }
        picking.invalidate()
        let endingPickResult = await endingPick.value
        precondition(endingPickResult == nil && Native.pickerCancelled.count == 3)
        precondition(Native.commands.isEmpty)
        Native.reset()
        var historyAPI = Native.bridge
        historyAPI.tab_copy_history = { _, _, direction, buffer, capacity in
            MainActor.assumeIsolated {
                let value = direction == 0 ? "[{\"id\":77,\"title\":\"Earlier\",\"url\":\"https://fixture.test/earlier\"}]" : "[]"
                let bytes = Array(value.utf8CString)
                if let buffer, capacity >= bytes.count {
                    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                }
                return bytes.count
            }
        }
        historyAPI.tab_go_to_history_entry = { window, tab, entry in
            MainActor.assumeIsolated { Native.command("history:\(entry)", window, tab) }
        }
        let history = try ChromiumPageNavigation(profileID: Native.profile, window: 10, tab: 20, bridge: historyAPI)
        let entries = history.historyEntries(forward: false)
        precondition(entries.map(\.id) == [77] && history.historyEntries(forward: true).isEmpty)
        Native.emit(2, url: "https://fixture.test/intervening")
        precondition(history.goToHistoryEntry(entries[0].id))
        precondition(Native.commands.last?.0 == "history:77")
        Native.emit(6, window: 11)
        precondition(history.goToHistoryEntry(77) && Native.commands.last?.1 == 11)
        history.invalidate()
        let beforeHistoryCommands = Native.commands.count
        precondition(history.historyEntries(forward: false).isEmpty && !history.goToHistoryEntry(77))
        precondition(Native.commands.count == beforeHistoryCommands)
        print("Chromium navigation adapter: profile binding, transfer routing, lifecycle, CSS and cancellation passed")
    }
}
