// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookWeb

/// Compile with the actual PageNavigation.swift contract and app adapter.
/// Exercises ownership/callback ordering without a browser or user data.
@MainActor
private enum Native {
    static let profile = UUID(uuidString: "9fc28221-b340-4c80-94ef-89a2cf4db441")!
    static var callback: ChromiumNavigationAPI.Callback?
    static var context: UnsafeMutableRawPointer?
    static var observed = 0
    static var cancelled: [UInt64] = []
    static var commands: [(String, Int32, Int32)] = []
    static var acceptsCommands = true
    static var acceptsObserver = true
    static var pageCommands: [(Int32, Int32, Int32)] = []
    static var thumbnailCallback: ChromiumNavigationAPI.ThumbnailCallback?
    static var thumbnailRequest: UInt64 = 0
    static var thumbnailAccepts = true
    static var siteDataCallback: ChromiumNavigationAPI.SiteDataCallback?
    static var siteDataRequest: UInt64 = 0
    static var siteDataActions: [Int32] = []
    static var acceptsSiteData = true
    static var muteRequests: [(Int32, Int32, Int32)] = []

    static func reset() {
        callback = nil; context = nil; observed = 0; cancelled = []; commands = []
        acceptsCommands = true; acceptsObserver = true; pageCommands = []; muteRequests = []
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

    static var api: ChromiumNavigationAPI {
        ChromiumNavigationAPI(
            observe: { _, _, callback, context in
                MainActor.assumeIsolated {
                    Native.observed += 1
                    guard Native.acceptsObserver else { return 0 }
                    Native.callback = callback; Native.context = context
                    Native.emit(0, flags: 2)
                    return 41
                }
            },
            unobserve: { token in MainActor.assumeIsolated { Native.cancelled.append(token) } },
            navigate: { window, tab, url in
                MainActor.assumeIsolated { Native.command(String(cString: url!), window, tab) }
            },
            back: { window, tab in MainActor.assumeIsolated { Native.command("back", window, tab) } },
            forward: { window, tab in MainActor.assumeIsolated { Native.command("forward", window, tab) } },
            reload: { window, tab in MainActor.assumeIsolated { Native.command("reload", window, tab) } },
            stop: { window, tab in MainActor.assumeIsolated { Native.command("stop", window, tab) } },
            select: { window, tab in MainActor.assumeIsolated { Native.command("select", window, tab) } },
            close: { window, tab in MainActor.assumeIsolated { Native.command("close", window, tab) } },
            captureThumbnail: { _, request, callback in MainActor.assumeIsolated {
                Native.thumbnailRequest = request; Native.thumbnailCallback = callback
                return Native.thumbnailAccepts ? 1 : 0
            } },
            clearSiteData: { _, request, action, callback in MainActor.assumeIsolated {
                Native.siteDataRequest = request; Native.siteDataActions.append(action)
                Native.siteDataCallback = callback; return Native.acceptsSiteData ? 1 : 0
            } }, profileUUID: { _, buffer, capacity in
                MainActor.assumeIsolated {
                    let bytes = Array(Native.profile.uuidString.lowercased().utf8CString)
                    if let buffer, capacity >= bytes.count {
                        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                    }
                    return bytes.count
                }
            }, executePageCommand: { window, tab, command in MainActor.assumeIsolated {
                Native.pageCommands.append((window, tab, command)); return Native.acceptsCommands ? 1 : 0
            } }, setMuted: { window, tab, muted in MainActor.assumeIsolated {
                Native.muteRequests.append((window, tab, muted)); return Native.acceptsCommands ? 1 : 0
            } })
    }

    static func page() throws -> ChromiumPageNavigation {
        try ChromiumPageNavigation(profileID: profile, window: 10, tab: 20, api: api)
    }
}

@main
private enum NavigationChecks {
    @MainActor static func main() throws {
        Native.reset()
        do {
            _ = try ChromiumPageNavigation(profileID: UUID(), window: 10, tab: 20, api: Native.api)
            preconditionFailure("A mislabeled native profile was admitted")
        } catch ChromiumNavigationError.profileMismatch {}
        precondition(Native.observed == 0)

        var page: ChromiumPageNavigation? = try Native.page()
        precondition(page?.state.title == "Fixture" && page?.state.canGoBack == true)
        precondition(page?.state.url?.path == "/committed" && page?.state.isLoading == false)
        precondition(page!.performNativePageCommand(.find))
        precondition(Native.pageCommands.last?.2 == 0 && Native.pageCommands.count == 1)
        Native.acceptsCommands = false
        precondition(!page!.performNativePageCommand(.print))
        precondition(!page!.setAudioMuted(true) && page!.state.isAudioMuted == false)
        Native.acceptsCommands = true
        precondition(page!.setAudioMuted(true) && page!.state.isAudioMuted == false,
                     "Dispatch acceptance is not mute state")
        Native.emit(6, flags: 256 | 512)
        precondition(page!.state.isAudioMuted == true && page!.state.isAudible == true)
        precondition(page!.performNativePageCommand(.hardReload) && Native.pageCommands.last?.2 == 8)
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
        precondition(events.count == 4)
        guard case .closed = events.last else { preconditionFailure("Missing close notification") }
        precondition(!page!.goBack())
        let commandsAfterClose = Native.pageCommands.count, muteAfterClose = Native.muteRequests.count
        precondition(!page!.performNativePageCommand(.webInspector) && !page!.setAudioMuted(true))
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
        precondition(page!.requestNativeClose())
        precondition(outcomes.isEmpty, "Dispatch acceptance completed close")
        Native.emit(8, window: 12)
        precondition(outcomes == [.cancelled] && page!.goBack())
        precondition(page!.requestNativeClose())
        Native.emit(7, window: 12)
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
        print("Chromium navigation adapter: profile binding, transfer routing, lifecycle and cancellation passed")
    }
}
