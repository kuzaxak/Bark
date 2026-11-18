import AppKit
import BarcChromium
import SwiftUI
import NookTabsCore
import NookWeb

@MainActor
private enum Native {
    static var callback: barc_profile_window_callback?
    static var context: UnsafeMutableRawPointer?
    static var profile = UUID()
    static var calls: [String] = []
    static var observers: [UInt64: (BarcTabCallback?, UnsafeMutableRawPointer?, Int32, Int32)] = [:]
    static var token: UInt64 = 1
    static var attachAccepted = true
    static var showAccepted = true
    static var onAttach: (() -> Void)?
    static var onShow: (() -> Void)?
    static var headers: [Int32: NSView] = [:]
    static var members: [Int32: Set<Int32>] = [:]
    static var detachAttempts = 0
    /// Windows that are Bark's own (`--bark-window=host`), and their tabs' page views.
    static var hostWindows: Set<Int32> = []
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
        bridge.window_detach_native_shell_if_owned = { window, expected in MainActor.assumeIsolated {
            Native.detachAttempts += 1
            guard let current = Native.headers[window],
                  Unmanaged.passUnretained(current).toOpaque() == expected else { return 0 }
            Native.headers[window] = nil
            Native.calls.append("detach")
            return 1
        } }
        bridge.window_native_shell_is_owned = { window, expected in MainActor.assumeIsolated {
            guard Native.members[window] != nil else { return 0 }
            guard let current = Native.headers[window] else { return expected == nil ? 1 : 0 }
            return Unmanaged.passUnretained(current).toOpaque() == expected ? 1 : 0
        } }
        bridge.window_tab_at = { window, _ in MainActor.assumeIsolated { Native.members[window]?.first ?? 0 } }
        bridge.window_host_observe = { window, _, _ in MainActor.assumeIsolated { Native.hostWindows.contains(window) ? UInt64(window) : 0 } }
        bridge.window_host_unobserve = { _ in }
        bridge.window_set_root_view = { window, _ in MainActor.assumeIsolated { Native.hostWindows.contains(window) ? 1 : 0 } }
        bridge.window_set_chrome = { window, _ in MainActor.assumeIsolated { Native.hostWindows.contains(window) ? 1 : 0 } }
        bridge.tab_native_view = { window, tab in MainActor.assumeIsolated {
            guard Native.hostWindows.contains(window), Native.members[window]?.contains(tab) == true else { return nil }
            return Native.pageViews[tab].map { Unmanaged.passUnretained($0).toOpaque() }
        } }
        bridge.window_attach_native_shell = { window, pointer in MainActor.assumeIsolated {
            guard let pointer else { preconditionFailure("Unconditional header detach is forbidden") }
            if Native.hostWindows.contains(window) { Native.calls.append("attach refused"); return 0 }
            if Native.attachAccepted { Native.headers[window] = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue() }
            Native.calls.append("attach"); Native.onAttach?()
            return Native.attachAccepted ? 1 : 0
        } }
        bridge.window_select = { _ in MainActor.assumeIsolated { Native.calls.append("select"); return 1 } }
        bridge.window_discovery_state = { window, output in MainActor.assumeIsolated {
            guard let output, Native.members[window] != nil else { return 0 }
            output.pointee.window = window; output.pointee.physical_group = UInt64(window); output.pointee.selected_client = window
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

    static func close(_ window: Int32, flags: UInt32 = 128) {
        for (token, observer) in observers.filter({ $0.value.2 == window }) {
            observer.0?(observer.1, token, 7, window, observer.3, nil, nil, 0, flags)
            observers[token] = nil // Native CLOSED already ended observation.
        }
        if flags & 128 != 0 { headers[window] = nil }
    }
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
            precondition(Native.calls == ["open:" + profile.id.uuidString, "attach", "select", "navigate:" + route.1, "show"])
            Native.close(window, flags: 0)
            // A plain CLOSED reaches the presenter on a later main-actor turn.
            for _ in 0..<8 where presenter.ownsNativeWindow(window) { await Task.yield() }
            precondition(!presenter.ownsNativeWindow(window))
            precondition(Native.calls.last == "detach")
        }

        // In host mode the window's root view holds the controls and the page; Chromium is never
        // asked to attach or detach a sidebar.
        Native.hostWindows = [50]
        let hostPage = NSView()
        Native.pageViews = [500: hostPage]
        Native.calls = []
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(50)
        guard case .success = outcomes.removeLast() else { preconditionFailure("A host window opens the profile page") }
        precondition(Native.calls == ["open:" + profile.id.uuidString, "select", "navigate:chrome://extensions/", "show"], "\(Native.calls)")
        let hostRoot = sequence(first: hostPage as NSView, next: \.superview).lazy.compactMap { $0 as? ChromiumWindowRoot }.first
        precondition(hostRoot != nil && presenter.ownsNativeWindow(50), "The root shows the profile page")
        precondition(hostRoot!.subviews.contains { $0.subviews.first is NSHostingView<ChromiumProfilePageView> },
                     "The root holds the page's controls")
        Native.close(50, flags: 0)
        for _ in 0..<8 where presenter.ownsNativeWindow(50) { await Task.yield() }
        precondition(!presenter.ownsNativeWindow(50) && !Native.calls.contains("detach"), "Closing needs no detach")
        Native.hostWindows = []; Native.pageViews = [:]

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

        Native.calls = []; Native.attachAccepted = false
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(22)
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(!Native.calls.contains("show") && Native.calls.last == "close")
        precondition(Native.observers.values.contains { $0.2 == 22 })
        Native.close(22); Native.attachAccepted = true

        // An owner ending reentrantly during attachment cannot be shown/admitted.
        let beforeOwnerEndDetaches = Native.detachAttempts
        Native.calls = []; Native.onAttach = { Native.close(23) }
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(23); Native.onAttach = nil
        precondition(outcomes.count == 1)
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(!Native.calls.contains("show"))
        precondition(Native.detachAttempts == beforeOwnerEndDetaches)

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
        let header = Native.headers[40] as! NSHostingView<ChromiumProfilePageView>
        let controls = header.rootView
        let late = Native.observers.first!.value
        let lateToken = Native.observers.first!.key
        controls.goBack()
        precondition(Native.calls.last == "back:40:400")
        Native.calls = []
        Native.transfer(40, to: 41)
        precondition(Native.calls == ["detach"] && Native.observers.isEmpty && Native.headers[40] == nil)
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
        let queuedHeader = Native.headers[48] as! NSHostingView<ChromiumProfilePageView>
        Native.members[48]?.remove(480)
        Native.members[49, default: []].insert(480)
        Native.calls = []
        queuedHeader.rootView.close(); queuedHeader.rootView.reload()
        precondition(Native.calls.isEmpty)
        Native.transfer(48, to: 49)
        precondition(Native.calls == ["detach"] && Native.members[49]?.contains(480) == true)

        // Exact expected-view comparison preserves a replacement product header.
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(42)
        guard case .success = outcomes.removeLast() else { preconditionFailure() }
        let replacedHeader = Native.headers[42] as! NSHostingView<ChromiumProfilePageView>
        let replacementControls = replacedHeader.rootView
        let productHeader = NSView()
        Native.headers[42] = productHeader
        Native.calls = []
        replacementControls.close(); replacementControls.reload()
        replacementControls.goBack(); replacementControls.goForward()
        precondition(Native.calls.isEmpty && Native.headers[42] === productHeader)
        Native.transfer(42, to: 43)
        precondition(Native.headers[42] === productHeader && Native.calls.isEmpty)
        withExtendedLifetime(replacedHeader) {}

        // A reentrant replacement can win even when attachment returns zero.
        // Attempting attachment is enough to require exact header ownership
        // before any refusal cleanup may close a window.
        let rejectedReplacement = NSView()
        Native.calls = []
        Native.onAttach = {
            Native.headers[50] = rejectedReplacement
            Native.attachAccepted = false
        }
        presenter.open(profile, destination: .extensions, canPresent: { true }) { outcomes.append($0) }
        Native.opened(50); Native.onAttach = nil; Native.attachAccepted = true
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.headers[50] === rejectedReplacement)
        precondition(Native.calls == ["open:" + profile.id.uuidString, "attach"] && Native.observers.isEmpty)

        // Transfers inside pending native callbacks fail exactly once without
        // closing/showing/navigating the old owner or following the live tab.
        Native.calls = []
        Native.onAttach = { Native.transfer(44, to: 45) }
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(44); Native.onAttach = nil
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls == ["open:" + profile.id.uuidString, "attach", "detach"])
        precondition(Native.members[45]?.contains(440) == true && Native.observers.isEmpty)
        Native.calls = []
        Native.onShow = { Native.transfer(46, to: 47) }
        presenter.open(profile, destination: .privacy, canPresent: { true }) { outcomes.append($0) }
        Native.opened(46); Native.onShow = nil
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls.suffix(2) == ["show", "detach"] && !Native.calls.contains("close"))
        precondition(Native.members[47]?.contains(460) == true && outcomes.isEmpty && Native.observers.isEmpty)
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
        let recoveryHeader = Native.headers[70] as! NSHostingView<ChromiumProfilePageView>
        recoveryHeader.rootView.openRecovery()
        precondition(settingsOpened == 1)
        Native.headers[70] = NSView()
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
        precondition(recovery.isEmpty && Native.calls.suffix(1) == ["close"] && !Native.calls.contains("attach"))
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
        precondition(recovery.count == 2 && !Native.calls.contains("attach"))
        for result in recovery {
            guard case .failure(.presentationUnavailable) = result else { preconditionFailure() }
        }
        precondition(Native.observers.isEmpty)
        print("Chromium profile page checks passed")
    }
}
