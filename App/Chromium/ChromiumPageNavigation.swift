// Licensed under GPL-3.0. See LICENSE.
import Darwin
import Foundation
import NookWeb

/// The additive C boundary in Runtime/Chromium/barc_bridge.h. Resolve once per
/// runtime, then share the functions between pages; no polling or extra views.
struct ChromiumNavigationAPI {
    typealias Callback = @convention(c) (
        UnsafeMutableRawPointer?, UInt64, Int32, Int32, Int32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UInt32
    ) -> Void
    typealias Observe = @convention(c) (Int32, Int32, Callback?, UnsafeMutableRawPointer?) -> UInt64
    typealias Unobserve = @convention(c) (UInt64) -> Void
    typealias Command = @convention(c) (Int32, Int32) -> Int32
    typealias Navigate = @convention(c) (Int32, Int32, UnsafePointer<CChar>?) -> Int32
    typealias PageCommand = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias ThumbnailCallback = @convention(c) (
        UnsafeMutableRawPointer?, UInt64, UInt64, UnsafePointer<UInt8>?, Int
    ) -> Void
    typealias CaptureThumbnail = @convention(c) (UInt64, UInt64, ThumbnailCallback?) -> Int32
    typealias SiteDataCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, Int32) -> Void
    typealias SiteData = @convention(c) (UInt64, UInt64, Int32, SiteDataCallback?) -> Int32
    typealias ProfileUUID = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int

    let observe: Observe
    let unobserve: Unobserve
    let navigate: Navigate
    let back: Command
    let forward: Command
    let reload: Command
    let stop: Command
    let select: Command
    let close: Command
    let captureThumbnail: CaptureThumbnail
    let clearSiteData: SiteData
    let profileUUID: ProfileUUID
    var executePageCommand: PageCommand? = nil
    var setMuted: PageCommand? = nil
    var privateSessionUUID: ProfileUUID = { _, _, _ in 0 }
}

extension ChromiumNavigationAPI {
    init(library: UnsafeMutableRawPointer) throws {
        func resolve<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(library, name) else {
                throw ChromiumNavigationError.missingSymbol(name)
            }
            return unsafeBitCast(address, to: T.self)
        }
        observe = try resolve("barc_tab_observe", Observe.self)
        unobserve = try resolve("barc_tab_unobserve", Unobserve.self)
        navigate = try resolve("barc_tab_navigate", Navigate.self)
        back = try resolve("barc_tab_go_back", Command.self)
        forward = try resolve("barc_tab_go_forward", Command.self)
        reload = try resolve("barc_tab_reload", Command.self)
        stop = try resolve("barc_tab_stop", Command.self)
        select = try resolve("barc_tab_select", Command.self)
        close = try resolve("barc_tab_close", Command.self)
        captureThumbnail = try resolve("barc_tab_capture_thumbnail", CaptureThumbnail.self)
        clearSiteData = try resolve("barc_tab_clear_site_data", SiteData.self)
        profileUUID = try resolve("barc_window_profile_uuid", ProfileUUID.self)
        executePageCommand = try resolve("barc_tab_execute_command", PageCommand.self)
        setMuted = try resolve("barc_tab_set_muted", PageCommand.self)
        privateSessionUUID = try resolve("barc_window_private_session_uuid", ProfileUUID.self)
    }
}

enum ChromiumSiteDataOutcome: Equatable { case completed, cancelled, failed }

enum ChromiumNavigationError: Error {
    case missingSymbol(String)
    case profileMismatch
    case observationRejected
}

/// Navigation for an existing Chromium tab. The native browser still owns its
/// surface and lifetime. Rebinding the page model never creates a second page.
@MainActor
final class ChromiumPageNavigation: PageNavigation {
    let profileID: UUID?
    let isPrivateSession: Bool
    private(set) var state = PageNavigationState(canGoBack: false, canGoForward: false)
    var onStateChanged: ((PageNavigationState) -> Void)?
    var onEvent: ((PageNavigationEvent) -> Void)?

    private let api: ChromiumNavigationAPI
    private let tab: Int32
    private var window: Int32
    private var nextThumbnailRequest: UInt64 = 0
    private var thumbnailGeneration: UInt64 = 0
    private var thumbnailRequest: (id: UInt64, generation: UInt64, window: Int32,
                                   completion: @MainActor (Data?) -> Void)?
    private var nextSiteDataRequest: UInt64 = 0
    private var siteDataRequest: (id: UInt64, window: Int32,
                                  completion: @MainActor (ChromiumSiteDataOutcome) -> Void)?
    private var observation: UInt64 = 0
    private var invalidated = false
    private(set) var isClosed = false
    private(set) var nativeCloseOutcome: PageCloseOutcome?
    var nativeWindowID: Int32 { window }
    var nativeTabID: Int32 { tab }
    // Host-only lifecycle channel. PageSession retains its event/state channels.
    var onNativeCloseOutcome: ((PageCloseOutcome) -> Void)?
    var onNativeOwnerChanged: ((Int32) -> Void)?
    private let context = CallbackContext()

    private final class CallbackContext {
        weak var owner: ChromiumPageNavigation?
    }

    init(profileID: UUID, window: Int32, tab: Int32, api: ChromiumNavigationAPI, privateSession: Bool = false) throws {
        // Verify the native owner, rather than trusting a caller's profile label.
        var uuid = [CChar](repeating: 0, count: 37)
        let query = privateSession ? api.privateSessionUUID : api.profileUUID
        let required = query(window, &uuid, uuid.count)
        guard required == uuid.count,
              UUID(uuidString: String(decoding: uuid.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)) == profileID else {
            throw ChromiumNavigationError.profileMismatch
        }
        self.profileID = profileID
        self.isPrivateSession = privateSession
        self.window = window
        self.tab = tab
        self.api = api
        context.owner = self
        let token = api.observe(window, tab, { pointer, token, event, window, tab, url, title, error, flags in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                // Copy borrowed strings before calling any client code, which
                // can close the tab or cancel this observation synchronously.
                context.owner?.receive(
                    token: token, event: event, window: window, tab: tab,
                    url: url.flatMap { URL(string: String(cString: $0)) },
                    title: title.map { String(cString: $0) }, error: error, flags: flags)
            }
        }, Unmanaged.passUnretained(context).toOpaque())
        guard token != 0, !invalidated else {
            invalidate()
            throw ChromiumNavigationError.observationRejected
        }
        observation = token
    }

    isolated deinit {
        if observation != 0 { api.unobserve(observation) }
    }

    func load(_ url: URL) {
        guard !invalidated, window > 0 else { return }
        let accepted = url.absoluteString.withCString { api.navigate(window, tab, $0) }
        if accepted != 1, !invalidated {
            let error = NSError(domain: "Barc.Chromium.Command", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "This tab is no longer available."])
            onEvent?(.failed(error, provisional: true, committedURL: state.url))
        }
    }

    @discardableResult func goBack() -> Bool { command(api.back) }
    @discardableResult func goForward() -> Bool { command(api.forward) }
    @discardableResult func reload() -> Bool { command(api.reload) }
    func stop() { _ = command(api.stop) }

    @discardableResult func selectNativePage() -> Bool { command(api.select) }
    @discardableResult func requestNativeClose() -> Bool { command(api.close) }

    private func command(_ action: ChromiumNavigationAPI.Command) -> Bool {
        !invalidated && window > 0 && action(window, tab) == 1
    }

    @discardableResult
    func executeNativePageCommand(_ command: Int32) -> Bool {
        guard !invalidated, !isClosed, window > 0, let execute = api.executePageCommand else { return false }
        return execute(window, tab, command) == 1
    }

    @discardableResult
    func setAudioMuted(_ muted: Bool) -> Bool {
        guard !invalidated, !isClosed, window > 0, let setMuted = api.setMuted else { return false }
        return setMuted(window, tab, muted ? 1 : 0) == 1
    }

    @discardableResult
    func captureThumbnail(completion: @escaping @MainActor (Data?) -> Void) -> Bool {
        guard !invalidated, !isClosed, observation != 0, window > 0,
              thumbnailRequest == nil, nextThumbnailRequest != UInt64.max else { return false }
        nextThumbnailRequest += 1
        let request = nextThumbnailRequest
        thumbnailRequest = (request, thumbnailGeneration, window, completion)
        let accepted = api.captureThumbnail(observation, request, { pointer, token, request, bytes, count in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                context.owner?.receivedThumbnail(token: token, request: request, bytes: bytes, count: count)
            }
        }) == 1
        if !accepted, thumbnailRequest?.id == request { thumbnailRequest = nil }
        return accepted
    }

    private func receivedThumbnail(token: UInt64, request: UInt64,
                                   bytes: UnsafePointer<UInt8>?, count: Int) {
        guard token == observation, let pending = thumbnailRequest, pending.id == request else { return }
        thumbnailRequest = nil
        guard !invalidated, !isClosed, pending.generation == thumbnailGeneration,
              pending.window == window, let bytes, count > 0, count <= 1_048_576 else {
            pending.completion(nil)
            return
        }
        pending.completion(Data(bytes: bytes, count: count))
    }

    private func cancelThumbnail() {
        thumbnailGeneration &+= 1
        let pending = thumbnailRequest
        thumbnailRequest = nil
        pending?.completion(nil)
    }

    @discardableResult
    func clearNativeSiteData(_ action: Int32,
                             completion: @escaping @MainActor (ChromiumSiteDataOutcome) -> Void) -> Bool {
        guard !invalidated, !isClosed, observation != 0, window > 0,
              siteDataRequest == nil, nextSiteDataRequest != UInt64.max else { return false }
        nextSiteDataRequest += 1
        let request = nextSiteDataRequest
        siteDataRequest = (request, window, completion)
        let accepted = api.clearSiteData(observation, request, action, { pointer, token, request, result in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                context.owner?.receivedSiteData(token: token, request: request, result: result)
            }
        }) == 1
        if !accepted, siteDataRequest?.id == request { siteDataRequest = nil }
        return accepted
    }

    private func receivedSiteData(token: UInt64, request: UInt64, result: Int32) {
        guard token == observation, let pending = siteDataRequest, pending.id == request else { return }
        siteDataRequest = nil
        guard !invalidated, !isClosed, pending.window == window else {
            pending.completion(.cancelled); return
        }
        pending.completion(result == 0 ? .completed : (result == 1 ? .cancelled : .failed))
    }

    private func cancelSiteData() {
        let pending = siteDataRequest
        siteDataRequest = nil
        pending?.completion(.cancelled)
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        cancelThumbnail()
        cancelSiteData()
        let token = observation
        observation = 0
        onStateChanged = nil
        onEvent = nil
        onNativeCloseOutcome = nil
        onNativeOwnerChanged = nil
        if token != 0 { api.unobserve(token) }
    }

    private func matchesProfile(_ window: Int32) -> Bool {
        var bytes = [CChar](repeating: 0, count: 37)
        let query = isPrivateSession ? api.privateSessionUUID : api.profileUUID
        guard query(window, &bytes, 37) == 37, bytes[36] == 0, !bytes[..<36].contains(0) else { return false }
        return UUID(uuidString: String(cString: bytes)) == profileID
    }

    private func receive(token: UInt64, event: Int32, window: Int32, tab: Int32,
                         url: URL?, title: String?, error: Int32, flags: UInt32) {
        guard !invalidated, tab == self.tab, token != 0,
              observation == 0 || observation == token else { return }
        // A Browser's Profile/SessionID are immutable. Validate only a new
        // nonzero owner, never allocate/parse UUIDs for unchanged state/title.
        // Owner zero is detached/non-commandable; terminal delivery remains
        // valid after the old native owner has already disappeared.
        guard event == 7 || window == self.window || window == 0 || matchesProfile(window) else { return }
        observation = token  // INITIAL can call out before observe() returns.
        let ownerChanged = self.window != window
        self.window = window  // A live transfer changes the owner, never the page.
        if ownerChanged {
            cancelThumbnail()
            cancelSiteData()
            onNativeOwnerChanged?(window)
        }
        guard !invalidated else { return }
        if event == 8 { // CLOSE_CANCELLED is not navigation cancellation.
            onNativeCloseOutcome?(.cancelled)
            return
        }
        if event == 7 { // CLOSED: the engine has already ended observation.
            observation = 0
            isClosed = true
            let outcome: PageCloseOutcome = flags & 128 != 0 ? .ownerEnded : .closed
            nativeCloseOutcome = outcome
            let notify = onEvent
            let closeOutcome = onNativeCloseOutcome
            invalidate()
            // Let a pending unload/delete finish before the general closed
            // event can be interpreted as an unsolicited model deletion.
            closeOutcome?(outcome)
            notify?(outcome == .ownerEnded ? .ownerEnded : .closed)
            return
        }
        let snapshot = PageNavigationState(
            url: url, title: title, isLoading: flags & 1 != 0,
            canGoBack: flags & 2 != 0, canGoForward: flags & 4 != 0,
            isAudioMuted: flags & 256 != 0, isAudible: flags & 512 != 0)
        if state != snapshot {
            state = snapshot
            onStateChanged?(snapshot)
        }
        guard !invalidated else { return }
        if event == 1 || event == 2 { cancelThumbnail() }
        guard !invalidated else { return }
        switch event {
        case 1: onEvent?(.started(url))
        case 2: onEvent?(.committed(url, sameDocument: flags & 16 != 0))
        case 3: onEvent?(.finished(url, title: title, isReload: flags & 8 != 0))
        case 4:
            if flags & 64 != 0 {
                onEvent?(.cancelled(committedURL: url))
                return
            }
            let failure = NSError(domain: "Barc.Chromium.Navigation", code: Int(error),
                                  userInfo: [NSLocalizedDescriptionKey: "The page could not be loaded."])
            onEvent?(.failed(failure, provisional: flags & 32 != 0, committedURL: url))
        case 5: if let title { onEvent?(.titleChanged(title)) }
        default: break  // INITIAL and STATE never invent a history visit.
        }
    }
}
