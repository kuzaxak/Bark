// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// The app's concrete native host owns process-local window/tab handles. Model
/// identity remains in TabsController. All calls/completions run on MainActor.
@MainActor
public protocol NativePageHost: AnyObject {
    /// Produce one inactive blank page. Never present it before model admission.
    /// Complete exactly once. Cancellation is best effort and a no-op after
    /// completion; any late successful result must still be delivered for release.
    /// The host must outlive its pages and outstanding native requests. Private
    /// metadata must use actual private native ownership, never a regular UUID.
    func createPage(for session: PageSession, profile: Profile, in window: BrowserWindowState,
                    completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void)
        -> (@MainActor () -> Void)
    /// Pure admission query for an existing, unmodified page. Validate this host,
    /// model window, native owner/profile and live membership; reject ending or
    /// pending-close owners. This must not select, create, navigate or close.
    func canAdoptPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool
    /// Actual selection admission, including transfer when necessary. False
    /// leaves the existing owner intact; it is not a completed focus claim.
    func selectPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool
    /// Attach the existing product header only if this page is already the
    /// native selection. Never select, focus, load, show, or roll back a client.
    func acceptNativeSelection(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool
    /// Pure current native selection and exact product-header ownership check.
    func isNativeSelection(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool
    /// Report actual tab deletion, explicit cancellation, or logical owner teardown.
    /// Dispatching a close request must not complete this operation.
    func closePage(_ page: any PageNavigation,
                   completion: @escaping @MainActor (PageCloseOutcome) -> Void)
}

struct NativePageCreation {
    let id: UUID
    let profileID: UUID
    let windowID: UUID
    var cancel: (@MainActor () -> Void)?
}

struct NativePageRelease {
    let id: UUID
    var completions: [@MainActor (PageCloseOutcome) -> Void]
}

extension PageSession {
    var usesNativePageHost: Bool {
        (detachedProfile?.engine ?? controller?.profileEngine ?? .webKit) == .chromium
    }

    var requiresNativeResourceRelease: Bool {
        usesNativePageHost && (navigation != nil || nativeCreation != nil)
    }

    func cancelNativeCreation(notifyPreparation: Bool = true) {
        let pending = nativeCreation
        nativeCreation = nil
        nativeRequestedURL = nil
        if pending != nil && navigation == nil { loadingState = .idle }
        if notifyPreparation { finishNativePreparation(false) }
        pending?.cancel?()
    }

    func cancelNativePreparation(in window: BrowserWindowState) {
        guard nativePreparationWindow === window else { return }
        nativePreparationWindow = nil
        cancelNativeCreation()
    }

    private func finishNativePreparation(_ prepared: Bool) {
        let completions = nativePreparationCompletions
        nativePreparationCompletions.removeAll()
        for completion in completions { completion(prepared) }
    }

    func ensureNativePage(in requestedWindow: BrowserWindowState? = nil,
                          completion: (@MainActor (Bool) -> Void)? = nil) {
        if let requestedWindow {
            if let previous = nativePreparationWindow, previous !== requestedWindow {
                cancelNativePreparation(in: previous)
            }
            nativePreparationWindow = requestedWindow
        }
        if let completion { nativePreparationCompletions.append(completion) }
        // A return/select intent remains queued through an actual release.
        // completeNativeRelease resumes it only after the ending guard clears.
        guard !nativeIsEnding else { return }
        guard let controller, controller.session(for: itemID) === self,
              let profile, profile.engine == .chromium,
              let host = controller.nativePageHost,
              let window = nativePreparationWindow ?? controller.nativePageWindow(for: self),
              controller.windowRegistry.windows[window.id] === window else {
            finishNativePreparation(false)
            return
        }
        nativePreparationWindow = window
        if let navigation {
            guard navigation.profileID == profile.id else {
                unload()
                return
            }
            finishNativePreparation(true)
            return
        }
        if let pending = nativeCreation {
            if pending.profileID == profile.id && pending.windowID == window.id { return }
            cancelNativeCreation(notifyPreparation: false)
        }
        let id = UUID()
        nativeCreation = NativePageCreation(id: id, profileID: profile.id,
                                            windowID: window.id, cancel: nil)
        loadingState = .didStartProvisionalNavigation
        let cancel = host.createPage(for: self, profile: profile, in: window) {
            [weak self, weak window] result in
            // Retain the host through completion so rejected native owners can
            // be released even when their model/session has disappeared.
            guard let self, let window,
                  self.nativeCreation?.id == id,
                  let controller = self.controller,
                  controller.session(for: self.itemID) === self,
                  controller.windowRegistry.windows[window.id] === window,
                  self.nativePreparationWindow === window,
                  self.profile?.id == profile.id,
                  controller.nativePageHost === host else {
                if let self, self.nativeCreation?.id == id {
                    self.nativeCreation = nil
                    self.loadingState = .idle
                    self.finishNativePreparation(false)
                }
                if case .success(let page) = result { Self.releaseUnaccepted(page, through: host) }
                return
            }
            self.nativeCreation = nil
            switch result {
            case .failure(let error):
                self.loadingState = .didFailProvisionalNavigation(error)
                self.finishNativePreparation(false)
            case .success(let page):
                guard page.profileID == profile.id else {
                    Self.releaseUnaccepted(page, through: host)
                    self.loadingState = .didFailProvisionalNavigation(URLError(.userAuthenticationRequired))
                    self.finishNativePreparation(false)
                    return
                }
                let target = self.nativeRequestedURL ?? self.url
                self.nativeRequestedURL = nil
                self.installNavigation(page)
                self.nativeResourceHost = host
                guard self.navigation === page,
                      controller.session(for: self.itemID) === self else {
                    Self.releaseUnaccepted(page, through: host)
                    self.finishNativePreparation(false)
                    return
                }
                page.load(target)
                self.finishNativePreparation(true)
            }
        }
        // A host may complete synchronously before returning its cancel token.
        if nativeCreation?.id == id { nativeCreation?.cancel = cancel }
        else { cancel() }
    }

    private static func releaseUnaccepted(_ page: any PageNavigation, through host: any NativePageHost) {
        host.closePage(page) { outcome in
            if outcome != .cancelled { page.invalidate() }
        }
    }

    func requestNativeRelease(completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        if nativeCreation != nil {
            cancelNativeCreation()
        }
        // Refuse reentrant release while terminal cleanup is completing.
        guard !nativeIsEnding || navigation != nil || nativeRelease != nil else {
            completion(.cancelled)
            return
        }
        guard let page = navigation else { completion(.closed); return }
        if nativeRelease != nil {
            nativeRelease?.completions.append(completion)
            return
        }
        guard let host = nativeResourceHost ?? controller?.nativePageHost else {
            completion(.cancelled)
            return
        }
        let id = UUID()
        nativeRelease = NativePageRelease(id: id, completions: [completion])
        nativeIsEnding = true
        host.closePage(page) { [weak self, weak page] outcome in
            guard let self, let page, self.nativeRelease?.id == id,
                  self.navigation === page else { return }
            self.completeNativeRelease(outcome)
        }
    }

    func completeNativeRelease(_ outcome: PageCloseOutcome) {
        if outcome == .ownerEnded { nativeOwnerEnded(); return }
        guard let release = nativeRelease else { return }
        nativeRelease = nil
        if outcome == .closed {
            let page = navigation
            navigation = nil
            nativeResourceHost = nil
            // Observation-only invalidation is safe now: the host confirmed
            // actual resource destruction. Never issue another stop/close.
            page?.invalidate()
        } else {
            nativeIsEnding = false
        }
        for completion in release.completions { completion(outcome) }
        // Refusal callbacks may synchronously start a retry. Do not clear the
        // new release's guard or resume a selection into its pending close.
        guard nativeRelease == nil else { return }
        nativeIsEnding = false
        if !nativePreparationCompletions.isEmpty || nativeRequestedURL != nil { ensureNativePage() }
    }
}
