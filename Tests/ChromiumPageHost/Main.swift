// Licensed under GPL-3.0. See LICENSE.
import AppKit
import NookWeb

/// Uses real package models and mocked C calls; no browser or URL is loaded.
@MainActor
private enum Native {
    static let first = UUID()
    static let second = UUID()
    static var profiles: [Int32: UUID] = [10: first]
    static var tabs: [Int32: [Int32]] = [10: [100]]
    static var nextTab: Int32 = 200
    static var pending: (ChromiumPageHostAPI.Callback?, UnsafeMutableRawPointer?)?
    static var openedFrom: [Int32] = []
    static var opens = 0
    static var creates = 0
    static var selected: Int32 = 10
    static var attached: Int32 = 10
    static var onSelect: (() -> Int32)?
    static var onAttach: ((Int32) -> Int32)?
    static var observations: [UInt64: (ChromiumNavigationAPI.Callback?, UnsafeMutableRawPointer?, Int32, Int32)] = [:]
    static var nextObservation: UInt64 = 1

    static var api: ChromiumPageHostAPI {
        ChromiumPageHostAPI(
            open: { owner, _, destination, callback, context in MainActor.assumeIsolated {
                precondition(destination == 5)
                Native.opens += 1; Native.openedFrom.append(owner); Native.pending = (callback, context)
            } },
            create: { window, url, foreground in MainActor.assumeIsolated {
                precondition(String(cString: url!) == "about:blank" && foreground == 0)
                Native.creates += 1; Native.nextTab += 1; Native.tabs[window, default: []].append(Native.nextTab)
                return Native.nextTab
            } },
            tabAt: { window, index in MainActor.assumeIsolated {
                guard let list = Native.tabs[window], list.indices.contains(index) else { return 0 }
                return list[index]
            } },
            selectWindow: { window in MainActor.assumeIsolated { Native.selected = window; return 1 } },
            closeWindow: { window in MainActor.assumeIsolated { Native.tabs[window] = nil; Native.profiles[window] = nil; return 1 } },
            attach: { window, view in MainActor.assumeIsolated {
                if let callback = Native.onAttach { return callback(window) }
                Native.attached = view == nil ? 0 : window; return 1
            } })
    }

    static var navigation: ChromiumNavigationAPI {
        ChromiumNavigationAPI(
            observe: { window, tab, callback, context in MainActor.assumeIsolated {
                let token = Native.nextObservation; Native.nextObservation += 1
                Native.observations[token] = (callback, context, window, tab); return token
            } },
            unobserve: { token in MainActor.assumeIsolated { Native.observations[token] = nil } },
            navigate: { _, _, _ in preconditionFailure("Host must not navigate during construction") },
            back: { _, _ in 1 }, forward: { _, _ in 1 }, reload: { _, _ in 1 }, stop: { _, _ in 1 },
            select: { window, _ in MainActor.assumeIsolated {
                if let callback = Native.onSelect { return callback() }
                Native.selected = window; return 1
            } },
            close: { _, _ in 1 },
            profileUUID: { window, buffer, capacity in MainActor.assumeIsolated {
                guard let profile = Native.profiles[window] else { return 0 }
                let bytes = Array(profile.uuidString.utf8CString)
                if let buffer, capacity >= bytes.count {
                    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                }
                return bytes.count
            } })
    }

    static func opened(profile: UUID?, window: Int32 = 20, blank: Int32 = 200) {
        profiles[window] = profile ?? second; tabs[window] = [blank]
        let result = pending; pending = nil
        result?.0?(0, window, result?.1)
    }

    static func emit(_ event: Int32, page: ChromiumPageNavigation, flags: UInt32 = 0) {
        let entry = observations.first { $0.value.2 == page.nativeWindowID && $0.value.3 == page.nativeTabID }!
        entry.value.0?(entry.value.1, entry.key, event, page.nativeWindowID, page.nativeTabID, nil, nil, 0, flags)
    }
}

@main
private enum HostChecks {
    @MainActor static func main() throws {
        let host = ChromiumNativePageHost(api: Native.api, navigationAPI: Native.navigation)
        let window = BrowserWindowState()
        let shell = NSView()
        precondition(host.registerWindow(window, nativeOwner: 10, shell: shell, initialBlankTab: 100))
        let firstProfile = Profile(id: Native.first, engine: .chromium)
        let secondProfile = Profile(id: Native.second, engine: .chromium)
        func session() -> PageSession {
            PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "", isPrivate: false, controller: nil)
        }
        var original: ChromiumPageNavigation!
        _ = host.createPage(for: session(), profile: firstProfile, in: window) {
            original = try! $0.get() as? ChromiumPageNavigation
        }
        precondition(original.nativeTabID == 100 && Native.creates == 0)

        var cancelledDelivered = false
        let cancel = host.createPage(for: session(), profile: secondProfile, in: window) { result in
            if case .failure = result { cancelledDelivered = true }
        }
        var first: ChromiumPageNavigation!
        _ = host.createPage(for: session(), profile: secondProfile, in: window) { first = try! $0.get() as? ChromiumPageNavigation }
        var second: ChromiumPageNavigation!
        _ = host.createPage(for: session(), profile: secondProfile, in: window) { second = try! $0.get() as? ChromiumPageNavigation }
        cancel()
        precondition(Native.opens == 1 && first == nil)
        Native.opened(profile: nil)
        precondition(cancelledDelivered && first.nativeTabID == 200 && second.nativeTabID == 201 && Native.creates == 1)
        cancel() // Completion has already happened; cancellation is inert.

        // Runtime supersession must never restore the earlier native selection.
        Native.onSelect = {
            Native.onSelect = nil
            precondition(host.selectPage(first, in: window))
            return 0
        }
        precondition(!host.selectPage(original, in: window))
        precondition(Native.selected == 20 && Native.attached == 20)

        // A nested successful mount wins over an outer attachment failure.
        Native.onAttach = { _ in
            Native.onAttach = nil
            precondition(host.selectPage(second, in: window))
            return 0
        }
        precondition(!host.selectPage(original, in: window))
        precondition(Native.selected == 20 && Native.attached == 20)

        // Ordinary attach refusal restores the previous admitted owner.
        Native.onAttach = { _ in Native.onAttach = nil; return 0 }
        precondition(!host.selectPage(original, in: window))
        precondition(Native.selected == 20 && Native.attached == 20)

        var outcomes: [PageCloseOutcome] = []
        host.closePage(first) { outcomes.append($0) }
        precondition(outcomes.isEmpty, "Dispatch acceptance is not CLOSED")
        Native.emit(8, page: first)
        precondition(outcomes == [.cancelled] && !first.isClosed)
        host.closePage(first) { outcomes.append($0) }
        Native.emit(7, page: first)
        precondition(outcomes == [.cancelled, .closed] && first.isClosed)
        precondition(!host.selectPage(first, in: window))
        host.closePage(first) { outcomes.append($0) }
        precondition(outcomes == [.cancelled, .closed, .closed])
        // If all requests cancel during open, deliver exactly one real late
        // resource for package cleanup, not a successful imaginary close.
        let thirdProfile = Profile(engine: .chromium)
        var late: ChromiumPageNavigation!
        let cancelLate = host.createPage(for: session(), profile: thirdProfile, in: window) {
            late = try! $0.get() as? ChromiumPageNavigation
        }
        cancelLate()
        Native.opened(profile: thirdProfile.id, window: 30, blank: 300)
        precondition(late.nativeTabID == 300)
        var lateClosed = false
        host.closePage(late) { lateClosed = $0 == .closed }
        precondition(!lateClosed)
        Native.emit(7, page: late)
        precondition(lateClosed)

        // A dead original logical Browser is not reused as the shared root.
        Native.profiles[20] = nil; Native.tabs[20] = nil
        Native.profiles[30] = nil; Native.tabs[30] = nil
        let fourthProfile = Profile(engine: .chromium)
        var fourth: ChromiumPageNavigation!
        _ = host.createPage(for: session(), profile: fourthProfile, in: window) {
            fourth = try! $0.get() as? ChromiumPageNavigation
        }
        precondition(Native.pending != nil && Native.openedFrom.last != 20)
        Native.opened(profile: fourthProfile.id, window: 40, blank: 400)
        precondition(fourth.nativeTabID == 400)
        var ended: [PageCloseOutcome] = []
        host.closePage(fourth) { ended.append($0) }
        Native.emit(7, page: fourth, flags: 128)
        host.closePage(fourth) { ended.append($0) }
        precondition(ended == [.ownerEnded, .ownerEnded])
        precondition(!host.selectPage(fourth, in: window))
        print("Chromium page host checks passed")
    }
}
