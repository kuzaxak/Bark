import AppKit
import NookTabsCore
import NookWeb

@MainActor
private enum Native {
    static var callback: ChromiumPageHostAPI.Callback?
    static var context: UnsafeMutableRawPointer?
    static var profile = UUID()
    static var calls: [String] = []
    static var observers: [UInt64: (ChromiumNavigationAPI.Callback?, UnsafeMutableRawPointer?, Int32, Int32)] = [:]
    static var token: UInt64 = 1
    static var attachAccepted = true
    static var showAccepted = true
    static var onAttach: (() -> Void)?
    static var onShow: (() -> Void)?

    static var api: ChromiumProfilePageAPI {
        ChromiumProfilePageAPI(open: { uuid, destination, callback, context in MainActor.assumeIsolated {
            precondition(destination == 5, "Utility construction must remain hidden")
            Native.calls.append("open:" + String(cString: uuid!))
            Native.callback = callback; Native.context = context
        } }, tabAt: { _, _ in 100 }, attach: { _, pointer in MainActor.assumeIsolated {
            if pointer == nil { Native.calls.append("detach"); return 1 }
            Native.calls.append("attach"); Native.onAttach?()
            return Native.attachAccepted ? 1 : 0
        } }, select: { _ in MainActor.assumeIsolated { Native.calls.append("select"); return 1 } },
        show: { _ in MainActor.assumeIsolated {
            Native.calls.append("show"); Native.onShow?()
            return Native.showAccepted ? 1 : 0
        } }, close: { _ in MainActor.assumeIsolated { Native.calls.append("close"); return 1 } })
    }

    static var navigation: ChromiumNavigationAPI {
        ChromiumNavigationAPI(observe: { window, tab, callback, context in MainActor.assumeIsolated {
            let token = Native.token; Native.token += 1
            Native.observers[token] = (callback, context, window, tab)
            return token
        } }, unobserve: { token in MainActor.assumeIsolated { Native.observers[token] = nil } },
        navigate: { _, _, url in MainActor.assumeIsolated {
            Native.calls.append("navigate:" + String(cString: url!)); return 1
        } }, back: { _, _ in 1 }, forward: { _, _ in 1 }, reload: { _, _ in 1 }, stop: { _, _ in 1 },
        select: { _, _ in 1 }, close: { _, _ in 1 },
        profileUUID: { _, pointer, capacity in MainActor.assumeIsolated {
            let bytes = Array(Native.profile.uuidString.utf8CString)
            if let pointer, capacity >= bytes.count {
                for (index, byte) in bytes.enumerated() { pointer[index] = byte }
            }
            return bytes.count
        } })
    }

    static func opened(_ window: Int32) {
        let callback = self.callback, context = self.context
        self.callback = nil; self.context = nil
        callback?(0, window, context)
    }

    static func close(_ window: Int32, flags: UInt32 = 128) {
        for (token, observer) in observers.filter({ $0.value.2 == window }) {
            observer.0?(observer.1, token, 7, window, observer.3, nil, nil, 0, flags)
            observers[token] = nil // Native CLOSED already ended observation.
        }
    }
}

@main
private enum ProfileChecks {
    @MainActor static func main() throws {
        var tree = TabTree()
        let space = UUID()
        tree.createSpace(id: space, name: "Work", icon: "briefcase", accentHex: "#000000", after: nil)
        let profile = tree.profiles.first!
        Native.profile = profile.id
        let presenter = ChromiumProfilePagePresenter(api: Native.api, navigationAPI: Native.navigation)
        var outcomes: [Result<Void, ProfilePageOpenError>] = []
        presenter.open(profile, destination: .settings, canPresent: { false }) { outcomes.append($0) }
        precondition(Native.calls.isEmpty)
        guard case .failure(.profileUnavailable) = outcomes.removeLast() else { preconditionFailure() }

        let routes: [(ProfilePageDestination, String)] = [(.settings, "chrome://settings/"),
            (.extensions, "chrome://extensions/"), (.privacy, "chrome://settings/privacy"),
            (.siteSettings, "chrome://settings/content"), (.clearData, "chrome://settings/clearBrowserData")]
        for (index, route) in routes.enumerated() {
            Native.calls = []
            presenter.open(profile, destination: route.0, canPresent: { true }) { outcomes.append($0) }
            precondition(outcomes.isEmpty, "Dispatch is not admission")
            let window = Int32(index + 10)
            Native.opened(window)
            guard case .success = outcomes.removeLast() else { preconditionFailure() }
            precondition(Native.calls == ["open:" + profile.id.uuidString, "attach", "select", "navigate:" + route.1, "show"])
            Native.close(window, flags: 0)
            precondition(Native.calls.last == "detach")
        }

        // A kept/no-space identity is presented directly, never under the active space.
        let kept = TabTree().profiles(keeping: [KeptProfile(profile)]).first!
        precondition(kept.spaceIDs.isEmpty && kept.id == profile.id)
        Native.calls = []
        presenter.open(kept, destination: .siteSettings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(30)
        guard case .success = outcomes.removeLast() else { preconditionFailure() }
        precondition(Native.calls.first == "open:" + kept.id.uuidString)
        Native.close(30)
        var available = true
        Native.calls = []
        presenter.open(kept, destination: .privacy, canPresent: { available }) { outcomes.append($0) }
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
        Native.calls = []; Native.onAttach = { Native.close(23) }
        presenter.open(profile, destination: .settings, canPresent: { true }) { outcomes.append($0) }
        Native.opened(23); Native.onAttach = nil
        precondition(outcomes.count == 1)
        guard case .failure(.presentationFailed) = outcomes.removeLast() else { preconditionFailure() }
        precondition(!Native.calls.contains("show"))

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
        Native.close(24)
        precondition(Native.observers.isEmpty)
        print("Chromium profile page checks passed")
    }
}
