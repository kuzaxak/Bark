// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore
import NookSettings
import Observation

/// Owns a live native resource, including a page outside the saved tree. The
/// owner must outlive its pages and outstanding close requests; PageSession
/// holds it weakly. All calls/completions run on MainActor.
@MainActor
public protocol NativePageResourceOwner: AnyObject {
    /// Complete only on actual tab deletion, cancellation, or logical owner end.
    /// Detached pages use the same release contract without a model window.
    func closePage(_ page: any PageNavigation,
                   completion: @escaping @MainActor (PageCloseOutcome) -> Void)
    /// As `closePage`. If the page is still shown when it actually closes, the
    /// engine shows `successor` in its place rather than a page of its own choosing.
    func closePage(_ page: any PageNavigation, showing successor: any PageNavigation,
                   completion: @escaping @MainActor (PageCloseOutcome) -> Void)
}

public extension NativePageResourceOwner {
    func closePage(_ page: any PageNavigation, showing successor: any PageNavigation,
                   completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        closePage(page, completion: completion)
    }
}

/// The app's concrete native host owns process-local window/tab handles. Model
/// identity remains in TabsController.
@MainActor
public protocol NativePageHost: NativePageResourceOwner {
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
    /// Admit the already-prepared live panes. The dictionaries contain only the
    /// requested/previous panes, not another page registry. Never recreate pages.
    /// A stale previous collection may survive; the new layout must still be exact.
    func applySplit(_ record: SplitRecord?, replacing previous: SplitRecord?,
                    pages: [UUID: PageSession], activeItemID: UUID?,
                    in window: BrowserWindowState, isCurrent: () -> Bool) -> Bool
    /// Pure current layout/header/active-pane validation after native callouts.
    func isSplit(_ record: SplitRecord?, pages: [UUID: PageSession],
                 activeItemID: UUID?, in window: BrowserWindowState) -> Bool
}

/// A native host can settle a space intent without inferring the winner from
/// discovery notifications. The browser still owns all prompt interactions.
@MainActor
public protocol NativeSpaceSwitchHost: NativePageHost {
    func switchSpace(to profile: Profile, page: (any PageNavigation)?,
                     in window: BrowserWindowState, isCurrent: @escaping @MainActor () -> Bool,
                     completion: @escaping @MainActor (NativeSpaceSwitchOutcome) -> Void)
}

public enum NativeSpaceSwitchOutcome {
    case applied((any PageNavigation)?)
    case superseded(NativeSpaceSwitchSelection)
    case refused(retained: NativeSpaceSwitchSelection?)
    case closed
    case unresolved
}

public enum NativeSpaceSwitchSelection {
    case page(any PageNavigation)
    case empty(profileID: UUID)
}

struct NativePageCreation {
    let id: UUID
    let profileID: UUID
    let windowID: UUID
    var cancel: (@MainActor () -> Void)?
    var backgroundAdmission: (@MainActor () -> Bool)? = nil
}

struct NativePageRelease {
    let id: UUID
    var completions: [@MainActor (PageCloseOutcome) -> Void]
}

extension PageSession {
    var requiresNativeResourceRelease: Bool {
        usesNativePageHost && (navigation != nil || nativeCreation != nil)
    }

    func cancelNativeCreation(notifyPreparation: Bool = true) {
        let pending = nativeCreation
        nativeCreation = nil
        nativeRequestedURL = nil
        // Keep the cold query, but retire any metadata callback owned by the
        // cancelled attempt (including a same-query retry).
        if let intent = nativeSearchIntent { nativeSearchIntent = (UUID(), intent.query, nil) }
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
                          backgroundAdmission: (@MainActor () -> Bool)? = nil,
                          completion: (@MainActor (Bool) -> Void)? = nil) {
        restorePendingNativeSearch()
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
            if pending.profileID == profile.id && pending.windowID == window.id {
                // A user selection/split preparation takes over the same request.
                if pending.backgroundAdmission != nil { nativeCreation?.backgroundAdmission = backgroundAdmission }
                return
            }
            cancelNativeCreation(notifyPreparation: false)
        }
        let id = UUID()
        nativeCreation = NativePageCreation(id: id, profileID: profile.id,
                                            windowID: window.id, cancel: nil, backgroundAdmission: backgroundAdmission)
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
            if let allow = self.nativeCreation?.backgroundAdmission, !allow(),
               self.nativeCreation?.id == id, self.nativeCreation?.backgroundAdmission != nil {
                self.nativeCreation = nil
                self.loadingState = .idle
                self.finishNativePreparation(false)
                if case .success(let page) = result { Self.releaseUnaccepted(page, through: host) }
                return
            }
            // Admission is pure in production; preserve any newer reentrant request.
            guard self.nativeCreation?.id == id else {
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
                self.loadNativeTarget(target, through: page)
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

    func requestNativeRelease(showing successor: (any PageNavigation)? = nil,
                              completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
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
        let completion: @MainActor (PageCloseOutcome) -> Void = { [weak self, weak page] outcome in
            guard let self, let page, self.nativeRelease?.id == id,
                  self.navigation === page else { return }
            self.completeNativeRelease(outcome)
        }
        if let successor { host.closePage(page, showing: successor, completion: completion) }
        else { host.closePage(page, completion: completion) }
    }

    func completeNativeRelease(_ outcome: PageCloseOutcome) {
        if outcome == .ownerEnded { nativeOwnerEnded(); return }
        guard let release = nativeRelease else { return }
        nativeRelease = nil
        if outcome == .closed {
            let page = navigation
            navigation = nil
            resetNativeBoostCSS()
            nativeResourceHost = nil
            // Observation-only invalidation is safe now: the host confirmed
            // actual resource destruction. Never issue another stop/close.
            page?.invalidate()
            if !isPrivate && !isDetached { controller?.nativeSyncAdmissionChanged() }
        } else {
            nativeIsEnding = false
        }
        for completion in release.completions { completion(outcome) }
        // Refusal callbacks may synchronously start a retry. Do not clear the
        // new release's guard or resume a selection into its pending close.
        guard nativeRelease == nil else { return }
        nativeIsEnding = false
        if outcome == .cancelled { refreshNativeBoostCSS() }
        if !nativePreparationCompletions.isEmpty || nativeRequestedURL != nil { ensureNativePage() }
    }
}

// Hosts without native split support refuse admission without model mutation.
public extension NativePageHost {
    func applySplit(_ record: SplitRecord?, replacing previous: SplitRecord?,
                    pages: [UUID: PageSession], activeItemID: UUID?,
                    in window: BrowserWindowState, isCurrent: () -> Bool) -> Bool { false }
    func isSplit(_ record: SplitRecord?, pages: [UUID: PageSession],
                 activeItemID: UUID?, in window: BrowserWindowState) -> Bool { false }
}

extension TabsController {
    /// Optional startup admission only. Foreground and displayed-page preparation
    /// never consults this ceiling, and no admitted page is evicted to meet it.
    public func warmNativeStartupPages(in window: BrowserWindowState,
                                      while canWarm: @escaping @MainActor () -> Bool) async {
        guard profileEngine == .chromium, !window.isIncognito, window.privateTree == nil,
              let spaceID = window.spaceID, let profileID = tree.dataStoreID(for: spaceID),
              isProfileAvailable(profileID), settings.startupLoadMode != .nothing else { return }
        let startup = settings.startupLoadMode, mode = settings.tabManagementMode
        let ids = startup == .favorites ? favorites(of: spaceID).map(\.id) : displayOrder(in: window)
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var pending = false, failed = false, cursor = 0
        var cancelPreparation: (@MainActor () -> Void)?
        weak var loadingPage: PageSession?
        func current() -> Bool {
            canWarm() && !isTerminating && !Task.isCancelled &&
                windowRegistry.windows[window.id] === window && !window.isIncognito &&
                window.spaceID == spaceID && tree.dataStoreID(for: spaceID) == profileID &&
                isProfileAvailable(profileID) && settings.startupLoadMode == startup &&
                settings.tabManagementMode == mode
        }
        func count() -> Int { sessions.reduce(0) { $0 + ($1.navigation != nil ? 1 : 0) } }
        func foregroundBarrier() -> (waiting: Bool, unavailable: Bool) {
            // The window map itself is not observable.
            _ = windowRegistry.registrationRevision
            var waiting = false, unavailable = false
            for displayedWindow in windowRegistry.windows.values {
                if displayedWindow.nativePresentationIsPreparing {
                    waiting = true
                    _ = displayedWindow.nativeSelectionSession?.loadingState
                }
                let selected = displayedWindow.selectedItemID
                let displayed = displayedWindow.split.flatMap { split in
                    selected.map(split.contains) == true ? split.itemIDs : nil
                } ?? selected.map { [$0] } ?? []
                for id in displayed {
                    guard let page = session(for: id) else { waiting = true; continue }
                    _ = page.loadingState
                    if page.navigation == nil {
                        if page.nativeCreation != nil { waiting = true }
                        else { unavailable = true }
                    } else if let navigation = page.navigation {
                        if nativePageHost?.canAdoptPage(navigation, in: displayedWindow) != true {
                            unavailable = true
                        } else if !page.nativeStartupNavigationHasSettled { waiting = true }
                    }
                }
            }
            return (waiting, unavailable)
        }
        func eligible(_ id: UUID) -> Bool {
            guard let url = nativeStartupTarget(for: id), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", !isInAgentSpace(id),
                  favorites(of: spaceID).contains(where: { $0.id == id }) || self.spaceID(of: id) == spaceID,
                  !isVisibleInAnyWindow(id) else { return false }
            return true
        }
        defer { cancelPreparation?(); events.continuation.finish() }
        events.continuation.yield(())
        for await _ in events.stream {
            let facts = withObservationTracking {
                let valid = current()
                let admitted = count()
                let foreground = foregroundBarrier()
                var waiting = foreground.waiting, unavailable = foreground.unavailable
                // The existing creation owns the sole background reservation;
                // another task cannot race a cancelled task's deferred cleanup.
                for page in sessions where page.nativeCreation?.backgroundAdmission != nil {
                    _ = page.loadingState
                    if !pending || loadingPage !== page { waiting = true }
                }
                if let page = loadingPage, !pending {
                    _ = page.loadingState
                    if let navigation = page.navigation {
                        if nativePageHost?.canAdoptPage(navigation, in: window) != true { unavailable = true }
                        else if !page.nativeStartupNavigationHasSettled { waiting = true }
                    } else { unavailable = true }
                }
                return (valid, admitted, waiting, unavailable)
            } onChange: {
                // Observation reports willSet. Recheck after the mutation, never poll.
                DispatchQueue.main.async { events.continuation.yield(()) }
            }
            guard facts.0, !failed, !facts.3 else { return }
            if pending || facts.2 { continue }
            guard facts.1 < mode.startupWarmLimit else { return }
            loadingPage = nil
            var candidate: UUID?
            while cursor < ids.count {
                let id = ids[cursor]; cursor += 1
                guard eligible(id), session(for: id)?.navigation == nil,
                      session(for: id)?.nativeCreation == nil else { continue }
                candidate = id; break
            }
            guard let id = candidate else { return }
            pending = true
            let cancel = prepareNativeStartupPage(id, in: window, canAdmit: {
                // User selection or another window may start restoring while
                // this optional factory is in flight. Refuse its late result
                // until foreground preparation settles.
                guard current(), eligible(id), count() < mode.startupWarmLimit else { return false }
                let foreground = foregroundBarrier()
                return !foreground.waiting && !foreground.unavailable
            }) { prepared in
                pending = false
                cancelPreparation = nil
                failed = !prepared
                loadingPage = prepared ? self.session(for: id) : nil
                events.continuation.yield(())
            }
            if pending { cancelPreparation = cancel } else { cancel() }
        }
    }

    /// Match ensureSession's saved-current-page restoration without creating a
    /// cold session. A live pending explicit target takes precedence over both.
    private func nativeStartupTarget(for id: UUID) -> URL? {
        if let page = session(for: id) { return page.nativeRequestedURL ?? page.url }
        guard case .main? = owner(ofItem: id), let home = tree.item(id)?.url else { return nil }
        return tree.scope(of: id) == .synced ? device.openPages[id]?.url ?? home : home
    }

    /// One cancellable claim on existing preparation. Selection/split admission
    /// clears the background restriction and owns its continuation independently.
    @discardableResult
    func prepareNativeStartupPage(_ id: UUID, in window: BrowserWindowState,
                                  canAdmit: @escaping @MainActor () -> Bool,
                                  completion: @escaping @MainActor (Bool) -> Void) -> (@MainActor () -> Void) {
        var callback: (@MainActor (Bool) -> Void)? = completion
        func finish(_ ready: Bool) { let done = callback; callback = nil; done?(ready) }
        guard profileEngine == .chromium, windowRegistry.windows[window.id] === window,
              !window.isIncognito,
              let target = nativeStartupTarget(for: id), ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              let page = ensureSession(for: id), !page.isDetached,
              !page.isPrivate, page.navigation == nil, page.nativeCreation == nil,
              let profile = page.profile, profile.engine == .chromium, !profile.isEphemeral,
              window.spaceID.flatMap({ tree.dataStoreID(for: $0) }) == profile.id,
              canAdmit() else { finish(false); return {} }
        page.ensureNativePage(in: window, backgroundAdmission: { [weak self] in
            guard let target = self?.nativeStartupTarget(for: id),
                  ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return false }
            return canAdmit()
        }) { [weak self, weak page, weak window] ready in
            guard ready, let self, let page, let window,
                  self.session(for: id) === page,
                  self.windowRegistry.windows[window.id] === window,
                  let navigation = page.navigation,
                  self.nativePageHost?.canAdoptPage(navigation, in: window) == true else {
                finish(false); return
            }
            if !self.isNativePageOwner(page, in: window) { self.recordPageOwner(id, in: window) }
            finish(true)
        }
        let request = page.nativeCreation?.id
        return { [weak page] in
            guard callback != nil else { return }
            finish(false)
            guard let page, let request, page.nativeCreation?.id == request,
                  page.nativeCreation?.backgroundAdmission != nil else { return }
            page.cancelNativeCreation()
        }
    }
}
