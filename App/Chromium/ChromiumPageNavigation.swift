// Licensed under GPL-3.0. See LICENSE.
import BarcChromium
internal import BarkLoadProgress
internal import BarkRendererState
import Darwin
import Foundation
import AppKit
import NookBlocker
import NookWeb

enum ChromiumSiteDataOutcome: Equatable { case completed, cancelled, failed }

enum ChromiumNavigationError: Error {
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
    private let bridge: BarcBridge
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
    private var progressSuppressedUntilNextLoad = false
    private var pendingPeekRequest: Int32 = 0
    private var peekEnabled = false
    private var invalidated = false
    private(set) var isClosed = false
    private(set) var nativeCloseOutcome: PageCloseOutcome?
    var nativeWindowID: Int32 { window }
    var nativeTabID: Int32 { tab }

    /// Sample the existing page without selecting it, running script, or starting a renderer.
    var resourceDiagnostics: (inWindow: Bool?, pid: Int32?, visibility: String?) {
        guard observation != 0, !invalidated, !isClosed, !isPrivateSession,
              window > 0, matchesProfile(window) else { return (nil, nil, nil) }
        let inWindow = bridge.tab_native_view(window, tab).map {
            Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue().window != nil
        }
        var pid: Int32 = 0
        var visible: Int32 = 0
        let available = withUnsafePointer(to: bridge) { BarkReadRendererState($0, window, tab, &pid, &visible) }
        guard available == 1,
              pid > 0, visible == 0 || visible == 1 else { return (inWindow, nil, nil) }
        return (inWindow, pid, visible == 1 ? "visible" : "hidden")
    }
    // Host-only lifecycle channel. PageSession retains its event/state channels.
    var onNativeCloseOutcome: ((PageCloseOutcome) -> Void)?
    var onNativeOwnerChanged: ((Int32) -> Void)?
    enum NativePageReadyConsumer { case startup, palette }
    private var nativePageReadyActions: [NativePageReadyConsumer: () -> Void] = [:]

    /// Replaces this consumer's pending action for the next main document.
    func whenNativePageReady(for consumer: NativePageReadyConsumer, _ action: @escaping () -> Void) {
        nativePageReadyActions[consumer] = action
    }
    private let context = CallbackContext()

    private final class CallbackContext {
        weak var owner: ChromiumPageNavigation?
    }

    init(profileID: UUID, window: Int32, tab: Int32, bridge: BarcBridge, privateSession: Bool = false) throws {
        // Verify the native owner, rather than trusting a caller's profile label.
        var uuid = [CChar](repeating: 0, count: 37)
        let query = privateSession ? bridge.window_private_session_uuid : bridge.window_profile_uuid
        let required = query(window, &uuid, uuid.count)
        guard required == uuid.count,
              UUID(uuidString: String(decoding: uuid.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)) == profileID else {
            throw ChromiumNavigationError.profileMismatch
        }
        self.profileID = profileID
        self.isPrivateSession = privateSession
        self.window = window
        self.tab = tab
        self.bridge = bridge
        context.owner = self
        let token = bridge.tab_observe(window, tab, { pointer, token, event, window, tab, url, title, error, flags in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                // Copy borrowed strings before calling any client code, which
                // can close the tab or cancel this observation synchronously.
                context.owner?.receive(
                    token: token, event: BarcTabEvent(rawValue: UInt32(bitPattern: event)), window: window, tab: tab,
                    url: url.flatMap { URL(string: String(cString: $0)) },
                    title: title.map { String(cString: $0) }, error: error, flags: flags)
            }
        }, Unmanaged.passUnretained(context).toOpaque())
        guard token != 0, !invalidated else {
            invalidate()
            throw ChromiumNavigationError.observationRejected
        }
        observation = token
        let accepted = bridge.tab_observe_media(token, { pointer, token, window, tab, flags, title, artist, album in
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
        _ = Self.observeLoadProgress(bridge, token, { pointer, token, progress, loading in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                context.owner?.receiveLoadProgress(token: token, progress: progress, loading: loading)
            }
        })
    }

    private static func observeLoadProgress(_ bridge: BarcBridge, _ token: UInt64,
        _ callback: @escaping BarkLoadProgressCallback) -> Int32 {
        withUnsafePointer(to: bridge) { BarkObserveTabLoadProgress($0, token, callback) }
    }

    isolated deinit {
        if observation != 0 { bridge.tab_unobserve(observation) }
    }

    func search(_ query: String, kagiSessionToken: String?) -> Bool {
        guard !invalidated, window > 0 else { return false }
        let accepted = query.withCString { query in
            if let token = kagiSessionToken { return token.withCString { bridge.tab_search(window, tab, query, $0) } }
            return bridge.tab_search(window, tab, query, nil)
        }
        return accepted == 1 && !invalidated
    }

    func load(_ url: URL) {
        guard !invalidated, window > 0 else { return }
        let accepted = url.absoluteString.withCString { bridge.tab_navigate(window, tab, $0) }
        if accepted != 1, !invalidated {
            let error = NSError(domain: "Barc.Chromium.Command", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "This tab is no longer available."])
            onEvent?(.failed(error, provisional: true, committedURL: state.url))
        }
    }

    func historyEntries(forward: Bool) -> [PageHistoryEntry] {
        guard !invalidated, !isClosed, window > 0 else { return [] }
        let owner = window
        let direction = Int32((forward ? BARC_HISTORY_FORWARD : BARC_HISTORY_BACK).rawValue)
        let count = bridge.tab_copy_history(owner, tab, direction, nil, 0)
        guard count > 1, count <= 1_048_576, !invalidated, window == owner else { return [] }
        var bytes = [CChar](repeating: 0, count: count)
        let copied = bridge.tab_copy_history(owner, tab, direction, &bytes, count)
        guard copied == count, bytes.last == 0, !invalidated, window == owner,
              let entries = try? JSONDecoder().decode([PageHistoryEntry].self,
                  from: Data(bytes.dropLast().map { UInt8(bitPattern: $0) })),
              entries.count <= 100, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.id > 0 && $0.title.utf8.count <= 4096 && $0.url.absoluteString.utf8.count <= 8192 }) else { return [] }
        return entries
    }
    @discardableResult func goToHistoryEntry(_ id: Int32) -> Bool {
        guard !invalidated, !isClosed, window > 0, id > 0 else { return false }
        return bridge.tab_go_to_history_entry(window, tab, id) == 1
    }

    @discardableResult func goBack() -> Bool { command(bridge.tab_go_back) }
    @discardableResult func goForward() -> Bool { command(bridge.tab_go_forward) }
    @discardableResult func reload() -> Bool { command(bridge.tab_reload) }
    func stop() {
        if command(bridge.tab_stop) { setLoadProgress(nil) }
    }

    @discardableResult func applyBlockingPolicy(_ policy: ContentBlockerManager.NetworkPagePolicy) -> Bool {
        guard !invalidated, !isClosed, window > 0, observation != 0 else { return false }
        let remaining = max(0, policy.disabledUntil?.timeIntervalSinceNow ?? 0)
        let milliseconds = UInt64(min(remaining * 1_000, Double(Int64.max).nextDown).rounded(.up))
        if let host = policy.continuedHost {
            return host.withCString { bridge.blocker_set_tab_policy(window, tab, policy.isOAuthFlow ? 1 : 0, $0, milliseconds) == 1 }
        }
        return bridge.blocker_set_tab_policy(window, tab, policy.isOAuthFlow ? 1 : 0, nil, milliseconds) == 1
    }

    @discardableResult
    func setNativePeekCapability(_ enabled: Bool, onShiftClick: Bool = false) -> Bool {
        if !enabled { peekEnabled = false; pendingPeekRequest = 0 }
        let capability = enabled ? Int32(onShiftClick ? BARC_TAB_PEEK_CAPABLE | BARC_TAB_PEEK_ON_SHIFT_CLICK : BARC_TAB_PEEK_CAPABLE) : 0
        guard !invalidated, !isClosed, observation != 0,
              bridge.tab_enable_peek(observation, capability) == 1 else { return false }
        peekEnabled = enabled
        return true
    }

    var pendingPeekRequestID: Int32? {
        !invalidated && !isClosed && peekEnabled && pendingPeekRequest > 0 ? pendingPeekRequest : nil
    }

    /// Called only after PageSession leaves the native observer stack. Native
    /// admission consumes the captured document intent, never a caller URL.
    func createNativePeek(request: Int32, admission: BarcTransferAdmission,
                          context: UnsafeMutableRawPointer?) -> Bool {
        guard !invalidated, !isClosed, window > 0, observation != 0,
              request > 0, pendingPeekRequest == request else { return false }
        let accepted = bridge.tab_create_peek(observation, request, admission, context) == 1
        if pendingPeekRequest == request { pendingPeekRequest = 0 }
        return accepted
    }

    @discardableResult func selectNativePage() -> Bool { command(bridge.tab_select) }
    /// `successor`, a page of the same client, is shown if this page is still shown when it closes.
    @discardableResult func requestNativeClose(showing successor: ChromiumPageNavigation? = nil) -> Bool {
        guard let successor, !successor.invalidated, successor.window == window, !invalidated,
              observation != 0 else { return command(bridge.tab_close) }
        return bridge.tab_close_selecting(observation, successor.tab) == 1
    }

    private func command(_ action: (Int32, Int32) -> Int32) -> Bool {
        !invalidated && window > 0 && action(window, tab) == 1
    }

    @discardableResult
    func executeNativePageCommand(_ command: Int32) -> Bool {
        guard !invalidated, !isClosed, window > 0 else { return false }
        return bridge.tab_execute_command(window, tab, command) == 1
    }

    var certificateState: SiteCertificateState {
        guard !invalidated, !isClosed, window > 0 else { return .unavailable }
        switch bridge.tab_execute_command(window, tab, Int32(BARC_PAGE_CERTIFICATE_STATE.rawValue)) {
        case Int32(BARC_CERTIFICATE_SECURE.rawValue): return .secure
        case Int32(BARC_CERTIFICATE_AVAILABLE.rawValue): return .available
        default: return .unavailable
        }
    }

    func showCertificate() -> Bool {
        executeNativePageCommand(Int32(BARC_PAGE_SHOW_CERTIFICATE.rawValue))
    }

    func handleCertificateClose(dismiss: Bool) -> Bool {
        let command = dismiss ? BARC_PAGE_CLOSE_CERTIFICATE_VIEWER : BARC_PAGE_CERTIFICATE_VIEWER_FOCUSED
        return executeNativePageCommand(Int32(command.rawValue))
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
        guard !invalidated, !isClosed, window > 0 else { return false }
        return bridge.tab_media_action(window, tab, Int32((paused ? BARC_MEDIA_PAUSE : BARC_MEDIA_PLAY).rawValue)) == 1
    }

    @discardableResult
    func skipTrack(forward: Bool) -> Bool {
        guard !invalidated, !isClosed, window > 0 else { return false }
        return bridge.tab_media_action(window, tab, Int32((forward ? BARC_MEDIA_NEXT_TRACK : BARC_MEDIA_PREVIOUS_TRACK).rawValue)) == 1
    }

    @discardableResult
    func setAudioMuted(_ muted: Bool) -> Bool {
        guard !invalidated, !isClosed, window > 0 else { return false }
        return bridge.tab_set_muted(window, tab, muted ? 1 : 0) == 1
    }

    @discardableResult
    func captureThumbnail(completion: @escaping @MainActor (Data?) -> Void) -> Bool {
        guard !invalidated, !isClosed, observation != 0, window > 0,
              thumbnailRequest == nil, nextThumbnailRequest != UInt64.max else { return false }
        nextThumbnailRequest += 1
        let request = nextThumbnailRequest
        thumbnailRequest = (request, thumbnailGeneration, window, 1_048_576, completion)
        let accepted = bridge.tab_capture_thumbnail(observation, request, { pointer, token, request, bytes, count in
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
        if let pending { _ = bridge.tab_cancel_capture(observation, pending.id) }
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
                      thumbnailRequest == nil, nextThumbnailRequest != UInt64.max else {
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
                let accepted = bridge.tab_capture_screenshot(observation, id, Int32(maxWidth), { pointer, token, request, bytes, count in
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
        _ = bridge.tab_cancel_file(observation, id)
        request.completion(.failure(CancellationError()))
    }
    private func cancelFileDownloads() {
        let requests = fileRequests
        fileRequests.removeAll()
        for (id, request) in requests {
            _ = bridge.tab_cancel_file(observation, id)
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
        guard !invalidated,!isClosed,pending.window==window,result != BARC_FILE_CANCELLED.rawValue,bytes>=0,
              result != BARC_FILE_OK.rawValue || (temporary != nil && bytes<=100*1024*1024) else {
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
                      fileRequests.count < 6, nextFileRequest != .max,
                      url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                      directory.isFileURL, !url.absoluteString.utf8.contains(0), !directory.path.utf8.contains(0) else {
                    continuation.resume(throwing: ChromiumNavigationError.fileDownloadUnavailable);return
                }
                nextFileRequest += 1
                let id = nextFileRequest;request.id = id
                fileRequests[id] = (window, directory, { continuation.resume(with: $0) })
                let accepted = url.absoluteString.withCString { url in directory.path.withCString { directory in
                    bridge.tab_download_file(observation,id,url,directory,{ pointer,token,request,result,status,path,mime,bytes,directoryDescriptor in
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
        let accepted = bridge.tab_clear_site_data(observation, request, action, { pointer, token, request, result in
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
        pending.completion(result == BARC_SITE_COMPLETED.rawValue ? .completed :
            (result == BARC_SITE_CANCELLED.rawValue ? .cancelled : .failed))
    }

    private func cancelSiteData() {
        let pending = siteDataRequest
        siteDataRequest = nil
        pending?.completion(.cancelled)
    }

    enum ScriptMode {
        case expression, asyncBody
        var native: BarcScriptMode { self == .expression ? BARC_SCRIPT_COMPLETION_VALUE : BARC_SCRIPT_ASYNC_BODY }
    }
    enum ScriptWorld {
        case page, isolated
        var native: BarcScriptWorld { self == .page ? BARC_SCRIPT_PAGE_WORLD : BARC_SCRIPT_ISOLATED_WORLD }
    }
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

    var lastDeveloperPick: (window: UUID, owner: Int32, profile: UUID?, document: UInt64, pick: DevPick)?

    private var nextPickerRequest: UInt64 = 0
    private var pickerRequest: (id: UInt64, continuation: CheckedContinuation<String?, Never>)?
    var supportsElementPicker: Bool {
        !invalidated && !isClosed && observation != 0
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
                let accepted = bridge.tab_start_boost_picker(observation, request, { pointer, token, request, selector, length in
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
        if observation != 0 { _ = bridge.tab_cancel_boost_picker(observation, pending.id) }
        pending.continuation.resume(returning: nil)
    }

    func evaluateScript(_ source: String, mode: ScriptMode, world: ScriptWorld) async throws -> ScriptResult {
        guard !invalidated, !isClosed, observation != 0, window > 0,
              !source.contains("\0"), source.utf8.count <= 128 * 1024,
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
                    bridge.tab_evaluate_script(observation, request, Int32(mode.native.rawValue), Int32(world.native.rawValue), source,
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
        switch BarcScriptResult(rawValue: UInt32(bitPattern: status)) {
        case BARC_SCRIPT_VALUE, BARC_SCRIPT_UNDEFINED:
            pending.continuation.resume(returning: ScriptResult(text: text, json: json,
                isString: isString, isUndefined: status == BARC_SCRIPT_UNDEFINED.rawValue))
        case BARC_SCRIPT_EXCEPTION: pending.continuation.resume(throwing: ScriptError.exception(text))
        case BARC_SCRIPT_REJECTED: pending.continuation.resume(throwing: ScriptError.rejected(text))
        case BARC_SCRIPT_BUSY: pending.continuation.resume(throwing: ScriptError.busy)
        case BARC_SCRIPT_CANCELLED: pending.continuation.resume(throwing: ScriptError.cancelled)
        case BARC_SCRIPT_UNSERIALIZABLE: pending.continuation.resume(throwing: ScriptError.unserializable)
        default: pending.continuation.resume(throwing: ScriptError.unavailable)
        }
    }

    private func cancelScript(request: UInt64? = nil) {
        guard let pending = scriptRequest, request == nil || pending.id == request else { return }
        scriptRequest = nil
        // Revoke before native cancellation can synchronously call back.
        if observation != 0 { _ = bridge.tab_cancel_script(observation, pending.id) }
        pending.continuation.resume(throwing: ScriptError.cancelled)
    }

    var supportsTranslation: Bool { !invalidated && !isClosed }

    @discardableResult
    func translate(_ command: PageTranslationCommand,
                   completion: @escaping @MainActor (PageTranslationResult?) -> Void) -> Bool {
        guard supportsTranslation, observation != 0, window != 0,
              nextTranslationRequest < UInt64.max else { return false }
        let operation: BarcTranslateOperation
        let pairs: [PageTranslationNode]
        switch command {
        case .sample: operation = BARC_TRANSLATE_SAMPLE; pairs = []
        case .start: operation = BARC_TRANSLATE_START; pairs = []
        case .apply(let value): operation = BARC_TRANSLATE_APPLY; pairs = value
        case .restore: operation = BARC_TRANSLATE_RESTORE; pairs = []
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
            bridge.tab_translate(observation, translationGeneration, request, Int32(operation.rawValue), value, { pointer, token, generation, request, status, payload in
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
        if status == BARC_TRANSLATE_APPLIED.rawValue, let payload {
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

    var supportsUserCSS: Bool { !invalidated && !isClosed }

    @discardableResult
    func setUserCSS(_ css: String, for committedURL: URL,
                    completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard !invalidated, !isClosed, observation != 0, window > 0,
              !css.contains("\0"), css.utf8.count <= 16 * 1024 * 1024,
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
                bridge.tab_set_user_css(observation, request, url, style, { pointer, token, request, result in
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
        pending.completion(!invalidated && !isClosed && pending.window == window && result == BARC_STYLE_APPLIED.rawValue)
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
        state.loadProgress = nil
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
        nativePageReadyActions.removeAll()
        if token != 0 { bridge.tab_unobserve(token) }
    }

    private func matchesProfile(_ window: Int32) -> Bool {
        var bytes = [CChar](repeating: 0, count: 37)
        let query = isPrivateSession ? bridge.window_private_session_uuid : bridge.window_profile_uuid
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
            setLoadProgress(nil)
            guard !invalidated else { return false }
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

    private func setLoadProgress(_ progress: Double?) {
        guard state.loadProgress != progress else { return }
        state.loadProgress = progress
        onStateChanged?(state)
    }

    func receiveLoadProgress(token: UInt64, progress: Double, loading: Int32) {
        guard !invalidated, token != 0, token == observation, window != 0 else { return }
        let fraction = loading == 1 && state.isLoading && !progressSuppressedUntilNextLoad && progress.isFinite && (0...1).contains(progress)
            ? progress : nil
        setLoadProgress(fraction)
    }

    private func receiveMedia(token: UInt64, window: Int32, tab: Int32, flags: UInt32,
                              title: String?, artist: String?, album: String?) {
        guard admitCallback(token: token, window: window, tab: tab) else { return }
        let known = flags & BARC_MEDIA_KNOWN.rawValue != 0
        let playing = flags & BARC_MEDIA_PLAYING.rawValue != 0, video = flags & BARC_MEDIA_VIDEO.rawValue != 0
        let media = known ? PageMedia(hasMedia: flags & BARC_MEDIA_CONTROLLABLE.rawValue != 0,
            isAudible: flags & BARC_MEDIA_AUDIBLE.rawValue != 0,
            isPlaying: playing, hasVideo: video, isPlayingVideo: playing && video,
            handlesPreviousTrack: flags & BARC_MEDIA_PREVIOUS.rawValue != 0, handlesNextTrack: flags & BARC_MEDIA_NEXT.rawValue != 0,
            canPlay: flags & BARC_MEDIA_CAN_PLAY.rawValue != 0, canPause: flags & BARC_MEDIA_CAN_PAUSE.rawValue != 0,
            title: title.flatMap { $0.isEmpty ? nil : $0 }, artist: artist.flatMap { $0.isEmpty ? nil : $0 },
            album: album.flatMap { $0.isEmpty ? nil : $0 }) : nil
        var next = state
        next.media = media
        if known { next.isAudible = flags & BARC_MEDIA_AUDIBLE.rawValue != 0 }
        if next != state { state = next; onEvent?(.mediaChanged(media)) }
    }

    private func receive(token: UInt64, event: BarcTabEvent, window: Int32, tab: Int32,
                         url: URL?, title: String?, error: Int32, flags: UInt32) {
        guard admitCallback(token: token, window: window, tab: tab, terminal: event == BARC_TAB_CLOSED) else { return }
        let sameDocument = flags & BARC_TAB_SAME_DOCUMENT.rawValue != 0
        if event == BARC_TAB_NATIVE_BLOCKED || event == BARC_TAB_CONTINUE_NATIVE_BLOCK {
            // The rejected target is independent of the displayed document.
            // Never infer native blocker provenance from a generic net error.
            if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                onEvent?(event == BARC_TAB_NATIVE_BLOCKED ? .nativeBlocked(url) : .continueNativeBlock(url))
            }
            return
        }
        if event == BARC_TAB_PEEK_REQUESTED { // Link intent must never overwrite the source snapshot.
            if peekEnabled, error > 0, let url {
                pendingPeekRequest = error
                onEvent?(.peekRequested(url))
            }
            return
        }
        if event == BARC_TAB_CLOSE_CANCELLED { // Not navigation cancellation.
            onNativeCloseOutcome?(.cancelled)
            return
        }
        if event == BARC_TAB_CLOSED { // The engine has already ended observation.
            observation = 0
            isClosed = true
            let outcome: PageCloseOutcome = flags & BARC_TAB_OWNER_ENDED.rawValue != 0 ? .ownerEnded : .closed
            nativeCloseOutcome = outcome
            let notify = onEvent
            let closeOutcome = onNativeCloseOutcome
            invalidate()
            // Let a pending unload/delete finish before the general closed
            // event can be interpreted as an unsolicited model deletion.
            let deliver = {
                closeOutcome?(outcome)
                notify?(outcome == .ownerEnded ? .ownerEnded : .closed)
            }
            // CLOSED arrives inside a bridge callback, where tab_select
            // refuses the selection the app makes next.
            if outcome == .closed { Task { @MainActor in deliver() } } else { deliver() }
            return
        }
        if event == BARC_TAB_STARTED || (event == BARC_TAB_COMMITTED && !sameDocument) {
            cancelElementPicker()
            if event == BARC_TAB_STARTED { cancelScript(); cancelFileDownloads() }
            pendingPeekRequest = 0
        }
        var media = state.media
        let provisional = flags & BARC_TAB_PROVISIONAL.rawValue != 0
        let audible = flags & BARC_TAB_AUDIBLE.rawValue != 0, pipKnown = flags & BARC_TAB_PIP_STATE_KNOWN.rawValue != 0
        if (event == BARC_TAB_COMMITTED && !sameDocument) || (event == BARC_TAB_FAILED && !provisional) { media = nil }
        if let current = media?.isAudible, current != audible {
            media?.isAudible = audible
        }
        let loading = flags & BARC_TAB_LOADING.rawValue != 0
        let ended = event == BARC_TAB_FAILED || event == BARC_TAB_FINISHED
            || (event == BARC_TAB_COMMITTED && sameDocument)
        let began = event == BARC_TAB_STARTED || (event == BARC_TAB_COMMITTED && !sameDocument)
            || (!state.isLoading && loading)
        if ended { progressSuppressedUntilNextLoad = true }
        else if began { progressSuppressedUntilNextLoad = false }
        let snapshot = PageNavigationState(
            url: url, title: title, isLoading: loading,
            canGoBack: flags & BARC_TAB_BACK.rawValue != 0, canGoForward: flags & BARC_TAB_FORWARD.rawValue != 0,
            isAudioMuted: flags & BARC_TAB_MUTED.rawValue != 0, isAudible: audible,
            hasVideoPictureInPicture: pipKnown ? flags & BARC_TAB_VIDEO_PIP.rawValue != 0 : nil,
            hasDocumentPictureInPicture: pipKnown ? flags & BARC_TAB_DOCUMENT_PIP.rawValue != 0 : nil, media: media,
            loadProgress: loading && !began && !ended ? state.loadProgress : nil)
        if state != snapshot {
            state = snapshot
            onStateChanged?(snapshot)
        }
        guard !invalidated else { return }
        if event == BARC_TAB_STARTED || event == BARC_TAB_COMMITTED { cancelThumbnail() }
        if event == BARC_TAB_COMMITTED && !sameDocument { cancelStyle(); cancelTranslation() }
        guard !invalidated else { return }
        switch event {
        case BARC_TAB_STARTED: onEvent?(.started(url))
        case BARC_TAB_COMMITTED: onEvent?(.committed(url, sameDocument: sameDocument))
        case BARC_TAB_FINISHED: onEvent?(.finished(url, title: title, isReload: flags & BARC_TAB_RELOAD.rawValue != 0))
        case BARC_TAB_FAILED:
            if flags & BARC_TAB_ABORTED.rawValue != 0 {
                onEvent?(.cancelled(committedURL: url))
                return
            }
            let failure = NSError(domain: "Barc.Chromium.Navigation", code: Int(error),
                                  userInfo: [NSLocalizedDescriptionKey: "The page could not be loaded."])
            onEvent?(.failed(failure, provisional: provisional, committedURL: url))
        case BARC_TAB_TITLE: if let title { onEvent?(.titleChanged(title)) }
        default: break  // INITIAL and STATE never invent a history visit.
        }
        if !invalidated, (event == BARC_TAB_COMMITTED && !sameDocument) || event == BARC_TAB_FINISHED {
            let actions = nativePageReadyActions
            nativePageReadyActions.removeAll()
            for action in actions.values { action() }
        }
    }
}


extension ChromiumPageNavigation: VaultNativePage {
    var vaultProfileID: UUID? { profileID }
    func observeVaultPasskeys(_ callback: (@MainActor (VaultNativePasskeyRequest?) -> Void)?) {
        let previous = vaultPasskeyCallback; vaultPasskeyCallback = callback
        if callback == nil { previous?(nil) }
        guard !invalidated, observation != 0 else { callback?(nil); return }
        let native: BarcVaultPasskeyCallback? = callback == nil ? nil : { pointer, token, request, operation, arguments, nativeView in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                guard let owner = context.owner, owner.observation == token, !owner.invalidated else { return }
                guard request != 0, operation == BARC_PASSKEY_REGISTER.rawValue || operation == BARC_PASSKEY_ASSERT.rawValue, let nativeView,
                      let args = ChromiumPageNavigation.fileString(arguments,limit:65537),
                      owner.vaultPasskeyIsCurrent(request) else { owner.vaultPasskeyCallback?(nil); return }
                let view = Unmanaged<NSView>.fromOpaque(nativeView).takeUnretainedValue()
                owner.vaultPasskeyCallback?(VaultNativePasskeyRequest(token:request,operation:operation,arguments:args,view:view))
            }
        }
        if bridge.tab_observe_vault_passkeys(observation,native) != 1 { callback?(nil) }
    }
    func vaultPasskeyIsCurrent(_ token: UInt64) -> Bool {
        !invalidated && !isClosed && observation != 0 && window > 0 && matchesProfile(window) &&
            bridge.tab_vault_passkey_is_current(observation,token) == 1
    }
    func completeVaultPasskey(_ token: UInt64, result: String?) -> Bool {
        guard observation != 0 else { return false }
        guard let result else { return bridge.tab_complete_vault_passkey(observation,token,0,nil) == 1 }
        guard !result.utf8.contains(0), result.utf8.count <= 262144, vaultPasskeyIsCurrent(token) else { return false }
        return result.withCString { bridge.tab_complete_vault_passkey(observation,token,1,$0) == 1 }
    }
    func observeVaultSave(_ callback: (@MainActor (VaultNativeSubmission?) -> Void)?) {
        let previous = vaultSaveCallback; vaultSaveCallback = callback
        if callback == nil { previous?(nil) }
        guard !invalidated, observation != 0 else { callback?(nil); return }
        let native: BarcVaultSaveCallback? = callback == nil ? nil : { pointer, token, submission, origin, username, password, nativeView in
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
        if bridge.tab_observe_vault_save(observation,native) != 1 { callback?(nil) }
    }
    func vaultSaveIsCurrent(_ token: UInt64) -> Bool {
        !invalidated && !isClosed && observation != 0 && window > 0 && matchesProfile(window) &&
            bridge.tab_vault_save_is_current(observation,token) == 1
    }
    func cancelVaultSave(_ token: UInt64) {
        if observation != 0 { _ = bridge.tab_cancel_vault_save(observation,token) }
    }
    func observeVault(_ callback: (@MainActor (VaultNativeFocus?) -> Void)?) {
        let previous = vaultCallback
        vaultCallback = callback
        if callback == nil { previous?(nil) }
        guard !invalidated, observation != 0 else { callback?(nil); return }
        let native: BarcVaultCallback? = callback == nil ? nil : { pointer, token, focus, origin, kind, nativeView, x, y, width, height in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                guard let owner = context.owner, owner.observation == token, !owner.invalidated else { return }
                guard focus != 0, kind == BARC_VAULT_PASSWORD.rawValue || kind == BARC_VAULT_ONE_TIME_CODE.rawValue, let nativeView,
                      let origin = ChromiumPageNavigation.fileString(origin, limit: 4096),
                      [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0 else {
                    owner.vaultCallback?(nil); return
                }
                let view = Unmanaged<NSView>.fromOpaque(nativeView).takeUnretainedValue()
                var rect = CGRect(x:x,y:y,width:width,height:height)
                if !view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                rect = rect.intersection(view.bounds)
                guard !rect.isNull, !rect.isEmpty, owner.vaultFocusIsCurrent(focus) else { owner.vaultCallback?(nil); return }
                owner.vaultCallback?(VaultNativeFocus(token:focus,origin:origin,isCode:kind == BARC_VAULT_ONE_TIME_CODE.rawValue,view:view,anchor:rect))
            }
        }
        if bridge.tab_observe_vault(observation, native) != 1 { callback?(nil) }
    }
    func vaultFieldIsCurrent(_ token: UInt64) -> Bool {
        !invalidated && !isClosed && observation != 0 && window > 0 && matchesProfile(window) &&
            bridge.tab_vault_field_is_current(observation, token) == 1
    }
    func cancelVaultFocus(_ token: UInt64) { if observation != 0 { _ = bridge.tab_cancel_vault_focus(observation, token) } }
    func vaultFocusIsCurrent(_ token: UInt64) -> Bool {
        !invalidated && !isClosed && observation != 0 && window > 0 && matchesProfile(window) &&
            bridge.tab_vault_focus_is_current(observation,token) == 1
    }
    func fillVault(_ token: UInt64, username: String, secret: String) -> Bool {
        guard !username.utf8.contains(0), !secret.utf8.contains(0), vaultFocusIsCurrent(token) else { return false }
        return username.withCString { username in secret.withCString { secret in bridge.tab_fill_vault(observation,token,username,secret) == 1 } }
    }
}
