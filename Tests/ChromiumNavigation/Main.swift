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
            profileUUID: { _, buffer, capacity in
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
        precondition(!page!.performNativePageCommand(.hardReload))
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

        print("Chromium navigation adapter: profile binding, transfer routing, lifecycle and cancellation passed")
    }
}
