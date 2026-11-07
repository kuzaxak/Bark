import AppKit
import Darwin
import NookTabsCore
import NookWeb
import SwiftUI

struct ChromiumProfilePageAPI {
    typealias Open = @convention(c) (UnsafePointer<CChar>?, Int32, ChromiumPageHostAPI.Callback?, UnsafeMutableRawPointer?) -> Void
    let open: Open
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
        tabAt = try load("barc_window_tab_at", ChromiumPageHostAPI.TabAt.self)
        attach = try load("barc_window_attach_native_shell", ChromiumPageHostAPI.Attach.self)
        select = try load("barc_window_select", ChromiumPageHostAPI.WindowCommand.self)
        show = try load("barc_window_show", ChromiumPageHostAPI.WindowCommand.self)
        close = try load("barc_window_close", ChromiumPageHostAPI.WindowCommand.self)
    }

    init(open: @escaping Open, tabAt: @escaping ChromiumPageHostAPI.TabAt,
         attach: @escaping ChromiumPageHostAPI.Attach, select: @escaping ChromiumPageHostAPI.WindowCommand,
         show: @escaping ChromiumPageHostAPI.WindowCommand, close: @escaping ChromiumPageHostAPI.WindowCommand) {
        self.open = open; self.tabAt = tabAt; self.attach = attach
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
    private struct Page {
        let navigation: ChromiumPageNavigation
        let view: NSView
    }
    private let api: ChromiumProfilePageAPI
    private let navigationAPI: ChromiumNavigationAPI
    private var requests: [UUID: Request] = [:]
    private var pages: [Int32: Page] = [:]

    init(api: ChromiumProfilePageAPI, navigationAPI: ChromiumNavigationAPI) {
        self.api = api; self.navigationAPI = navigationAPI
    }

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
        guard request.canPresent() else {
            _ = api.close(window)
            finish(request, .failure(.profileUnavailable)); return
        }
        let tab = api.tabAt(window, 0)
        guard tab > 0 else { refuse(request, window: window); return }
        do {
            let navigation = try ChromiumPageNavigation(profileID: request.profile.id, window: window, tab: tab, api: navigationAPI)
            let view = NSHostingView(rootView: ChromiumProfilePageView(profile: request.profile,
                navigation: navigation, close: { [weak self] in _ = self?.api.close(window) }))
            pages[window] = Page(navigation: navigation, view: view)
            let expectedProfile = request.profile.id
            navigation.onNativeCloseOutcome = { [weak self, weak request] outcome in
                guard outcome != .cancelled, let self else { return }
                let ended = self.pages.removeValue(forKey: window)
                if outcome == .closed, ended != nil, self.profileID(window) == expectedProfile {
                    _ = self.api.attach(window, nil)
                }
                if let request { self.finish(request, .failure(.presentationFailed)) }
            }
            guard api.attach(window, Unmanaged.passUnretained(view).toOpaque()) == 1,
                  pages[window] != nil, request.canPresent(), api.select(window) == 1,
                  pages[window] != nil, request.canPresent() else {
                refuse(request, window: window); return
            }
            let accepted = request.destination.nativeURL.withCString { navigationAPI.navigate(window, tab, $0) }
            guard accepted == 1, pages[window] != nil, request.canPresent(),
                  api.show(window) == 1, pages[window] != nil, request.canPresent() else {
                refuse(request, window: window); return
            }
            finish(request, .success(()))
        } catch {
            refuse(request, window: window)
        }
    }

    private func refuse(_ request: Request, window: Int32) {
        // A C dispatch is not proof of deletion. Keep the observed view alive
        // until its actual terminal event if native close is asynchronous.
        _ = api.close(window)
        if profileID(window) == nil { pages.removeValue(forKey: window)?.navigation.invalidate() }
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

private struct ChromiumProfilePageView: View {
    let profile: ProfileSummary
    let navigation: ChromiumPageNavigation
    let close: () -> Void
    @State private var state = PageNavigationState(canGoBack: false, canGoForward: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(profile.name, systemImage: "person.crop.circle")
                .font(.headline)
            HStack {
                Button { _ = navigation.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!state.canGoBack).accessibilityLabel("Back")
                Button { _ = navigation.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!state.canGoForward).accessibilityLabel("Forward")
                Button { _ = navigation.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload")
            }
            Text(state.title ?? "Profile Settings").lineLimit(3)
            Button("Close Window", action: close)
            Spacer()
        }
        .padding(12)
        .onAppear {
            state = navigation.state
            let binding = $state
            navigation.onStateChanged = { binding.wrappedValue = $0 }
        }
    }
}
