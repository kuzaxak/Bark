#if BARK_CATALOG_FRAMEWORK
@testable import NookNativeShell
#endif
import AppKit
import Observation
import BarcChromium
import CloudKit
import SwiftUI
import NookTabsCore
import NookBlocker
import NookSettings
import NookTweaks
import NookWeb
import SwiftData

@MainActor @Observable
private final class ShareDeliveryGate {
    var state: ChromiumCloudShareInbox<String>.Readiness = .needsSettings
    var privateWindow = true

    var readiness: ChromiumCloudShareInbox<String>.Readiness { privateWindow ? .waiting : state }
}

@MainActor
private enum Native {
    static var callback: barc_profile_window_callback?
    static var context: UnsafeMutableRawPointer?
    static var profile = UUID()
    static var calls: [String] = []
    static var observers: [UInt64: (BarcTabCallback?, UnsafeMutableRawPointer?, Int32, Int32)] = [:]
    static var token: UInt64 = 1
    static var showAccepted = true
    static var onAttach: (() -> Void)?
    static var onShow: (() -> Void)?
    static var roots: [Int32: ChromiumWindowRoot] = [:]
    static var members: [Int32: Set<Int32>] = [:]
    static var activeTabs: [Int32: Int32] = [:]
    /// Blank factory windows own inert AppKit views. Only unsupported hosts are opted out.
    static var unsupportedWindows: Set<Int32> = []
    static var pageViews: [Int32: NSView] = [:]

    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.profile_open_window = { uuid, destination, callback, context in MainActor.assumeIsolated {
            precondition(destination == BARC_PROFILE_BLANK, "Utility construction must remain hidden")
            Native.calls.append("open:" + String(cString: uuid!))
            Native.callback = callback; Native.context = context
        } }
        bridge.tab_copy_title = { window, tab, _, _ in MainActor.assumeIsolated {
            Native.members[window]?.contains(tab) == true ? 1 : 0
        } }
        bridge.window_tab_at = { window, _ in MainActor.assumeIsolated { Native.members[window]?.first ?? 0 } }
        bridge.window_host_observe = { window, _, _ in MainActor.assumeIsolated {
            guard Native.members[window] != nil, !Native.unsupportedWindows.contains(window) else { return 0 }
            return UInt64(window)
        } }
        bridge.window_host_unobserve = { _ in }
        bridge.window_native_shell_is_owned = { window, expected in MainActor.assumeIsolated {
            guard Native.members[window] != nil, !Native.unsupportedWindows.contains(window) else { return 0 }
            return Native.roots[window].map { Unmanaged.passUnretained($0).toOpaque() } == expected ? 1 : 0
        } }
        bridge.window_set_root_view = { window, pointer in MainActor.assumeIsolated {
            guard let pointer, Native.members[window] != nil else { return 0 }
            let root = Unmanaged<ChromiumWindowRoot>.fromOpaque(pointer).takeUnretainedValue()
            if let existing = Native.roots[window] { return existing === root ? 1 : 0 }
            Native.calls.append("root")
            Native.onAttach?()
            guard Native.members[window]?.isEmpty == false, Native.roots[window] == nil else { return 0 }
            Native.roots[window] = root
            return 1
        } }
        bridge.window_set_chrome = { _, _ in 1 }
        bridge.tab_native_view = { window, tab in
            let address: UInt = MainActor.assumeIsolated {
                guard Native.members[window]?.contains(tab) == true, let view = Native.pageViews[tab] else { return 0 }
                return UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque())
            }
            return UnsafeMutableRawPointer(bitPattern: address)
        }
        bridge.window_select = { _ in MainActor.assumeIsolated { Native.calls.append("select"); return 1 } }
        bridge.window_discovery_state = { window, output in MainActor.assumeIsolated {
            guard let output, Native.members[window] != nil else { return 0 }
            output.pointee.window = window; output.pointee.physical_group = UInt64(window); output.pointee.selected_client = window
            output.pointee.active_tab = Native.activeTabs[window] ?? Native.members[window]?.first ?? 0
            return 1
        } }
        bridge.window_show = { _ in MainActor.assumeIsolated {
            Native.calls.append("show"); Native.onShow?()
            return Native.showAccepted ? 1 : 0
        } }
        bridge.window_close = { _ in MainActor.assumeIsolated { Native.calls.append("close"); return 1 } }
        bridge.tab_observe = { window, tab, callback, context in MainActor.assumeIsolated {
            let token = Native.token; Native.token += 1
            Native.observers[token] = (callback, context, window, tab)
            return token
        } }
        bridge.tab_unobserve = { token in MainActor.assumeIsolated { Native.observers[token] = nil } }
        bridge.tab_observe_media = { _, _ in 1 }
        bridge.tab_observe_vault = { _, _ in 1 }
        bridge.tab_observe_vault_save = { _, _ in 1 }
        bridge.tab_observe_vault_passkeys = { _, _ in 1 }
        bridge.tab_navigate = { _, _, url in MainActor.assumeIsolated {
            Native.calls.append("navigate:" + String(cString: url!)); return 1
        } }
        bridge.tab_go_back = { window, tab in MainActor.assumeIsolated { Native.calls.append("back:\(window):\(tab)"); return 1 } }
        bridge.tab_go_forward = { window, tab in MainActor.assumeIsolated { Native.calls.append("forward:\(window):\(tab)"); return 1 } }
        bridge.tab_reload = { window, tab in MainActor.assumeIsolated { Native.calls.append("reload:\(window):\(tab)"); return 1 } }
        bridge.tab_stop = { _, _ in 1 }
        bridge.tab_select = { _, _ in 1 }
        bridge.tab_close = { _, _ in 1 }
        bridge.tab_capture_thumbnail = { _, _, _ in 0 }
        bridge.tab_clear_site_data = { _, _, _, _ in 0 }
        bridge.window_profile_uuid = { _, pointer, capacity in MainActor.assumeIsolated {
            let bytes = Array(Native.profile.uuidString.utf8CString)
            if let pointer, capacity >= bytes.count {
                for (index, byte) in bytes.enumerated() { pointer[index] = byte }
            }
            return bytes.count
        } }
        return bridge
    }

    static func opened(_ window: Int32) {
        let callback = self.callback, context = self.context
        self.callback = nil; self.context = nil
        members[window] = [window * 10]
        pageViews[window * 10] = NSView()
        callback?(BARC_PROFILE_OK, window, context)
    }

    static func transfer(_ window: Int32, to destination: Int32) {
        for (token, observer) in observers.filter({ $0.value.2 == window }) {
            members[window]?.remove(observer.3)
            members[destination, default: []].insert(observer.3)
            // Owner changes even when the navigation snapshot remains identical.
            observer.0?(observer.1, token, 0, destination, observer.3, nil, nil, 0, 0)
        }
    }

    static func controls(_ window: Int32) -> NSHostingView<ChromiumProfilePageView> {
        guard let root = roots[window],
              let header = root.subviews.lazy.compactMap({
                  $0.subviews.first as? NSHostingView<ChromiumProfilePageView>
              }).first else { preconditionFailure("Window \(window) has no profile controls") }
        return header
    }

    static func close(_ window: Int32, flags: UInt32 = 128) {
        for (token, observer) in observers.filter({ $0.value.2 == window }) {
            observer.0?(observer.1, token, 7, window, observer.3, nil, nil, 0, flags)
            observers[token] = nil // Native CLOSED already ended observation.
        }
        if flags & 128 != 0 { roots[window] = nil; members[window] = nil; activeTabs[window] = nil }
    }
}

private struct NoHistoryFixtureToken: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@MainActor
private func checkScopedHistoryClear() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BarkProfileHistory-" + UUID().uuidString)
    let defaults = UserDefaults(suiteName: folder.lastPathComponent)!
    defer {
        defaults.removePersistentDomain(forName: folder.lastPathComponent)
        try? FileManager.default.removeItem(at: folder)
    }
    let settings = NookSettingsService(kagiTokenStore: NoHistoryFixtureToken(), userDefaults: defaults,
                                       boostStore: BoostStore(fileURL: folder.appendingPathComponent("Boosts.json")))
    let registry = WindowRegistry()
    let tabs = TabsController(settings: settings, windowRegistry: registry,
                              blocker: ContentBlockerManager(settings: settings),
                              sponsorBlock: SponsorBlockManager(settings: settings),
                              siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium,
                              directory: folder.appendingPathComponent("Tabs"))
    let first = tabs.tree.orderedSpaces.first!.id
    let second = tabs.createSpace(name: "Personal", icon: "house", accentHex: "#222222", after: first)!
    let workID = tabs.tree.dataStoreID(for: first)!
    let personalID = tabs.tree.dataStoreID(for: second)!
    precondition(workID != personalID)

    let window = BrowserWindowState()
    window.spaceID = first
    registry.register(window)
    registry.setActive(window)
    let container = try ModelContainer(for: HistoryEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let history = HistoryManager(context: ModelContext(container))
    let urlA = URL(string: "https://fixture.test/work")!
    let urlB = URL(string: "https://fixture.test/personal")!
    await history.importVisitsAndWait([
        HistoryVisit(url: urlA, title: "Work visit", timestamp: Date(), tabId: nil, profileId: workID),
        HistoryVisit(url: urlB, title: "Personal visit", timestamp: Date(), tabId: nil, profileId: personalID),
    ])
    var admittedCompletions: [Result<Void, ProfilePageOpenError>] = []
    var clears: [UUID?] = []
    history.onHistoryCleared = { profile, _ in clears.append(profile) }

    func clear(_ target: UUID?) {
        tabs.clearDisplayedProfileHistory(target, history: history) { admittedCompletions.append($0) }
    }

    func expectFailure(_ expected: ProfilePageOpenError) {
        guard case .failure(let actual) = admittedCompletions.removeLast(), actual == expected else {
            preconditionFailure("Expected \(expected)")
        }
    }

    precondition(tabs.displayedHistoryProfile(history) == nil)
    clear(nil); expectFailure(.profileUnavailable)
    let allRecords = await history.getHistory()
    precondition(Set(allRecords.entries.map(\.url)) == [urlA, urlB] && clears.isEmpty)

    history.switchProfile(workID)
    precondition(tabs.displayedHistoryProfile(history)?.id == workID)
    window.isIncognito = true
    precondition(tabs.displayedHistoryProfile(history) == nil)
    clear(workID); expectFailure(.profileUnavailable)
    window.isIncognito = false
    clear(UUID()); expectFailure(.profileUnavailable)

    tabs.onOpenProfilePage = { profile, destination, _, completion in
        precondition(profile.id == workID && destination == .clearData)
        completion(.failure(.presentationFailed))
    }
    clear(workID); expectFailure(.presentationFailed)
    let workBefore = await history.getHistory()
    precondition(workBefore.entries.map(\.url) == [urlA] && clears.isEmpty)

    var finish: ((Result<Void, ProfilePageOpenError>) -> Void)?
    tabs.onOpenProfilePage = { profile, destination, canPresent, completion in
        precondition(profile.id == workID && destination == .clearData && canPresent())
        finish = completion
    }
    clear(workID)
    precondition(finish != nil && clears.isEmpty && admittedCompletions.isEmpty)
    window.spaceID = second
    history.switchProfile(personalID)
    precondition(tabs.displayedHistoryProfile(history)?.id == personalID)
    clear(workID); expectFailure(.profileUnavailable)
    finish?(.success(()))
    try admittedCompletions.removeLast().get()
    let personalAfter = await history.getHistory()
    history.switchProfile(workID)
    let workAfter = await history.getHistory()
    precondition(personalAfter.entries.map(\.url) == [urlB] && workAfter.entries.isEmpty && clears == [workID])
    print("Clear History preserves other profiles and waits for admission of the captured regular profile")
}

@MainActor
private func checkPasswordManagementCommand() {
    let commands = [
        "chrome://password-manager", "chrome://password-manager/passwords",
        "  CHROME://Password-Manager/settings?from=typed  ",
        "about:password-manager", "about:password-manager/passwords",
    ]
    let unrelated = [
        "https://password-manager/passwords", "chrome://settings/passwords",
        "chrome://password-manager.invalid/passwords", "chrome://password-manager@other.invalid/",
        "chrome://user@password-manager/", "chrome://password-manager:99/passwords",
        "chrome://%70assword-manager/", "about:password-manager-other", "about://password-manager",
        "view-source:chrome://password-manager/", "pawlvault://open", "what is chrome://password-manager/",
    ]

    var opened = 0
    var dismissed = 0
    func route(_ text: String, provider: Bool?, regularOwner: Bool = true,
               override: Bool = false, losesOwnerOnDismiss: Bool = false) -> Bool {
        var current = regularOwner
        return ChromiumPasswordManagementCommand.handle(
            text, pawlEnabledAtLaunch: provider, hasSearchOrPlacementOverride: override,
            ownerCurrent: { current },
            dismissEditor: {
                dismissed += 1
                if losesOwnerOnDismiss { current = false }
            },
            openPasswordSettings: { opened += 1 }
        )
    }

    for command in commands {
        precondition(ChromiumPasswordManagementCommand.offersSettings(
            command, pawlEnabledAtLaunch: true, regularNativeOwner: true, hasSearchOrPlacementOverride: false))
        precondition(route(command, provider: true))
        precondition(!route(command, provider: false))
        precondition(!route(command, provider: nil))
        precondition(!route(command, provider: true, regularOwner: false))
        precondition(!route(command, provider: true, override: true))
        precondition(!ChromiumPasswordManagementCommand.offersSettings(
            command, pawlEnabledAtLaunch: true, regularNativeOwner: true, hasSearchOrPlacementOverride: true))
    }
    for input in unrelated {
        precondition(!route(input, provider: true), "Unexpected Settings route for \(input)")
    }
    precondition(route(commands[0], provider: true, losesOwnerOnDismiss: true))
    precondition(opened == commands.count && dismissed == commands.count + 1)
    print("Native password management opens Bark Settings only for explicit commands with the selected Pawl provider")
}

@MainActor
private func checkPasswordManagementLanding() throws {
    let landing = ChromiumPasswordManagementLanding()
    var currentOwner = true
    var shown = 0
    func action(provider: Bool? = true) -> (() -> Void)? {
        landing.settingsAction(pawlEnabledAtLaunch: provider, ownerCurrent: { currentOwner },
                               openSettings: { shown += 1 })
    }
    precondition(action() == nil, "An ordinary tab without a typed marker offers no action")
    landing.update(true)
    precondition(action(provider: nil) == nil && action(provider: false) == nil)
    let original = action()!
    precondition(shown == 0, "Displaying the action must not open Settings")
    currentOwner = false
    precondition(action() == nil)
    original()
    precondition(shown == 0, "A previously visible action cannot follow selection")
    currentOwner = true
    landing.update(false)
    precondition(action() == nil, "Navigation must suppress the action")
    landing.update(true)
    original()
    precondition(shown == 0, "A fresh landing cannot revive the previous action")
    action()?()
    precondition(shown == 1)

    let navigation = try ChromiumPageNavigation(profileID: Native.profile, window: 550, tab: 551, bridge: Native.bridge)
    defer { navigation.invalidate() }
    let (token, observer) = Native.observers.first(where: { $0.value.2 == 550 })!
    func emit(_ event: BarcTabEvent, flags: UInt32 = 0) {
        observer.0?(observer.1, token, Int32(bitPattern: event.rawValue), 550, 551, nil, nil, 0, flags)
    }
    let adapter = navigation.passwordManagementLanding
    emit(BARC_TAB_INITIAL)
    precondition(!adapter.isAvailable)
    adapter.update(true)
    emit(BARC_TAB_STARTED, flags: BARC_TAB_LOADING.rawValue)
    precondition(!adapter.isAvailable, "A new provisional navigation retires the displayed marker")
    adapter.update(true)
    navigation.load(URL(string: "https://fixture.invalid/")!)
    precondition(!adapter.isAvailable, "App navigation retires the marker before the bridge responds")
    adapter.update(true)
    emit(BARC_TAB_STATE)
    precondition(!adapter.isAvailable, "An ordinary state replaces the old landing")
    print("Typed Pawl landing action verifies provider, current ownership and document lifetime")
}

@main
private enum ProfileChecks {
    @MainActor static func main() async throws {
        var tree = TabTree()
        let space = UUID()
        tree.createSpace(id: space, name: "Work", icon: "briefcase", accentHex: "#000000", after: nil)
        let profile = tree.profiles.first!
        Native.profile = profile.id
        let presenter = ChromiumProfilePagePresenter(bridge: Native.bridge)
        var outcomes: [Result<Void, ProfilePageOpenError>] = []
        presenter.open(profile, destination: .settings, canPresent: { false }) { outcomes.append($0) }
        precondition(Native.calls.isEmpty)
        guard case .failure(.profileUnavailable) = outcomes.removeLast() else { preconditionFailure() }

        let routes: [(ProfilePageDestination, String)] = [(.settings, "chrome://settings/"),
            (.extensions, "chrome://extensions/"), (.privacy, "chrome://settings/privacy"),
            (.siteSettings, "chrome://settings/content"), (.clearData, "chrome://settings/clearBrowserData"), (.downloads, "chrome://settings/downloads"), (.passwords, "chrome://password-manager/passwords")]
        for (index, route) in routes.enumerated() {
            Native.calls = []
            presenter.open(profile, destination: route.0, canPresent: { true }) { outcomes.append($0) }
            precondition(outcomes.isEmpty, "Dispatch is not admission")
            let window = Int32(index + 10)
            Native.opened(window)
            guard case .success = outcomes.removeLast() else { preconditionFailure() }
            precondition(presenter.ownsNativeWindow(window))
            precondition(Native.calls == ["open:" + profile.id.uuidString, "root", "select", "navigate:" + route.1, "show"])
            let controls = Native.controls(window)
            Native.close(window, flags: 0)
            // A plain CLOSED reaches the presenter on a later main-actor turn.
            for _ in 0..<8 where presenter.ownsNativeWindow(window) { await Task.yield() }
            precondition(!presenter.ownsNativeWindow(window))
            precondition(controls.superview == nil)
        }

        // The root contains both the inert native page and its Swift controls.
        Native.calls = []
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(51)
        guard case .success = outcomes.removeLast() else { preconditionFailure("A host window opens the profile page") }
        precondition(Native.calls == ["open:" + profile.id.uuidString, "root", "select", "navigate:chrome://extensions/", "show"], "\(Native.calls)")
        let hostPage = Native.pageViews[510]!
        let hostRoot = sequence(first: hostPage as NSView, next: \.superview).lazy.compactMap { $0 as? ChromiumWindowRoot }.first
        precondition(hostRoot === Native.roots[51] && presenter.ownsNativeWindow(51), "The root shows the profile page")
        precondition(hostRoot!.subviews.contains { $0.subviews.first is NSHostingView<ChromiumProfilePageView> },
                     "The root holds the page's controls")
        Native.close(51, flags: 0)
        for _ in 0..<8 where presenter.ownsNativeWindow(51) { await Task.yield() }
        precondition(!presenter.ownsNativeWindow(51))

        // A kept/no-space identity is presented directly, never under the active space.
        let kept = TabTree().profiles(keeping: [KeptProfile(profile)]).first!
        precondition(kept.spaceIDs.isEmpty && kept.id == profile.id)
        Native.calls = []
        presenter.open(kept, destination: .passwords, canPresent: { true }) { outcomes.append($0) }
        Native.opened(30)
        guard case .success = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls.first == "open:" + kept.id.uuidString)
        Native.close(30)
        var available = true
        Native.calls = []
        presenter.open(kept, destination: .passwords, canPresent: { available }) { outcomes.append($0) }
        available = false
        Native.opened(20)
        guard case .failure(.profileUnavailable) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls == ["open:" + profile.id.uuidString, "close"])

        // A foreign native identity is neither shown nor closed as if it were ours.
        Native.calls = []; Native.profile = UUID()
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(21)
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls.count == 1)
        Native.profile = profile.id

        Native.calls = []; Native.unsupportedWindows = [22]
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(22)
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls == ["open:" + profile.id.uuidString])
        precondition(!presenter.ownsNativeWindow(22) && Native.observers.isEmpty)
        Native.close(22); Native.unsupportedWindows = []

        // An owner ending reentrantly during attachment cannot be shown/admitted.
        Native.calls = []; Native.onAttach = { Native.close(23) }
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(23); Native.onAttach = nil
        precondition(outcomes.count == 1)
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(!Native.calls.contains("show"))
        precondition(Native.roots[23] == nil)

        Native.calls = []; available = true
        Native.onAttach = { available = false }
        presenter.open(profile, destination: .settings, canPresent: { available }) { outcomes.append($0) }
        Native.opened(25); Native.onAttach = nil
        guard case .failure(.profileUnavailable) = outcomes.removeLast() else { preconditionFailure() }
        precondition(!Native.calls.contains("show"))
        Native.close(25)

        Native.calls = []; Native.onShow = { Native.close(26) }
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(26); Native.onShow = nil
        precondition(outcomes.count == 1)
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }

        Native.calls = []; available = true
        Native.onShow = { available = false }
        presenter.open(profile, destination: .privacy, canPresent: { available }) { outcomes.append($0) }
        Native.opened(27); Native.onShow = nil
        guard case .failure(.profileUnavailable) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls.suffix(2) == ["show", "close"])
        Native.close(27)

        Native.calls = []; Native.showAccepted = false
        presenter.open(profile, destination: .clearData, canPresent: { true }) { outcomes.append($0) }
        Native.opened(24)
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls.last == "close")
        Native.close(24); Native.showAccepted = true
        precondition(Native.observers.isEmpty)

        // A displayed header does not follow transferred contents. Retained old
        // controls and queued callbacks cannot target either window afterwards.
        Native.calls = []
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(40)
        guard case .success = outcomes.removeLast() else { preconditionFailure() }
        let header = Native.controls(40)
        let controls = header.rootView
        let late = Native.observers.first!.value
        let lateToken = Native.observers.first!.key
        controls.goBack()
        precondition(Native.calls.last == "back:40:400")
        Native.calls = []
        Native.transfer(40, to: 41)
        precondition(Native.calls.isEmpty && Native.observers.isEmpty && header.superview == nil)
        precondition(Native.members[41]?.contains(400) == true)
        Native.calls = []
        controls.goBack(); controls.goForward(); controls.reload(); controls.close()
        withExtendedLifetime(controls) {
            late.0?(late.1, lateToken, 3, 41, 400, nil, nil, 0, 0)
        }
        precondition(Native.calls.isEmpty && outcomes.isEmpty)

        // Membership admission also protects actions before the queued owner
        // notification reaches this observer.
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(48)
        guard case .success = outcomes.removeLast() else { preconditionFailure() }
        let queuedHeader = Native.controls(48)
        Native.members[48]?.remove(480)
        Native.members[49, default: []].insert(480)
        Native.calls = []
        queuedHeader.rootView.close(); queuedHeader.rootView.reload()
        precondition(Native.calls.isEmpty)
        Native.transfer(48, to: 49)
        precondition(Native.calls.isEmpty && queuedHeader.superview == nil && Native.members[49]?.contains(480) == true)

        // Exact expected-view comparison preserves a replacement product header.
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(42)
        guard case .success = outcomes.removeLast() else { preconditionFailure() }
        let replacedHeader = Native.controls(42)
        let replacementControls = replacedHeader.rootView
        let productHeader = NSView()
        Native.roots[42]!.setSidebar(productHeader)
        Native.calls = []
        replacementControls.close(); replacementControls.reload()
        replacementControls.goBack(); replacementControls.goForward()
        precondition(Native.calls.isEmpty && Native.roots[42]!.holdsSidebar(productHeader))
        Native.transfer(42, to: 43)
        precondition(Native.roots[42]!.holdsSidebar(productHeader) && Native.calls.isEmpty)
        withExtendedLifetime(replacedHeader) {}

        // A reentrant replacement can win even when attachment returns zero.
        // Attempting attachment is enough to require exact header ownership
        // before any refusal cleanup may close a window.
        let rejectedReplacement = ChromiumWindowRoot(bridge: Native.bridge, client: 50) { _, _, _ in nil }
        Native.calls = []
        Native.onAttach = {
            Native.roots[50] = rejectedReplacement
        }
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(50); Native.onAttach = nil
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.roots[50] === rejectedReplacement)
        precondition(Native.calls == ["open:" + profile.id.uuidString, "root"] && Native.observers.isEmpty)

        // Transfers inside pending native callbacks fail exactly once without
        // closing/showing/navigating the old owner or following the live tab.
        Native.calls = []
        Native.onAttach = { Native.transfer(44, to: 45) }
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(44); Native.onAttach = nil
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls == ["open:" + profile.id.uuidString, "root"])
        precondition(Native.members[45]?.contains(440) == true && Native.observers.isEmpty)
        Native.calls = []
        Native.onShow = { Native.transfer(46, to: 47) }
        presenter.open(profile, destination: .privacy, canPresent: { true }) { outcomes.append($0) }
        Native.opened(46); Native.onShow = nil
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls.last == "show" && !Native.calls.contains("close"))
        precondition(Native.members[47]?.contains(460) == true && outcomes.isEmpty && Native.observers.isEmpty)
        // A reentrant Show may replace the selection while the original tab stays in the window.
        // Refusal can revoke our controls without closing the newly selected tab's window.
        Native.calls = []
        Native.onShow = {
            Native.members[52]?.insert(521)
            Native.activeTabs[52] = 521
        }
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(52); Native.onShow = nil
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls.last == "show" && Native.activeTabs[52] == 521)
        precondition(!presenter.ownsNativeWindow(52) && Native.observers.isEmpty)

        // Kept-only recovery returns only its admitted, still-owned native handle.
        var recovery: [Result<Int32, ProfilePageOpenError>] = []
        var settingsOpened = 0
        Native.calls = []
        presenter.openRecovery(kept, canPresent: { true }, openSettings: { settingsOpened += 1 }) { recovery.append($0) }
        precondition(recovery.isEmpty)
        Native.opened(70)
        let recoveryWindow = try recovery.removeLast().get()
        precondition(recoveryWindow == 70 && !Native.calls.contains("show"))
        precondition(presenter.ownsRecoveryWindow(70, profile: kept.id, activeTab: 700))
        precondition(!presenter.ownsRecoveryWindow(70, profile: UUID(), activeTab: 700))
        precondition(!presenter.ownsRecoveryWindow(70, profile: kept.id, activeTab: 701))
        let recoveryHeader = Native.controls(70)
        recoveryHeader.rootView.openRecovery()
        precondition(settingsOpened == 1)
        Native.roots[70]!.setSidebar(NSView())
        recoveryHeader.rootView.openRecovery()
        precondition(settingsOpened == 1 && !presenter.ownsRecoveryWindow(70, profile: kept.id, activeTab: 700))
        Native.transfer(70, to: 71)
        precondition(!presenter.ownsRecoveryWindow(70, profile: kept.id, activeTab: 700))

        // The exact pending operation can disappear during attachment (e.g.
        // successful retry); no stale utility startup owner may be returned.
        available = true; Native.calls = []
        Native.onAttach = { available = false }
        presenter.openRecovery(kept, canPresent: { available }, openSettings: {}) { recovery.append($0) }
        Native.opened(72); Native.onAttach = nil
        guard case .failure(.profileUnavailable) = recovery.removeLast() else { preconditionFailure() }
        precondition(!Native.calls.contains("show") && Native.calls.last == "close")
        Native.close(72)

        // Shutdown cancels completion immediately but retains the borrowed C
        // request until its late open callback, which closes only that exact UUID.
        Native.calls = []
        presenter.openRecovery(kept, canPresent: { true }, openSettings: {}) { recovery.append($0) }
        presenter.cancelPending()
        guard case .failure(.presentationUnavailable) = recovery.removeLast() else { preconditionFailure() }
        Native.opened(74)
        precondition(recovery.isEmpty && Native.calls.suffix(1) == ["close"] && !Native.calls.contains("root"))
        precondition(!presenter.ownsRecoveryWindow(74, profile: kept.id, activeTab: 740))
        // Cancellation can reenter from native attachment; completion is
        // cleared first, so unwinding the old request cannot publish success.
        Native.calls = []
        Native.onAttach = { presenter.cancelPending() }
        presenter.openRecovery(kept, canPresent: { true }, openSettings: {}) { recovery.append($0) }
        Native.opened(76); Native.onAttach = nil
        precondition(recovery.count == 1)
        guard case .failure(.presentationUnavailable) = recovery.removeLast() else { preconditionFailure() }
        precondition(!Native.calls.contains("show") && Native.calls.last == "close")
        Native.close(76)
        // A failed native factory has no handle to publish and no owned window to close.
        presenter.openRecovery(kept, canPresent: { true }, openSettings: {}) { recovery.append($0) }
        let failedCallback = Native.callback, failedContext = Native.context
        Native.callback = nil; Native.context = nil
        failedCallback?(BARC_PROFILE_CANCELLED, 0, failedContext)
        guard case .failure(.presentationFailed) = recovery.removeLast() else { preconditionFailure() }
        // One cancellation callback can deliver another request's factory result.
        // Both requests must already be revoked before the first callout.
        var pendingFactories: [(barc_profile_window_callback?, UnsafeMutableRawPointer?)] = []
        var delivered = false
        Native.calls = []
        for _ in 0..<2 {
            presenter.openRecovery(kept, canPresent: { true }, openSettings: {}) { result in
                recovery.append(result)
                if !delivered {
                    delivered = true
                    for (index, pending) in pendingFactories.enumerated() {
                        let window = Int32(78 + index)
                        Native.members[window] = [window * 10]
                        pending.0?(BARC_PROFILE_OK, window, pending.1)
                    }
                }
            }
            pendingFactories.append((Native.callback, Native.context))
            Native.callback = nil; Native.context = nil
        }
        presenter.cancelPending()
        precondition(recovery.count == 2 && !Native.calls.contains("root"))
        for result in recovery {
            guard case .failure(.presentationUnavailable) = result else { preconditionFailure() }
        }
        precondition(Native.observers.isEmpty)
        try await checkScopedHistoryClear()
        checkPasswordManagementCommand()
        try checkPasswordManagementLanding()
        await checkCloudShareActivation()
        print("Chromium profile page checks passed")
    }

    @MainActor private static func checkCloudShareActivation() async {
        let container = SpaceSyncAvailability.containerID, zone = SpaceSyncAvailability.zoneName
        let share = CKRecordNameZoneWideShare
        precondition(ChromiumApplication.isSystemSpacesShare(container: container, zone: zone, record: share))
        precondition(!ChromiumApplication.isSystemSpacesShare(container: "iCloud.ee.qdo.nook", zone: zone, record: share))
        precondition(!ChromiumApplication.isSystemSpacesShare(container: container, zone: "other", record: share))
        precondition(!ChromiumApplication.isSystemSpacesShare(container: container, zone: zone, record: "record-share"))

        let link = URL(string: "https://www.icloud.com/share/test#Bark_Spaces")!
        let legacy = URL(string: "https://www.icloud.com/share/test#Nook_Spaces")!
        precondition(ChromiumApplication.isExternalSpacesShareLink(link, syncEnabled: false))
        precondition(!ChromiumApplication.isExternalSpacesShareLink(legacy, syncEnabled: false))
        precondition(ChromiumApplication.isExternalSpacesShareLink(legacy, syncEnabled: true))
        for raw in ["https://www.icloud.com/share/test#Other",
                    "https://www.icloud.com:443/share/test#Bark_Spaces",
                    "https://user@www.icloud.com/share/test#Bark_Spaces",
                    "https://example.test/share/test#Bark_Spaces"] {
            precondition(!ChromiumApplication.isExternalSpacesShareLink(URL(string: raw)!, syncEnabled: true))
        }

        let replay = ChromiumShareLinkReplay()
        var fallback: (() -> Void)?
        var reopened: [URL] = []
        precondition(replay.take(link, lookup: { _, reopen in
            fallback = reopen
            return true
        }, reopen: { reopened.append($0) }))
        fallback?()
        fallback?()
        precondition(reopened == [link])
        precondition(!replay.take(link, lookup: { _, _ in preconditionFailure("Recursive invitation lookup") },
                                 reopen: { _ in preconditionFailure() }))
        replay.reachedPendingPage(link)

        let inbox = ChromiumCloudShareInbox<String>()
        var delivered: [String] = []
        precondition(inbox.receive(link.absoluteString))
        await Task.yield()
        precondition(delivered.isEmpty)
        let gate = ShareDeliveryGate()
        var settingsOpened = 0
        var lookups = 0
        inbox.ready(when: { gate.readiness }, showSettings: { settingsOpened += 1 }) { invitation in
            if invitation == "next" {
                lookups += 1
                if lookups == 1 {
                    gate.privateWindow = true
                    return false
                }
                if lookups == 2 {
                    gate.state = .waiting
                    return false
                }
            }
            delivered.append(invitation)
            if invitation == link.absoluteString { gate.state = .waiting }
            return true
        }
        precondition(delivered.isEmpty, "Acceptance must run outside the AppKit callback")
        for _ in 0..<10 { await Task.yield() }
        precondition(settingsOpened == 0, "The inbox cannot present Settings over a private window")
        gate.privateWindow = false
        for _ in 0..<100 where settingsOpened == 0 { await Task.yield() }
        precondition(delivered.isEmpty && settingsOpened == 1)
        inbox.receive("next")
        gate.state = .waiting
        await Task.yield()
        precondition(delivered.isEmpty && settingsOpened == 1)
        gate.state = .ready
        for _ in 0..<100 where delivered.isEmpty { await Task.yield() }
        precondition(delivered == [link.absoluteString], "A join in progress keeps the next invitation queued")
        gate.state = .ready
        for _ in 0..<100 where lookups == 0 { await Task.yield() }
        precondition(lookups == 1 && delivered == [link.absoluteString], "Entering a private window retains the pending invitation")
        gate.privateWindow = false
        for _ in 0..<100 where lookups < 2 { await Task.yield() }
        precondition(lookups == 2 && delivered == [link.absoluteString], "An account change retains the pending invitation")
        gate.state = .ready
        for _ in 0..<100 where delivered.count < 2 { await Task.yield() }
        precondition(delivered == [link.absoluteString, "next"] && lookups == 3 && settingsOpened == 1)
        gate.state = .waiting
        inbox.receive("cancelled")
        await Task.yield()
        inbox.stop()
        gate.state = .ready
        precondition(!inbox.receive("after shutdown"))
        await Task.yield()
        precondition(delivered == [link.absoluteString, "next"])
        print("Share links and system invitations survive startup and opt-in, wait for the current join, and clear on quit")
    }
}
