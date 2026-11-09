// Licensed under GPL-3.0. See LICENSE.
import BarcChromium
import Darwin
import Foundation
import AppKit
import NookBlocker
import NookWeb

/// The additive C boundary in Runtime/Chromium/barc_bridge.h. Resolve once per
/// runtime, then share the functions between pages; no polling or extra views.
struct ChromiumNavigationAPI {
    typealias Callback = @convention(c) (
        UnsafeMutableRawPointer?, UInt64, Int32, Int32, Int32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UInt32
    ) -> Void
    typealias Observe = @convention(c) (Int32, Int32, Callback?, UnsafeMutableRawPointer?) -> UInt64
    typealias PeekAdmission = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32
    typealias EnablePeek = @convention(c) (UInt64, Int32) -> Int32
    typealias CreatePeek = @convention(c) (UInt64, Int32, PeekAdmission?, UnsafeMutableRawPointer?) -> Int32
    typealias Unobserve = @convention(c) (UInt64) -> Void
    typealias Command = @convention(c) (Int32, Int32) -> Int32
    typealias History = @convention(c) (Int32, Int32, Int32, UnsafeMutablePointer<CChar>?, Int) -> Int
    typealias HistoryGo = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias Search = @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias Navigate = @convention(c) (Int32, Int32, UnsafePointer<CChar>?) -> Int32
    typealias PageCommand = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias ThumbnailCallback = @convention(c) (
        UnsafeMutableRawPointer?, UInt64, UInt64, UnsafePointer<UInt8>?, Int
    ) -> Void
    typealias CaptureScreenshot = @convention(c) (UInt64, UInt64, Int32, ThumbnailCallback?) -> Int32
    typealias CancelCapture = @convention(c) (UInt64, UInt64) -> Int32
    typealias CaptureThumbnail = @convention(c) (UInt64, UInt64, ThumbnailCallback?) -> Int32
    typealias FileCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, Int32, Int32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int64, Int32) -> Void
    typealias DownloadFile = @convention(c) (UInt64, UInt64, UnsafePointer<CChar>?, UnsafePointer<CChar>?, FileCallback?) -> Int32
    typealias CancelFile = @convention(c) (UInt64, UInt64) -> Int32
    typealias SiteDataCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, Int32) -> Void
    typealias SiteData = @convention(c) (UInt64, UInt64, Int32, SiteDataCallback?) -> Int32
    typealias MediaCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, Int32, Int32, UInt32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    typealias ObserveMedia = @convention(c) (UInt64, MediaCallback?) -> Int32
    typealias StyleCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, Int32) -> Void
    typealias UserCSS = @convention(c) (UInt64, UInt64, UnsafePointer<CChar>?, UnsafePointer<CChar>?, StyleCallback?) -> Int32
    typealias TranslationCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, UInt64, Int32, UnsafePointer<CChar>?) -> Void
    typealias Translation = @convention(c) (UInt64, UInt64, UInt64, Int32, UnsafePointer<CChar>?, TranslationCallback?) -> Int32
    typealias ScriptCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, Int32,
        UnsafePointer<CChar>?, Int, UnsafePointer<CChar>?, Int, Int32) -> Void
    typealias EvaluateScript = @convention(c) (UInt64, UInt64, Int32, Int32, UnsafePointer<CChar>?, ScriptCallback?) -> Int32
    typealias CancelScript = @convention(c) (UInt64, UInt64) -> Int32
    typealias PickerCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, UnsafePointer<CChar>?, Int) -> Void
    typealias StartPicker = @convention(c) (UInt64, UInt64, PickerCallback?) -> Int32
    typealias ProfileUUID = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int
    typealias VaultCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?, Double, Double, Double, Double) -> Void
    typealias VaultSaveCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias ObserveVaultSave = @convention(c) (UInt64, VaultSaveCallback?) -> Int32
    typealias VaultPasskeyCallback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias ObserveVaultPasskeys = @convention(c) (UInt64, VaultPasskeyCallback?) -> Int32
    typealias CompleteVaultPasskey = @convention(c) (UInt64, UInt64, Int32, UnsafePointer<CChar>?) -> Int32
    typealias ObserveVault = @convention(c) (UInt64, VaultCallback?) -> Int32
    typealias VaultCurrent = @convention(c) (UInt64, UInt64) -> Int32
    typealias VaultFill = @convention(c) (UInt64, UInt64, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias BlockingPolicy = @convention(c) (Int32, Int32, Int32, UnsafePointer<CChar>?, UInt64) -> Int32

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
    var downloadFile: DownloadFile? = nil
    var cancelFile: CancelFile? = nil
    var captureScreenshot: CaptureScreenshot? = nil
    var cancelCapture: CancelCapture? = nil
    var executePageCommand: PageCommand? = nil
    var setMuted: PageCommand? = nil
    var observeMedia: ObserveMedia? = nil
    var mediaAction: PageCommand? = nil
    var setUserCSS: UserCSS? = nil
    var translate: Translation? = nil
    var evaluateScript: EvaluateScript? = nil
    var cancelScript: CancelScript? = nil
    var startPicker: StartPicker? = nil
    var cancelPicker: CancelScript? = nil
    var createPeek: CreatePeek? = nil
    var enablePeek: EnablePeek? = nil
    var applyBlockingPolicy: BlockingPolicy? = nil
    var search: Search? = nil
    var history: History? = nil
    var historyGo: HistoryGo? = nil
    var observeVaultPasskeys: ObserveVaultPasskeys? = nil
    var vaultPasskeyCurrent: VaultCurrent? = nil
    var completeVaultPasskey: CompleteVaultPasskey? = nil
    var observeVault: ObserveVault? = nil
    var observeVaultSave: ObserveVaultSave? = nil
    var vaultSaveCurrent: VaultCurrent? = nil
    var cancelVaultSave: VaultCurrent? = nil
    var vaultCurrent: VaultCurrent? = nil
    var vaultFieldCurrent: VaultCurrent? = nil
    var cancelVaultFocus: VaultCurrent? = nil
    var vaultFill: VaultFill? = nil
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
        search = try resolve("barc_tab_search", Search.self)
        observeVaultSave = try resolve("barc_tab_observe_vault_save", ObserveVaultSave.self)
        vaultSaveCurrent = try resolve("barc_tab_vault_save_is_current", VaultCurrent.self)
        cancelVaultSave = try resolve("barc_tab_cancel_vault_save", VaultCurrent.self)
        observeVaultPasskeys = try resolve("barc_tab_observe_vault_passkeys", ObserveVaultPasskeys.self)
        vaultPasskeyCurrent = try resolve("barc_tab_vault_passkey_is_current", VaultCurrent.self)
        completeVaultPasskey = try resolve("barc_tab_complete_vault_passkey", CompleteVaultPasskey.self)
        observeVault = try resolve("barc_tab_observe_vault", ObserveVault.self)
        vaultCurrent = try resolve("barc_tab_vault_focus_is_current", VaultCurrent.self)
        vaultFieldCurrent = try resolve("barc_tab_vault_field_is_current", VaultCurrent.self)
        cancelVaultFocus = try resolve("barc_tab_cancel_vault_focus", VaultCurrent.self)
        vaultFill = try resolve("barc_tab_fill_vault", VaultFill.self)
        history = try resolve("barc_tab_copy_history", History.self)
        historyGo = try resolve("barc_tab_go_to_history_entry", HistoryGo.self)
        back = try resolve("barc_tab_go_back", Command.self)
        forward = try resolve("barc_tab_go_forward", Command.self)
        reload = try resolve("barc_tab_reload", Command.self)
        stop = try resolve("barc_tab_stop", Command.self)
        select = try resolve("barc_tab_select", Command.self)
        close = try resolve("barc_tab_close", Command.self)
        captureThumbnail = try resolve("barc_tab_capture_thumbnail", CaptureThumbnail.self)
        downloadFile = try resolve("barc_tab_download_file", DownloadFile.self)
        cancelFile = try resolve("barc_tab_cancel_file", CancelFile.self)
        captureScreenshot = try resolve("barc_tab_capture_screenshot", CaptureScreenshot.self)
        cancelCapture = try resolve("barc_tab_cancel_capture", CancelCapture.self)
        clearSiteData = try resolve("barc_tab_clear_site_data", SiteData.self)
        profileUUID = try resolve("barc_window_profile_uuid", ProfileUUID.self)
        executePageCommand = try resolve("barc_tab_execute_command", PageCommand.self)
        setMuted = try resolve("barc_tab_set_muted", PageCommand.self)
        observeMedia = try resolve("barc_tab_observe_media", ObserveMedia.self)
        mediaAction = try resolve("barc_tab_media_action", PageCommand.self)
        setUserCSS = try resolve("barc_tab_set_user_css", UserCSS.self)
        translate = try resolve("barc_tab_translate", Translation.self)
        evaluateScript = try resolve("barc_tab_evaluate_script", EvaluateScript.self)
        cancelScript = try resolve("barc_tab_cancel_script", CancelScript.self)
        startPicker = try resolve("barc_tab_start_boost_picker", StartPicker.self)
        cancelPicker = try resolve("barc_tab_cancel_boost_picker", CancelScript.self)
        createPeek = try resolve("barc_tab_create_peek", CreatePeek.self)
        enablePeek = try resolve("barc_tab_enable_peek", EnablePeek.self)
        applyBlockingPolicy = try resolve("barc_blocker_set_tab_policy", BlockingPolicy.self)
        privateSessionUUID = try resolve("barc_window_private_session_uuid", ProfileUUID.self)
    }
}

enum ChromiumSiteDataOutcome: Equatable { case completed, cancelled, failed }

enum ChromiumNavigationError: Error {
    case missingSymbol(String)
    case profileMismatch
    case fileDownloadUnavailable
    case screenshotBounds, screenshotUnavailable
    case observationRejected
}

struct ChromiumDownloadedFile: Sendable {
    let result: Int32
    let status: Int32
    let temporary: DevMCPTemporaryFile?
    let contentType: String
    let bytes: Int64
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

    private var vaultSaveCallback: (@MainActor (VaultNativeSubmission?) -> Void)?
    private var vaultPasskeyCallback: (@MainActor (VaultNativePasskeyRequest?) -> Void)?
    private var vaultCallback: (@MainActor (VaultNativeFocus?) -> Void)?
    private let api: ChromiumNavigationAPI
    private let tab: Int32
    private var window: Int32
    private var nextThumbnailRequest: UInt64 = 0
    private var thumbnailGeneration: UInt64 = 0
    private var thumbnailRequest: (id: UInt64, generation: UInt64, window: Int32, limit: Int,
                                   completion: @MainActor (Data?) -> Void)?
    private var nextFileRequest: UInt64 = 0
    private var fileRequests: [UInt64: (window: Int32, directory: URL, completion: (Result<ChromiumDownloadedFile, Error>) -> Void)] = [:]
    private var nextSiteDataRequest: UInt64 = 0
    private var siteDataRequest: (id: UInt64, window: Int32,
                                  completion: @MainActor (ChromiumSiteDataOutcome) -> Void)?
    var onTranslationNodes: (([PageTranslationNode]?) -> Void)?
    private var translationGeneration: UInt64 = 1
    private var nextTranslationRequest: UInt64 = 0
    private var translationRequest: (id: UInt64, completion: @MainActor (PageTranslationResult?) -> Void)?
    private var nextScriptRequest: UInt64 = 0
    private var scriptRequest: (id: UInt64, continuation: CheckedContinuation<ScriptResult, Error>)?
    private var nextStyleRequest: UInt64 = 0
    private var styleRequest: (id: UInt64, window: Int32, completion: @MainActor (Bool) -> Void)?
    private var observation: UInt64 = 0
    private var pendingPeekRequest: Int32 = 0
    private var peekEnabled = false
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
        if let observeMedia = api.observeMedia {
            let accepted = observeMedia(token, { pointer, token, window, tab, flags, title, artist, album in
                MainActor.assumeIsolated {
                    guard let pointer else { return }
                    let title = title.map { String(cString: $0) }, artist = artist.map { String(cString: $0) }
                    let album = album.map { String(cString: $0) }
                    let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                    context.owner?.receiveMedia(token: token, window: window, tab: tab, flags: flags,
                                                title: title, artist: artist, album: album)
                }
            })
            guard accepted == 1, !invalidated else {
                invalidate(); throw ChromiumNavigationError.observationRejected
            }
        }
    }

    isolated deinit {
        if observation != 0 { api.unobserve(observation) }
    }

    func search(_ query: String, kagiSessionToken: String?) -> Bool {
        guard !invalidated, window > 0, let command = api.search else { return false }
        let accepted = query.withCString { query in
            if let token = kagiSessionToken { return token.withCString { command(window, tab, query, $0) } }
            return command(window, tab, query, nil)
        }
        return accepted == 1 && !invalidated
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

    func historyEntries(forward: Bool) -> [PageHistoryEntry] {
        guard !invalidated, !isClosed, window > 0, let read = api.history else { return [] }
        let owner = window
        let count = read(owner, tab, forward ? 1 : 0, nil, 0)
        guard count > 1, count <= 1_048_576, !invalidated, window == owner else { return [] }
        var bytes = [CChar](repeating: 0, count: count)
        let copied = read(owner, tab, forward ? 1 : 0, &bytes, count)
        guard copied == count, bytes.last == 0, !invalidated, window == owner,
              let entries = try? JSONDecoder().decode([PageHistoryEntry].self,
                  from: Data(bytes.dropLast().map { UInt8(bitPattern: $0) })),
              entries.count <= 100, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.id > 0 && $0.title.utf8.count <= 4096 && $0.url.absoluteString.utf8.count <= 8192 }) else { return [] }
        return entries
    }
    @discardableResult func goToHistoryEntry(_ id: Int32) -> Bool {
        guard !invalidated, !isClosed, window > 0, id > 0, let go = api.historyGo else { return false }
        return go(window, tab, id) == 1
    }

    @discardableResult func goBack() -> Bool { command(api.back) }
    @discardableResult func goForward() -> Bool { command(api.forward) }
    @discardableResult func reload() -> Bool { command(api.reload) }
    func stop() { _ = command(api.stop) }

    @discardableResult func applyBlockingPolicy(_ policy: ContentBlockerManager.NetworkPagePolicy) -> Bool {
        guard !invalidated, !isClosed, window > 0, observation != 0,
              let apply = api.applyBlockingPolicy else { return false }
        let remaining = max(0, policy.disabledUntil?.timeIntervalSinceNow ?? 0)
        let milliseconds = UInt64(min(remaining * 1_000, Double(Int64.max).nextDown).rounded(.up))
        if let host = policy.continuedHost {
            return host.withCString { apply(window, tab, policy.isOAuthFlow ? 1 : 0, $0, milliseconds) == 1 }
        }
        return apply(window, tab, policy.isOAuthFlow ? 1 : 0, nil, milliseconds) == 1
    }

    @discardableResult
    func setNativePeekCapability(_ enabled: Bool) -> Bool {
        if !enabled { peekEnabled = false; pendingPeekRequest = 0 }
        guard !invalidated, !isClosed, observation != 0, let enable = api.enablePeek,
              enable(observation, enabled ? 1 : 0) == 1 else { return false }
        peekEnabled = enabled
        return true
    }

    var pendingPeekRequestID: Int32? {
        !invalidated && !isClosed && peekEnabled && pendingPeekRequest > 0 ? pendingPeekRequest : nil
    }

    /// Called only after PageSession leaves the native observer stack. Native
    /// admission consumes the captured document intent, never a caller URL.
    func createNativePeek(request: Int32, admission: ChromiumNavigationAPI.PeekAdmission,
                          context: UnsafeMutableRawPointer?) -> Bool {
        guard !invalidated, !isClosed, window > 0, observation != 0,
              request > 0, pendingPeekRequest == request,
              let create = api.createPeek else { return false }
        let accepted = create(observation, request, admission, context) == 1
        if pendingPeekRequest == request { pendingPeekRequest = 0 }
        return accepted
    }

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
    func clearBackForwardCache() -> Bool {
        executeNativePageCommand(Int32(BARC_PAGE_CLEAR_BACK_FORWARD_CACHE.rawValue))
    }

    @discardableResult
    func requestPictureInPicture() -> Bool {
        executeNativePageCommand(Int32(BARC_PAGE_VIDEO_PIP_TOGGLE.rawValue))
    }

    @discardableResult
    func setPlaybackPaused(_ paused: Bool) -> Bool {
        guard !invalidated, !isClosed, window > 0, let action = api.mediaAction else { return false }
        return action(window, tab, paused ? 1 : 0) == 1
    }

    @discardableResult
    func skipTrack(forward: Bool) -> Bool {
        guard !invalidated, !isClosed, window > 0, let action = api.mediaAction else { return false }
        return action(window, tab, forward ? 3 : 2) == 1
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
        thumbnailRequest = (request, thumbnailGeneration, window, 1_048_576, completion)
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
              pending.window == window, let bytes, count > 0, count <= pending.limit else {
            pending.completion(nil)
            return
        }
        pending.completion(Data(bytes: bytes, count: count))
    }

    private func cancelThumbnail() {
        thumbnailGeneration &+= 1
        let pending = thumbnailRequest
        thumbnailRequest = nil
        if let pending { _ = api.cancelCapture?(observation, pending.id) }
        pending?.completion(nil)
    }

    private final class ScreenshotRequest {
        var id: UInt64?
    }
    /// Copies only the retained last-rendered viewport; never shows/wakes a page.
    func captureScreenshot(maxWidth: Double = 1200) async throws -> Data {
        guard maxWidth.isFinite, maxWidth >= 1, maxWidth <= 4096,
              maxWidth.rounded(.towardZero) == maxWidth else {
            throw ChromiumNavigationError.screenshotBounds
        }
        let request = ScreenshotRequest()
        let result: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !invalidated, !isClosed, observation != 0, window > 0,
                      thumbnailRequest == nil, nextThumbnailRequest != UInt64.max,
                      let capture = api.captureScreenshot else {
                    continuation.resume(throwing: ChromiumNavigationError.screenshotUnavailable)
                    return
                }
                nextThumbnailRequest += 1
                let id = nextThumbnailRequest
                request.id = id
                thumbnailRequest = (id, thumbnailGeneration, window, 8_388_608, { bytes in
                    if let bytes { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: ChromiumNavigationError.screenshotUnavailable) }
                })
                let accepted = capture(observation, id, Int32(maxWidth), { pointer, token, request, bytes, count in
                    MainActor.assumeIsolated {
                        guard let pointer else { return }
                        let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                        context.owner?.receivedThumbnail(token: token, request: request, bytes: bytes, count: count)
                    }
                }) == 1
                if !accepted, thumbnailRequest?.id == id { cancelThumbnail() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let id = request.id, self.thumbnailRequest?.id == id else { return }
                self.cancelThumbnail()
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func cancelFileDownload(_ id: UInt64) {
        guard let request = fileRequests.removeValue(forKey: id) else { return }
        _ = api.cancelFile?(observation, id)
        request.completion(.failure(CancellationError()))
    }
    private func cancelFileDownloads() {
        let requests = fileRequests
        fileRequests.removeAll()
        for (id, request) in requests {
            _ = api.cancelFile?(observation, id)
            request.completion(.failure(CancellationError()))
        }
    }
    private static func fileString(_ pointer: UnsafePointer<CChar>?,limit:Int)->String? {
        guard let pointer else{return nil}
        let count=strnlen(pointer,limit+1);guard count<=limit else{return nil}
        return String(decoding:UnsafeBufferPointer(start:UnsafeRawPointer(pointer).assumingMemoryBound(to:UInt8.self),count:count),as:UTF8.self)
    }
    private static func takeDownloadedTemporary(_ path:UnsafePointer<CChar>?,directory:Int32)->DevMCPTemporaryFile? {
        guard directory>=0 else{return nil}
        guard let path=fileString(path,limit:4096),path.hasPrefix("/"),
              URL(fileURLWithPath:path).lastPathComponent.hasPrefix(".devmcp-") else {
            Task.detached{close(directory)};return nil
        }
        return DevMCPTemporaryFile(url:URL(fileURLWithPath:path),directoryDescriptor:directory)
    }
    private func receivedFile(token:UInt64,request:UInt64,result:Int32,status:Int32,
                              path:UnsafePointer<CChar>?,mime:UnsafePointer<CChar>?,bytes:Int64,directory:Int32) {
        let temporary=Self.takeDownloadedTemporary(path,directory:directory)
        guard token==observation,let pending=fileRequests.removeValue(forKey:request) else{return}
        guard temporary==nil || temporary?.url.deletingLastPathComponent().path==pending.directory.path else {
            pending.completion(.failure(ChromiumNavigationError.fileDownloadUnavailable));return
        }
        guard !invalidated,!isClosed,pending.window==window,result != 1,bytes>=0,
              result != 0 || (temporary != nil && bytes<=100*1024*1024) else {
            pending.completion(.failure(CancellationError()));return
        }
        pending.completion(.success(.init(result:result,status:status,temporary:temporary,
            contentType:Self.fileString(mime,limit:1024) ?? "",bytes:bytes)))
    }
    /// Authorized DevMCP job; credentials never leave the exact observed Profile.
    func downloadFile(_ url: URL, directory: URL) async throws -> ChromiumDownloadedFile {
        guard let directory = DevMCPFiles.nativeDirectory(directory) else {
            throw ChromiumNavigationError.fileDownloadUnavailable
        }
        let request = ScreenshotRequest()
        let result: ChromiumDownloadedFile = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !invalidated, !isClosed, observation != 0, window > 0,
                      fileRequests.count < 6, nextFileRequest != .max, let start = api.downloadFile,
                      url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                      directory.isFileURL, !url.absoluteString.utf8.contains(0), !directory.path.utf8.contains(0) else {
                    continuation.resume(throwing: ChromiumNavigationError.fileDownloadUnavailable);return
                }
                nextFileRequest += 1
                let id = nextFileRequest;request.id = id
                fileRequests[id] = (window, directory, { continuation.resume(with: $0) })
                let accepted = url.absoluteString.withCString { url in directory.path.withCString { directory in
                    start(observation,id,url,directory,{ pointer,token,request,result,status,path,mime,bytes,directoryDescriptor in
                        MainActor.assumeIsolated {
                            guard let pointer else { _=ChromiumPageNavigation.takeDownloadedTemporary(path,directory:directoryDescriptor);return }
                            let context=Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                            if let owner=context.owner {
                                owner.receivedFile(token:token,request:request,result:result,status:status,path:path,mime:mime,bytes:bytes,directory:directoryDescriptor)
                            } else { _=ChromiumPageNavigation.takeDownloadedTemporary(path,directory:directoryDescriptor) }
                        }
                    })
                } } == 1
                if !accepted, let pending = fileRequests.removeValue(forKey: id) {
                    pending.completion(.failure(ChromiumNavigationError.fileDownloadUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in if let id = request.id { self?.cancelFileDownload(id) } }
        }
        if Task.isCancelled { throw CancellationError() }
        return result
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

    enum ScriptMode: Int32 { case expression = 0, asyncBody = 1 }
    enum ScriptWorld: Int32 { case page = 0, isolated = 1 }
    struct ScriptResult {
        let text: String
        let json: String
        let isString: Bool
        let isUndefined: Bool
        var devMCPText: String { isUndefined ? "undefined" : (json.isEmpty ? text : json) }
        var browserToolText: String {
            if isUndefined { return "JavaScript executed (no return value)" }
            if isString || (json == "null" && text != "null" && !text.isEmpty) { return text }
            guard let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return text }
            return String(describing: value)
        }
    }
    enum ScriptError: LocalizedError {
        case unavailable, busy, cancelled, exception(String), rejected(String), unserializable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Script execution is unavailable for this document"
            case .busy: return "A script request is already pending"
            case .cancelled: return "Script request cancelled or its document changed"
            case .exception(let text): return "JavaScript exception: \(text)"
            case .rejected(let text): return "JavaScript promise rejected: \(text)"
            case .unserializable: return "JavaScript result exceeded the supported result size or could not be represented"
            }
        }
    }

    private var nextPickerRequest: UInt64 = 0
    private var pickerRequest: (id: UInt64, continuation: CheckedContinuation<String?, Never>)?
    var supportsElementPicker: Bool {
        !invalidated && !isClosed && observation != 0 && api.startPicker != nil && api.cancelPicker != nil
    }
    func pickElement() async -> String? {
        guard supportsElementPicker, !state.isLoading, pickerRequest == nil,
              !Task.isCancelled, nextPickerRequest < UInt64.max else { return nil }
        nextPickerRequest += 1
        let request = nextPickerRequest
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                pickerRequest = (request, continuation)
                let accepted = api.startPicker?(observation, request, { pointer, token, request, selector, length in
                    guard let pointer else { return }
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue().owner
                        owner?.receivedPicker(token: token, request: request, selector: selector, length: length)
                    }
                }) == 1
                if !accepted, pickerRequest?.id == request {
                    let pending = pickerRequest; pickerRequest = nil
                    pending?.continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPicker(request: request) }
        }
    }
    private func receivedPicker(token: UInt64, request: UInt64, selector: UnsafePointer<CChar>?, length: Int) {
        guard token == observation, let pending = pickerRequest, pending.id == request else { return }
        pickerRequest = nil
        guard !invalidated, !isClosed, let selector, length > 0, length <= 2048,
              let value = String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(selector)
                .assumingMemoryBound(to: UInt8.self), count: length), encoding: .utf8),
              !value.contains("\0") else { pending.continuation.resume(returning: nil); return }
        pending.continuation.resume(returning: value)
    }
    func cancelElementPicker() { cancelPicker() }
    private func cancelPicker(request: UInt64? = nil) {
        guard let pending = pickerRequest, request == nil || pending.id == request else { return }
        pickerRequest = nil
        if observation != 0 { _ = api.cancelPicker?(observation, pending.id) }
        pending.continuation.resume(returning: nil)
    }

    func evaluateScript(_ source: String, mode: ScriptMode, world: ScriptWorld) async throws -> ScriptResult {
        guard !invalidated, !isClosed, observation != 0, window > 0,
              !source.contains("\0"), source.utf8.count <= 128 * 1024,
              let evaluate = api.evaluateScript, api.cancelScript != nil,
              nextScriptRequest < UInt64.max else { throw ScriptError.unavailable }
        guard scriptRequest == nil else { throw ScriptError.busy }
        try Task.checkCancellation()
        nextScriptRequest += 1
        let request = nextScriptRequest
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                scriptRequest = (request, continuation)
                let accepted = source.withCString { source in
                    evaluate(observation, request, mode.rawValue, world.rawValue, source,
                        { pointer, token, request, status, text, textLength, json, jsonLength, isString in
                            guard let pointer else { return }
                            MainActor.assumeIsolated {
                                let owner = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue().owner
                                owner?.receivedScript(token: token, request: request, status: status,
                                    text: text, textLength: textLength, json: json, jsonLength: jsonLength, isString: isString != 0)
                            }
                        }) == 1
                }
                if !accepted, scriptRequest?.id == request {
                    let pending = scriptRequest; scriptRequest = nil
                    pending?.continuation.resume(throwing: ScriptError.unavailable)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelScript(request: request) }
        }
    }

    func capturePageText() async -> (title: String, body: String)? {
        guard !isPrivateSession, !state.isLoading else { return nil }
        let script = """
        (() => [document.title.slice(0, 4096), ((document.body && document.body.innerText) || '').trim().slice(0, 20000)])()
        """
        guard let result = try? await evaluateScript(script, mode: .expression, world: .isolated),
              !Task.isCancelled, !result.isUndefined,
              let parts = try? JSONDecoder().decode([String].self, from: Data(result.json.utf8)),
              parts.count == 2, parts[0].utf16.count <= 4096, parts[1].utf16.count <= 20000 else { return nil }
        return (parts[0], parts[1])
    }

    private func receivedScript(token: UInt64, request: UInt64, status: Int32,
        text: UnsafePointer<CChar>?, textLength: Int, json: UnsafePointer<CChar>?, jsonLength: Int, isString: Bool) {
        guard token == observation, let pending = scriptRequest, pending.id == request else { return }
        scriptRequest = nil
        func bounded(_ pointer: UnsafePointer<CChar>?, _ count: Int) -> String? {
            guard count >= 0, count <= 1024 * 1024 else { return nil }
            guard let pointer else { return count == 0 ? "" : nil }
            return String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: count), encoding: .utf8)
        }
        guard let text = bounded(text, textLength), let json = bounded(json, jsonLength) else {
            pending.continuation.resume(throwing: ScriptError.unserializable); return
        }
        switch status {
        case 0, 1:
            pending.continuation.resume(returning: ScriptResult(text: text, json: json,
                isString: isString, isUndefined: status == 1))
        case 2: pending.continuation.resume(throwing: ScriptError.exception(text))
        case 3: pending.continuation.resume(throwing: ScriptError.rejected(text))
        case 5: pending.continuation.resume(throwing: ScriptError.busy)
        case 6: pending.continuation.resume(throwing: ScriptError.cancelled)
        case 7: pending.continuation.resume(throwing: ScriptError.unserializable)
        default: pending.continuation.resume(throwing: ScriptError.unavailable)
        }
    }

    private func cancelScript(request: UInt64? = nil) {
        guard let pending = scriptRequest, request == nil || pending.id == request else { return }
        scriptRequest = nil
        // Revoke before native cancellation can synchronously call back.
        if observation != 0 { _ = api.cancelScript?(observation, pending.id) }
        pending.continuation.resume(throwing: ScriptError.cancelled)
    }

    var supportsTranslation: Bool { !invalidated && !isClosed && api.translate != nil }

    @discardableResult
    func translate(_ command: PageTranslationCommand,
                   completion: @escaping @MainActor (PageTranslationResult?) -> Void) -> Bool {
        guard supportsTranslation, observation != 0, window != 0,
              let translate = api.translate, nextTranslationRequest < UInt64.max else { return false }
        let operation: Int32
        let pairs: [PageTranslationNode]
        switch command {
        case .sample: operation = 0; pairs = []
        case .start: operation = 1; pairs = []
        case .apply(let value): operation = 2; pairs = value
        case .restore: operation = 3; pairs = []
        }
        guard pairs.count <= 128, pairs.allSatisfy({ $0.id.utf8.count <= 32 && $0.text.utf8.count <= 131072 }),
              let data = try? JSONEncoder().encode(pairs), data.count <= 512 * 1024,
              let payload = String(data: data, encoding: .utf8) else { return false }
        nextTranslationRequest += 1
        let request = nextTranslationRequest
        let previous = translationRequest
        translationRequest = nil
        previous?.completion(nil)
        guard supportsTranslation, nextTranslationRequest == request else { return false }
        translationRequest = (request, completion)
        let accepted = payload.withCString { value in
            translate(observation, translationGeneration, request, operation, value, { pointer, token, generation, request, status, payload in
                guard let pointer else { return }
                MainActor.assumeIsolated {
                    let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                    context.owner?.receivedTranslation(token: token, generation: generation,
                                                       request: request, status: status, payload: payload)
                }
            }) != 0
        }
        if !accepted, translationRequest?.id == request { translationRequest = nil }
        return accepted
    }

    private func receivedTranslation(token: UInt64, generation: UInt64, request: UInt64,
                                     status: Int32, payload: UnsafePointer<CChar>?) {
        guard !invalidated, !isClosed, observation == token,
              generation == translationGeneration else { return }
        let result: PageTranslationResult?
        if status == 0, let payload {
            let bytes = strnlen(payload, 512 * 1024 + 1)
            result = bytes <= 512 * 1024 ? try? JSONDecoder().decode(PageTranslationResult.self,
                from: Data(bytes: payload, count: bytes)) : nil
        } else { result = nil }
        if request == 0 {
            if let result, result.nodes.count <= 128 { onTranslationNodes?(result.nodes) }
            else { onTranslationNodes?(nil) }
        } else if let pending = translationRequest, pending.id == request {
            translationRequest = nil
            pending.completion(result)
        }
    }

    private func cancelTranslation() {
        translationGeneration &+= 1
        let pending = translationRequest
        translationRequest = nil
        pending?.completion(nil)
    }

    var supportsUserCSS: Bool { !invalidated && !isClosed && api.setUserCSS != nil }

    @discardableResult
    func setUserCSS(_ css: String, for committedURL: URL,
                    completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard !invalidated, !isClosed, observation != 0, window > 0,
              let setStyle = api.setUserCSS, !css.contains("\0"), css.utf8.count <= 16 * 1024 * 1024,
              nextStyleRequest != UInt64.max else { return false }
        // Revoke first; a superseded completion may reenter and issue newer CSS.
        nextStyleRequest += 1
        let request = nextStyleRequest
        let previous = styleRequest
        styleRequest = nil
        previous?.completion(false)
        guard !invalidated, !isClosed, nextStyleRequest == request else { return false }
        styleRequest = (request, window, completion)
        let accepted = committedURL.absoluteString.withCString { url in
            css.withCString { style in
                setStyle(observation, request, url, style, { pointer, token, request, result in
                    MainActor.assumeIsolated {
                        guard let pointer else { return }
                        let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                        context.owner?.receivedStyle(token: token, request: request, result: result)
                    }
                }) == 1
            }
        }
        if !accepted, styleRequest?.id == request { styleRequest = nil }
        return accepted
    }

    private func receivedStyle(token: UInt64, request: UInt64, result: Int32) {
        guard token == observation, let pending = styleRequest, pending.id == request else { return }
        styleRequest = nil
        pending.completion(!invalidated && !isClosed && pending.window == window && result == 0)
    }

    private func cancelStyle() {
        let pending = styleRequest
        styleRequest = nil
        pending?.completion(false)
    }

    func invalidate() {
        peekEnabled = false
        pendingPeekRequest = 0
        guard !invalidated else { return }
        observeVault(nil)
        observeVaultSave(nil)
        observeVaultPasskeys(nil)
        invalidated = true
        state.media = nil
        cancelThumbnail()
        cancelSiteData()
        cancelStyle()
        cancelTranslation()
        cancelElementPicker()
        cancelScript()
        cancelFileDownloads()
        onTranslationNodes = nil
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

    private func admitCallback(token: UInt64, window: Int32, tab: Int32, terminal: Bool = false) -> Bool {
        guard !invalidated, tab == self.tab, token != 0,
              observation == 0 || observation == token else { return false }
        // A Browser's Profile/SessionID are immutable. Validate only a new
        // nonzero owner, never allocate/parse UUIDs for unchanged state/title.
        // Owner zero is detached/non-commandable; terminal delivery remains
        // valid after the old native owner has already disappeared.
        guard terminal || window == self.window || window == 0 || matchesProfile(window) else { return false }
        observation = token  // INITIAL can call out before observe() returns.
        let ownerChanged = self.window != window
        self.window = window  // A live transfer changes the owner, never the page.
        if ownerChanged {
            cancelElementPicker()
            cancelScript()
            cancelFileDownloads()
            pendingPeekRequest = 0
            cancelThumbnail()
            cancelSiteData()
            cancelStyle()
            onNativeOwnerChanged?(window)
        }
        return !invalidated
    }

    private func receiveMedia(token: UInt64, window: Int32, tab: Int32, flags: UInt32,
                              title: String?, artist: String?, album: String?) {
        guard admitCallback(token: token, window: window, tab: tab) else { return }
        let known = flags & 1 != 0
        let playing = flags & 4 != 0, video = flags & 8 != 0
        let media = known ? PageMedia(hasMedia: flags & 2 != 0, isAudible: flags & 256 != 0,
            isPlaying: playing, hasVideo: video, isPlayingVideo: playing && video,
            handlesPreviousTrack: flags & 16 != 0, handlesNextTrack: flags & 32 != 0,
            canPlay: flags & 64 != 0, canPause: flags & 128 != 0,
            title: title.flatMap { $0.isEmpty ? nil : $0 }, artist: artist.flatMap { $0.isEmpty ? nil : $0 },
            album: album.flatMap { $0.isEmpty ? nil : $0 }) : nil
        var next = state
        next.media = media
        if known { next.isAudible = flags & 256 != 0 }
        if next != state { state = next; onEvent?(.mediaChanged(media)) }
    }

    private func receive(token: UInt64, event: Int32, window: Int32, tab: Int32,
                         url: URL?, title: String?, error: Int32, flags: UInt32) {
        guard admitCallback(token: token, window: window, tab: tab, terminal: event == 7) else { return }
        if event == 10 || event == 11 {
            // The rejected target is independent of the displayed document.
            // Never infer native blocker provenance from a generic net error.
            if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                onEvent?(event == 10 ? .nativeBlocked(url) : .continueNativeBlock(url))
            }
            return
        }
        if event == 9 { // Link intent must never overwrite the source snapshot.
            if peekEnabled, error > 0, let url {
                pendingPeekRequest = error
                onEvent?(.peekRequested(url))
            }
            return
        }
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
        if event == 1 || (event == 2 && flags & 16 == 0) {
            cancelElementPicker()
            if event == 1 { cancelScript(); cancelFileDownloads() }
            pendingPeekRequest = 0
        }
        var media = state.media
        if (event == 2 && flags & 16 == 0) || (event == 4 && flags & 32 == 0) { media = nil }
        if let audible = media?.isAudible, audible != (flags & 512 != 0) {
            media?.isAudible = flags & 512 != 0
        }
        let snapshot = PageNavigationState(
            url: url, title: title, isLoading: flags & 1 != 0,
            canGoBack: flags & 2 != 0, canGoForward: flags & 4 != 0,
            isAudioMuted: flags & 256 != 0, isAudible: flags & 512 != 0,
            hasVideoPictureInPicture: flags & 4096 != 0 ? flags & 1024 != 0 : nil,
            hasDocumentPictureInPicture: flags & 4096 != 0 ? flags & 2048 != 0 : nil, media: media)
        if state != snapshot {
            state = snapshot
            onStateChanged?(snapshot)
        }
        guard !invalidated else { return }
        if event == 1 || event == 2 { cancelThumbnail() }
        if event == 2 && flags & 16 == 0 { cancelStyle(); cancelTranslation() }
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


extension ChromiumPageNavigation: VaultNativePage {
    var vaultProfileID: UUID? { profileID }
    func observeVaultPasskeys(_ callback: (@MainActor (VaultNativePasskeyRequest?) -> Void)?) {
        let previous = vaultPasskeyCallback; vaultPasskeyCallback = callback
        if callback == nil { previous?(nil) }
        guard !invalidated, observation != 0, let observe = api.observeVaultPasskeys else { callback?(nil); return }
        let native: ChromiumNavigationAPI.VaultPasskeyCallback? = callback == nil ? nil : { pointer, token, request, operation, arguments, nativeView in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                guard let owner = context.owner, owner.observation == token, !owner.invalidated else { return }
                guard request != 0, (operation == 0 || operation == 1), let nativeView,
                      let args = ChromiumPageNavigation.fileString(arguments,limit:65537),
                      owner.vaultPasskeyIsCurrent(request) else { owner.vaultPasskeyCallback?(nil); return }
                let view = Unmanaged<NSView>.fromOpaque(nativeView).takeUnretainedValue()
                owner.vaultPasskeyCallback?(VaultNativePasskeyRequest(token:request,operation:operation,arguments:args,view:view))
            }
        }
        if observe(observation,native) != 1 { callback?(nil) }
    }
    func vaultPasskeyIsCurrent(_ token: UInt64) -> Bool {
        !invalidated && !isClosed && observation != 0 && window > 0 && matchesProfile(window) &&
            api.vaultPasskeyCurrent?(observation,token) == 1
    }
    func completeVaultPasskey(_ token: UInt64, result: String?) -> Bool {
        guard observation != 0, let complete = api.completeVaultPasskey else { return false }
        guard let result else { return complete(observation,token,0,nil) == 1 }
        guard !result.utf8.contains(0), result.utf8.count <= 262144, vaultPasskeyIsCurrent(token) else { return false }
        return result.withCString { complete(observation,token,1,$0) == 1 }
    }
    func observeVaultSave(_ callback: (@MainActor (VaultNativeSubmission?) -> Void)?) {
        let previous = vaultSaveCallback; vaultSaveCallback = callback
        if callback == nil { previous?(nil) }
        guard !invalidated, observation != 0, let observe = api.observeVaultSave else { callback?(nil); return }
        let native: ChromiumNavigationAPI.VaultSaveCallback? = callback == nil ? nil : { pointer, token, submission, origin, username, password, nativeView in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                guard let owner = context.owner, owner.observation == token, !owner.invalidated else { return }
                guard submission != 0, let nativeView,
                      let origin = ChromiumPageNavigation.fileString(origin,limit:4096),
                      let username = ChromiumPageNavigation.fileString(username,limit:65537),
                      let password = ChromiumPageNavigation.fileString(password,limit:65537),
                      owner.vaultSaveIsCurrent(submission) else { owner.vaultSaveCallback?(nil); return }
                let view = Unmanaged<NSView>.fromOpaque(nativeView).takeUnretainedValue()
                owner.vaultSaveCallback?(VaultNativeSubmission(token:submission,origin:origin,username:username,password:password,view:view))
            }
        }
        if observe(observation,native) != 1 { callback?(nil) }
    }
    func vaultSaveIsCurrent(_ token: UInt64) -> Bool {
        !invalidated && !isClosed && observation != 0 && window > 0 && matchesProfile(window) &&
            api.vaultSaveCurrent?(observation,token) == 1
    }
    func cancelVaultSave(_ token: UInt64) {
        if observation != 0 { _ = api.cancelVaultSave?(observation,token) }
    }
    func observeVault(_ callback: (@MainActor (VaultNativeFocus?) -> Void)?) {
        let previous = vaultCallback
        vaultCallback = callback
        if callback == nil { previous?(nil) }
        guard !invalidated, observation != 0, let observe = api.observeVault else { callback?(nil); return }
        let native: ChromiumNavigationAPI.VaultCallback? = callback == nil ? nil : { pointer, token, focus, origin, kind, nativeView, x, y, width, height in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                guard let owner = context.owner, owner.observation == token, !owner.invalidated else { return }
                guard focus != 0, (kind == 0 || kind == 1), let nativeView,
                      let origin = ChromiumPageNavigation.fileString(origin, limit: 4096),
                      [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0 else {
                    owner.vaultCallback?(nil); return
                }
                let view = Unmanaged<NSView>.fromOpaque(nativeView).takeUnretainedValue()
                var rect = CGRect(x:x,y:y,width:width,height:height)
                if !view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                rect = rect.intersection(view.bounds)
                guard !rect.isNull, !rect.isEmpty, owner.vaultFocusIsCurrent(focus) else { owner.vaultCallback?(nil); return }
                owner.vaultCallback?(VaultNativeFocus(token:focus,origin:origin,isCode:kind == 1,view:view,anchor:rect))
            }
        }
        if observe(observation, native) != 1 { callback?(nil) }
    }
    func vaultFieldIsCurrent(_ token: UInt64) -> Bool {
        !invalidated && !isClosed && observation != 0 && window > 0 && matchesProfile(window) &&
            api.vaultFieldCurrent?(observation, token) == 1
    }
    func cancelVaultFocus(_ token: UInt64) { if observation != 0 { _ = api.cancelVaultFocus?(observation, token) } }
    func vaultFocusIsCurrent(_ token: UInt64) -> Bool {
        !invalidated && !isClosed && observation != 0 && window > 0 && matchesProfile(window) &&
            api.vaultCurrent?(observation,token) == 1
    }
    func fillVault(_ token: UInt64, username: String, secret: String) -> Bool {
        guard !username.utf8.contains(0), !secret.utf8.contains(0), vaultFocusIsCurrent(token),
              let fill = api.vaultFill else { return false }
        return username.withCString { username in secret.withCString { secret in fill(observation,token,username,secret) == 1 } }
    }
}
