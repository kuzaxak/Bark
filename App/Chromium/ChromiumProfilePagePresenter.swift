import AppKit
import Darwin
import NookTabsCore
import NookWeb
import SwiftUI

struct ChromiumProfilePageAPI {
    typealias Open = @convention(c) (UnsafePointer<CChar>?, Int32, ChromiumPageHostAPI.Callback?, UnsafeMutableRawPointer?) -> Void
    typealias CopyTitle = @convention(c) (Int32, Int32, UnsafeMutablePointer<CChar>?, Int) -> Int
    typealias DetachOwned = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32
    let open: Open
    let copyTitle: CopyTitle
    let detachOwned: DetachOwned
    let ownsHeader: DetachOwned
    let tabAt: ChromiumPageHostAPI.TabAt
    let attach: ChromiumPageHostAPI.Attach
    let select: ChromiumPageHostAPI.WindowCommand
    let show: ChromiumPageHostAPI.WindowCommand
    let close: ChromiumPageHostAPI.WindowCommand

    init(library: UnsafeMutableRawPointer) throws {
        func load<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw ChromiumNavigationError.missingSymbol(name) }
            return unsafeBitCast(address, to: T.self)
        }
        open = try load("barc_profile_open_window", Open.self)
        copyTitle = try load("barc_tab_copy_title", CopyTitle.self)
        // Additive runtime prerequisite: compare the actual NativeViewHost view
        // before detaching. Never substitute unconditional attach(nil).
        detachOwned = try load("barc_window_detach_native_shell_if_owned", DetachOwned.self)
        ownsHeader = try load("barc_window_native_shell_is_owned", DetachOwned.self)
        tabAt = try load("barc_window_tab_at", ChromiumPageHostAPI.TabAt.self)
        attach = try load("barc_window_attach_native_shell", ChromiumPageHostAPI.Attach.self)
        select = try load("barc_window_select", ChromiumPageHostAPI.WindowCommand.self)
        show = try load("barc_window_show", ChromiumPageHostAPI.WindowCommand.self)
        close = try load("barc_window_close", ChromiumPageHostAPI.WindowCommand.self)
    }

    init(open: @escaping Open, copyTitle: @escaping CopyTitle, detachOwned: @escaping DetachOwned, ownsHeader: @escaping DetachOwned, tabAt: @escaping ChromiumPageHostAPI.TabAt,
         attach: @escaping ChromiumPageHostAPI.Attach, select: @escaping ChromiumPageHostAPI.WindowCommand,
         show: @escaping ChromiumPageHostAPI.WindowCommand, close: @escaping ChromiumPageHostAPI.WindowCommand) {
        self.open = open; self.copyTitle = copyTitle; self.detachOwned = detachOwned; self.ownsHeader = ownsHeader
        self.tabAt = tabAt; self.attach = attach
        self.select = select; self.show = show; self.close = close
    }
}

/// Utility pages are native lifetimes, never saved tabs or an alternate profile registry.
@MainActor
final class ChromiumProfilePagePresenter {
    @MainActor private final class Request {
        let id = UUID()
        let profile: ProfileSummary
        let destination: ProfilePageDestination
        let canPresent: @MainActor () -> Bool
        var completion: (@MainActor (Result<Void, ProfilePageOpenError>) -> Void)?
        weak var presenter: ChromiumProfilePagePresenter?
        init(profile: ProfileSummary, destination: ProfilePageDestination,
             canPresent: @escaping @MainActor () -> Bool,
             completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
            self.profile = profile; self.destination = destination
            self.canPresent = canPresent; self.completion = completion
        }
    }
    private final class Page {
        let navigation: ChromiumPageNavigation
        var view: NSView?
        var attemptedAttach = false
        init(navigation: ChromiumPageNavigation) { self.navigation = navigation }
    }
    private let api: ChromiumProfilePageAPI
    private let navigationAPI: ChromiumNavigationAPI
    private var requests: [UUID: Request] = [:]
    private var pages: [Int32: Page] = [:]

    init(api: ChromiumProfilePageAPI, navigationAPI: ChromiumNavigationAPI) {
        self.api = api; self.navigationAPI = navigationAPI
    }

    /// Catalog exclusion is current utility ownership, not a permanent factory
    /// origin blacklist. A released utility window's later pages remain eligible.
    func ownsNativeWindow(_ window: Int32) -> Bool { pages[window] != nil }

    func open(_ profile: ProfileSummary, destination: ProfilePageDestination,
              canPresent: @escaping @MainActor () -> Bool,
              completion: @escaping @MainActor (Result<Void, ProfilePageOpenError>) -> Void) {
        guard canPresent() else { completion(.failure(.profileUnavailable)); return }
        let request = Request(profile: profile, destination: destination, canPresent: canPresent, completion: completion)
        request.presenter = self
        requests[request.id] = request
        profile.id.uuidString.withCString { uuid in
            api.open(uuid, 5, { status, window, pointer in
                MainActor.assumeIsolated {
                    guard let pointer else { return }
                    let request = Unmanaged<Request>.fromOpaque(pointer).takeUnretainedValue()
                    request.presenter?.opened(request, status: status, window: window)
                }
            }, Unmanaged.passUnretained(request).toOpaque())
        }
    }

    private func opened(_ request: Request, status: Int32, window: Int32) {
        guard requests[request.id] === request else { return }
        guard status == 0, window > 0, profileID(window) == request.profile.id else {
            finish(request, .failure(.presentationFailed)); return
        }
        let tab = api.tabAt(window, 0)
        guard tab > 0 else { finish(request, .failure(.presentationFailed)); return }
        guard request.canPresent() else {
            if api.copyTitle(window, tab, nil, 0) > 0 { _ = api.close(window) }
            finish(request, .failure(.profileUnavailable)); return
        }
        do {
            let navigation = try ChromiumPageNavigation(profileID: request.profile.id, window: window, tab: tab, api: navigationAPI)
            let page = Page(navigation: navigation)
            let canUse: () -> Bool = { [weak self, weak page] in
                guard let self, let page else { return false }
                return self.ownsControls(page, window: window)
            }
            let view = NSHostingView(rootView: ChromiumProfilePageView(profile: request.profile,
                navigation: navigation, canUse: canUse, close: { [weak self, weak page] in
                    guard let self, let page, self.ownsControls(page, window: window) else { return }
                    _ = self.api.close(window)
                }))
            page.view = view
            pages[window] = page
            navigation.onNativeOwnerChanged = { [weak self, weak page, weak request] owner in
                guard owner != window, let self, let page else { return }
                self.release(page, window: window)
                if let request { self.finish(request, .failure(.presentationFailed)) }
            }
            navigation.onNativeCloseOutcome = { [weak self, weak page, weak request] outcome in
                guard outcome != .cancelled, let self, let page else { return }
                self.release(page, window: window, detachHeader: outcome != .ownerEnded)
                if let request { self.finish(request, .failure(.presentationFailed)) }
            }
            guard request.canPresent(), ownsPage(page, window: window) else {
                refuse(request, window: window, page: page); return
            }
            page.attemptedAttach = true
            let attached = api.attach(window, Unmanaged.passUnretained(view).toOpaque()) == 1
            guard attached, request.canPresent(), ownsControls(page, window: window),
                  api.select(window) == 1, request.canPresent(), ownsControls(page, window: window) else {
                refuse(request, window: window, page: page); return
            }
            let accepted = request.destination.nativeURL.withCString { navigationAPI.navigate(window, tab, $0) }
            guard accepted == 1, request.canPresent(), ownsControls(page, window: window),
                  api.show(window) == 1, request.canPresent(), ownsControls(page, window: window) else {
                refuse(request, window: window, page: page); return
            }
            finish(request, .success(()))
        } catch {
            refuse(request, window: window, tab: tab)
        }
    }

    private func ownsPage(_ page: Page, window: Int32) -> Bool {
        pages[window] === page && !page.navigation.isClosed &&
        page.navigation.nativeWindowID == window &&
        profileID(window) == page.navigation.profileID &&
        api.copyTitle(window, page.navigation.nativeTabID, nil, 0) > 0
    }

    private func ownsControls(_ page: Page, window: Int32) -> Bool {
        guard ownsPage(page, window: window), let view = page.view else { return false }
        return api.ownsHeader(window, Unmanaged.passUnretained(view).toOpaque()) == 1
    }

    private func release(_ page: Page, window: Int32, detachHeader: Bool = true) {
        if pages[window] === page { pages.removeValue(forKey: window) }
        // Revoke controls before AppKit/native detachment callbacks can reenter.
        page.navigation.invalidate()
        if detachHeader, page.navigation.nativeCloseOutcome != .ownerEnded, let view = page.view {
            _ = api.detachOwned(window, Unmanaged.passUnretained(view).toOpaque())
        }
    }

    private func refuse(_ request: Request, window: Int32, page: Page? = nil, tab: Int32? = nil) {
        // Never close the old window after its page has moved or another header
        // replaced this one. Reentrant attach may finish after transfer cleanup;
        // compare-and-detach again to release only our own late attachment.
        if let page {
            if ownsPage(page, window: window),
               !page.attemptedAttach || ownsControls(page, window: window) || api.ownsHeader(window, nil) == 1 {
                _ = api.close(window)
            }
            else { release(page, window: window) }
        } else if let tab, profileID(window) == request.profile.id, api.copyTitle(window, tab, nil, 0) > 0 {
            _ = api.close(window)
        }
        finish(request, .failure(request.canPresent() ? .presentationFailed : .profileUnavailable))
    }

    private func finish(_ request: Request, _ result: Result<Void, ProfilePageOpenError>) {
        guard requests.removeValue(forKey: request.id) === request else { return }
        let callback = request.completion
        request.completion = nil
        callback?(result)
    }

    private func profileID(_ window: Int32) -> UUID? {
        var bytes = [CChar](repeating: 0, count: 37)
        guard navigationAPI.profileUUID(window, &bytes, bytes.count) == bytes.count else { return nil }
        return UUID(uuidString: String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}

private extension ProfilePageDestination {
    var nativeURL: String {
        switch self {
        case .settings: "chrome://settings/"
        case .extensions: "chrome://extensions/"
        case .privacy: "chrome://settings/privacy"
        case .siteSettings: "chrome://settings/content"
        case .clearData: "chrome://settings/clearBrowserData"
        }
    }
}

struct ChromiumProfilePageView: View {
    let profile: ProfileSummary
    let navigation: ChromiumPageNavigation
    let canUse: () -> Bool
    let close: () -> Void
    @State private var state = PageNavigationState(canGoBack: false, canGoForward: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(profile.name, systemImage: "person.crop.circle")
                .font(.headline)
            HStack {
                Button(action: goBack) { Image(systemName: "chevron.left") }
                    .disabled(!state.canGoBack).accessibilityLabel("Back")
                Button(action: goForward) { Image(systemName: "chevron.right") }
                    .disabled(!state.canGoForward).accessibilityLabel("Forward")
                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload")
            }
            Text(state.title ?? "Profile Settings").lineLimit(3)
            Button("Close Window", action: close)
            Spacer()
        }
        .padding(12)
        .onAppear {
            guard canUse() else { return }
            state = navigation.state
            let binding = $state
            navigation.onStateChanged = { if canUse() { binding.wrappedValue = $0 } }
        }
    }

    func goBack() { if canUse() { _ = navigation.goBack() } }
    func goForward() { if canUse() { _ = navigation.goForward() } }
    func reload() { if canUse() { _ = navigation.reload() } }

}
