// Licensed under GPL-3.0. See LICENSE.
import AppKit
import NookWeb
import NookBlocker
import NookSettings
import NookTweaks

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
    static var selectionCalls = 0
    static var attachmentCalls = 0
    static var nativeCloses: [(Int32, Int32)] = []
    static var onObserve: ((Int32, Int32) -> Void)?
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
            tabTitle: { window, tab, _, _ in MainActor.assumeIsolated {
                Native.tabs[window]?.contains(tab) == true && Native.profiles[window] != nil ? 1 : 0
            } },
            selectWindow: { window in MainActor.assumeIsolated {
                Native.selectionCalls += 1; Native.selected = window; return 1
            } },
            closeWindow: { window in MainActor.assumeIsolated { Native.tabs[window] = nil; Native.profiles[window] = nil; return 1 } },
            attach: { window, view in MainActor.assumeIsolated {
                Native.attachmentCalls += 1
                if let callback = Native.onAttach { return callback(window) }
                Native.attached = view == nil ? 0 : window; return 1
            } })
    }

    static var navigation: ChromiumNavigationAPI {
        ChromiumNavigationAPI(
            observe: { window, tab, callback, context in MainActor.assumeIsolated {
                guard !Native.observations.values.contains(where: { $0.3 == tab }) else { return 0 }
                let token = Native.nextObservation; Native.nextObservation += 1
                Native.observations[token] = (callback, context, window, tab)
                "https://fixture.invalid/page-\(tab)".withCString {
                    callback?(context, token, 0, window, tab, $0, nil, 0, 0)
                }
                Native.onObserve?(window, tab)
                return token
            } },
            unobserve: { token in MainActor.assumeIsolated { Native.observations[token] = nil } },
            navigate: { _, _, _ in preconditionFailure("Host must not navigate during construction") },
            back: { _, _ in 1 }, forward: { _, _ in 1 }, reload: { _, _ in 1 }, stop: { _, _ in 1 },
            select: { window, _ in MainActor.assumeIsolated {
                Native.selectionCalls += 1
                if let callback = Native.onSelect { return callback() }
                Native.selected = window; return 1
            } },
            close: { window, tab in MainActor.assumeIsolated {
                Native.nativeCloses.append((window, tab)); return 1
            } },
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
        let entry = observations.first { $0.value.3 == page.nativeTabID }!
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
        precondition(host.canAdoptPage(original, in: window))
        let reservedHost = ChromiumNativePageHost(api: Native.api, navigationAPI: Native.navigation)
        let reservedWindow = BrowserWindowState(), reservedShell = NSView()
        precondition(reservedHost.registerWindow(reservedWindow, nativeOwner: 10, shell: reservedShell, initialBlankTab: 100))
        let beforeReserved = Native.nextObservation
        if case .success = reservedHost.bindExistingPage(nativeWindow: 10, tab: 100, profile: firstProfile, in: reservedWindow) {
            preconditionFailure("Reserved app factory blank was stolen")
        }
        precondition(Native.nextObservation == beforeReserved && Native.nativeCloses.isEmpty)
        precondition(!host.canAdoptPage(original, in: BrowserWindowState(id: window.id)))
        precondition(Native.selected == 10 && Native.creates == 0 && Native.opens == 0)
        Native.tabs[10] = []
        precondition(!host.canAdoptPage(original, in: window), "Native membership must be current")
        Native.tabs[10] = [100]

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

        // Existing app-owned adapters are reused without a second observer.
        let ownedCount = Native.observations.count
        let owned = try host.bindExistingPage(nativeWindow: 10, tab: 100, profile: firstProfile, in: window).get()
        precondition(owned.navigation === original && Native.observations.count == ownedCount)
        owned.finish(adopted: false); owned.finish(adopted: false)
        precondition(host.canAdoptPage(original, in: window))

        let beforeCreates = Native.creates, beforeOpens = Native.opens
        Native.tabs[10, default: []].append(contentsOf: [500, 501, 502])
        let firstAttempt = try host.bindExistingPage(nativeWindow: 10, tab: 500, profile: firstProfile, in: window).get()
        let nested = try host.bindExistingPage(nativeWindow: 10, tab: 500, profile: firstProfile, in: window).get()
        precondition(firstAttempt.navigation === nested.navigation)
        precondition(firstAttempt.navigation.state.url?.absoluteString == "https://fixture.invalid/page-500")
        nested.finish(adopted: true)
        firstAttempt.finish(adopted: false)
        firstAttempt.finish(adopted: false)
        precondition(host.canAdoptPage(nested.navigation, in: window), "Outer rejection killed a nested adoption")
        precondition(Native.observations.count == ownedCount + 1)

        let rejected = try host.bindExistingPage(nativeWindow: 10, tab: 501, profile: firstProfile, in: window).get()
        rejected.finish(adopted: false)
        precondition(!host.canAdoptPage(rejected.navigation, in: window))
        precondition(Native.observations.count == ownedCount + 1)
        let retry = try host.bindExistingPage(nativeWindow: 10, tab: 501, profile: firstProfile, in: window).get()
        precondition(retry.navigation !== rejected.navigation)
        retry.finish(adopted: false)
        precondition(Native.observations.count == ownedCount + 1)
        var abandoned: ChromiumExistingPageBinding? = try host.bindExistingPage(
            nativeWindow: 10, tab: 502, profile: firstProfile, in: window).get()
        precondition(abandoned != nil)
        abandoned = nil
        precondition(Native.observations.count == ownedCount + 1)
        precondition(Native.nativeCloses.isEmpty && Native.creates == beforeCreates && Native.opens == beforeOpens)

        // Current profile and owner are required even if an announcement was valid earlier.
        if case .success = host.bindExistingPage(nativeWindow: 20, tab: 500, profile: firstProfile, in: window) {
            preconditionFailure("A foreign native owner/profile was admitted")
        }
        Native.tabs[10]?.removeAll { $0 == 500 }
        precondition(!host.canAdoptPage(nested.navigation, in: window))
        Native.tabs[10]?.append(500)

        // Reject a transfer reported during initial observation, without closing it.
        Native.onObserve = { native, tab in
            guard tab == 503 else { return }
            Native.tabs[native]?.removeAll { $0 == tab }
            Native.profiles[11] = Native.first
            Native.tabs[11, default: []].append(tab)
            let entry = Native.observations.first { $0.value.3 == tab }!
            entry.value.0?(entry.value.1, entry.key, 6, 11, tab, nil, nil, 0, 0)
        }
        Native.tabs[10]?.append(503)
        if case .success = host.bindExistingPage(nativeWindow: 10, tab: 503, profile: firstProfile, in: window) {
            preconditionFailure("An initial owner transfer was ignored")
        }
        Native.onObserve = nil
        precondition(Native.nativeCloses.isEmpty && Native.observations.count == ownedCount + 1)

        Native.tabs[10]?.append(504)
        let pendingClose = try host.bindExistingPage(nativeWindow: 10, tab: 504, profile: firstProfile, in: window).get()
        var pendingOutcome: PageCloseOutcome?
        host.closePage(pendingClose.navigation) { pendingOutcome = $0 }
        pendingClose.finish(adopted: false)
        precondition(pendingOutcome == nil && Native.observations.count == ownedCount + 2)
        Native.emit(8, page: pendingClose.navigation)
        precondition(pendingOutcome == .cancelled && Native.observations.count == ownedCount + 1)

        // A live same-profile transfer must not carry this product sidebar
        // into an unregistered physical/native owner.
        func moveObservedPage(_ page: ChromiumPageNavigation, to owner: Int32) {
            for native in Array(Native.tabs.keys) { Native.tabs[native]?.removeAll { $0 == page.nativeTabID } }
            Native.tabs[owner, default: []].append(page.nativeTabID)
            let entry = Native.observations.first { $0.value.3 == page.nativeTabID }!
            page.state.url!.absoluteString.withCString {
                entry.value.0?(entry.value.1, entry.key, 6, owner, page.nativeTabID, $0, nil, 0, 0)
            }
        }
        moveObservedPage(nested.navigation, to: 11) // 11 has the same real profile UUID as 10.
        let beforeSelection = Native.selectionCalls, beforeAttachment = Native.attachmentCalls
        precondition(!host.selectPage(nested.navigation, in: window))
        precondition(Native.selectionCalls == beforeSelection && Native.attachmentCalls == beforeAttachment)
        precondition(Native.selected == 10 && Native.attached == 10)
        moveObservedPage(nested.navigation, to: 10)

        // Transfer during native selection is revalidated before any sidebar detach.
        Native.onSelect = {
            Native.onSelect = nil
            moveObservedPage(nested.navigation, to: 11)
            return 1
        }
        precondition(!host.selectPage(nested.navigation, in: window))
        precondition(Native.attachmentCalls == beforeAttachment && Native.attached == 10)
        moveObservedPage(nested.navigation, to: 10)

        // The normal supported same-model-window profile switch still mounts.
        precondition(host.selectPage(first, in: window))
        precondition(Native.selected == 20 && Native.attached == 20)
        precondition(host.selectPage(original, in: window))
        precondition(Native.selected == 10 && Native.attached == 10)

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
        precondition(!host.canAdoptPage(first, in: window), "Pending close is not adoption admission")
        Native.emit(8, page: first)
        precondition(outcomes == [.cancelled] && !first.isClosed)
        precondition(host.canAdoptPage(first, in: window))
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
        Native.tabs[40]?.append(401)
        let beforeEnding = Native.nextObservation, beforeEndingCloses = Native.nativeCloses.count
        if case .success = host.bindExistingPage(nativeWindow: 40, tab: 401, profile: fourthProfile, in: window) {
            preconditionFailure("Known ending logical owner admitted another page")
        }
        precondition(Native.nextObservation == beforeEnding && Native.nativeCloses.count == beforeEndingCloses)
        try checkActualModelAdoption()
        print("Chromium page host checks passed")
    }
}


private struct AdoptionNoTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

/// Exercise the concrete host with the actual package adoption path. All page
/// URLs are observer snapshots; the mocked navigation call rejects any load.
@MainActor
private func checkActualModelAdoption() throws {
    let suite = "NookExistingPageHost-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let settings = NookSettingsService(kagiTokenStore: AdoptionNoTokenStore(), userDefaults: defaults)
    let registry = WindowRegistry(), window = BrowserWindowState()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
        blocker: ContentBlockerManager(settings: settings, storageDirectory: directory.appendingPathComponent("Filters")),
        sponsorBlock: SponsorBlockManager(settings: settings), siteRouting: SiteRoutingManager(settings: settings),
        profileEngine: .chromium, directory: directory.appendingPathComponent("Tabs"))
    registry.register(window)
    registry.setActive(window)
    tabs.attach(window: window)
    let space = window.spaceID!, profile = tabs.profile(forSpace: space)!
    let host = ChromiumNativePageHost(api: Native.api, navigationAPI: Native.navigation)
    tabs.nativePageHost = host
    let shell = NSView()
    Native.profiles[90] = profile.id
    Native.tabs[90] = [900, 901, 902]
    precondition(host.registerWindow(window, nativeOwner: 90, shell: shell, initialBlankTab: 900))
    let beforeCreates = Native.creates, beforeOpens = Native.opens, beforeCloses = Native.nativeCloses.count
    let outer = try host.bindExistingPage(nativeWindow: 90, tab: 901, profile: profile, in: window).get()
    var admitted: UUID?
    Native.onSelect = {
        Native.onSelect = nil
        let nested = try! host.bindExistingPage(nativeWindow: 90, tab: 901, profile: profile, in: window).get()
        admitted = tabs.adoptNativePage(nested.navigation, through: host, in: window, spaceID: space, select: false)
        nested.finish(adopted: admitted != nil)
        return 0 // The outer foreground selection is superseded/refused.
    }
    let refused = tabs.adoptNativePage(outer.navigation, through: host, in: window, spaceID: space, select: true)
    outer.finish(adopted: refused != nil)
    precondition(refused == nil && admitted != nil)
    precondition(tabs.session(for: admitted!)?.isUnloaded == false && host.canAdoptPage(outer.navigation, in: window))
    precondition(tabs.adoptNativePage(outer.navigation, through: host, in: window, spaceID: space, select: false) == admitted)
    precondition(tabs.session(for: admitted!)?.url.absoluteString == "https://fixture.invalid/page-901")
    precondition(Native.creates == beforeCreates && Native.opens == beforeOpens && Native.nativeCloses.count == beforeCloses)
    Native.emit(7, page: outer.navigation, flags: 128)
    precondition(tabs.tree.item(admitted!) != nil && tabs.session(for: admitted!)?.isUnloaded == true)
    if case .success = host.bindExistingPage(nativeWindow: 90, tab: 902, profile: profile, in: window) {
        preconditionFailure("Owner-ended event admitted another existing native page")
    }
    precondition(Native.creates == beforeCreates && Native.opens == beforeOpens && Native.nativeCloses.count == beforeCloses)
}
