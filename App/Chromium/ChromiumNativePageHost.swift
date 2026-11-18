import AppKit
import BarcChromium
import Darwin
import NookWeb
import NookTabsCore

/// One observation admission attempt. Finish after the synchronous model
/// adoption result; abandoning it never closes the existing native contents.
@MainActor
final class ChromiumExistingPageBinding {
    let navigation: ChromiumPageNavigation
    private var completion: ((Bool) -> Void)?
    init(navigation: ChromiumPageNavigation, completion: @escaping (Bool) -> Void) {
        self.navigation = navigation; self.completion = completion
    }
    func finish(adopted: Bool) {
        let callback = completion
        completion = nil
        callback?(adopted)
    }
    isolated deinit { completion?(false) }
}

/// Only native handles are cached here. TabsController remains the model owner.
/// The app retains this host until Chromium stops delivering callbacks.
@MainActor
final class ChromiumNativePageHost: NativeSpaceSwitchHost {
    private struct CreationKey: Hashable { let window: UUID; let profile: UUID }
    @MainActor private final class Mount {
        weak var shell: NSView?
        weak var model: BrowserWindowState?
        let presenter: any ChromiumWindowPresenter
        let group: UInt64
        // Only our last successful header attachment, never native selection.
        var attachedClient: Int32?
        var generation: UInt64 = 0
        var spaceSwitchSequence: UInt64 = 0
        var hasSettledEmptySelection = false
        // Ownership identity only; SplitRecord remains the model's sole layout.
        var presentedSplit: (client: Int32, member: Int32, collection: Int32, kind: UInt32, generation: UInt64, count: UInt32)?
        // Native Peek may return the same sidebar to its source before catalog
        // reflection. These two owners suffice to reconcile the existing mount.
        var peekSidebarOwners: (source: Int32, peek: Int32)?
        var attemptedLiveRemainder: UInt64?
        // A Bark window's root showed a split, or its end, at least once.
        var hostSplitApplied = false
        init(shell: NSView, presenter: any ChromiumWindowPresenter, group: UInt64, attachedClient: Int32?, model: BrowserWindowState) {
            self.shell = shell; self.presenter = presenter; self.group = group; self.attachedClient = attachedClient; self.model = model
        }
    }
    @MainActor private final class Request {
        var cancelled = false
        var completed = false
        weak var session: PageSession?
        weak var profile: Profile?
        weak var window: BrowserWindowState?
        var completion: (@MainActor (Result<any PageNavigation, Error>) -> Void)?
        init(session: PageSession, profile: Profile, window: BrowserWindowState,
             _ completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void) {
            self.session = session; self.profile = profile; self.window = window
            self.completion = completion
        }
        func finish(_ result: Result<any PageNavigation, Error>) {
            guard !completed else { return }
            completed = true
            let callback = completion
            completion = nil
            callback?(result)
        }
    }
    @MainActor private final class Batch {
        weak var host: ChromiumNativePageHost?
        let key: CreationKey
        let group: UInt64
        var requests: [Request]
        var clientReady: [@MainActor (Int32?) -> Void] = []
        var native: Int32?
        var cleanupPages: [ChromiumPageNavigation] = []
        var cleanupTabs: Set<Int32> = []
        var cleanupClosing: Set<ObjectIdentifier> = []
        var blank: Int32?
        var failedAdmission = false
        weak var mount: Mount?
        init(host: ChromiumNativePageHost, key: CreationKey, group: UInt64, request: Request) {
            self.host = host; self.key = key; self.group = group; requests = [request]
            mount = host.mounts[key.window]
        }
    }
    @MainActor private final class Binding {
        var window: UUID
        var admissionGeneration: UInt64 = 0
        let page: ChromiumPageNavigation
        var owned: Bool
        var attempts = 0
        let invalidatesUnclaimed: Bool
        var priorCloseOutcome: ((PageCloseOutcome) -> Void)?
        weak var cleanupBatch: Batch?
        init(window: UUID, page: ChromiumPageNavigation, owned: Bool, invalidatesUnclaimed: Bool = true) {
            self.window = window; self.page = page; self.owned = owned
            self.invalidatesUnclaimed = invalidatesUnclaimed
            if !invalidatesUnclaimed { priorCloseOutcome = page.onNativeCloseOutcome }
        }
    }
    private let bridge: BarcBridge
    private var blocker: ChromiumContentBlocker?
    private struct BlankReservation { let tab: Int32; let group: UInt64 }
    private var mounts: [UUID: Mount] = [:]
    private var blankTabs: [Int32: BlankReservation] = [:]
    private var opening: [CreationKey: Batch] = [:]
    private var pages: [ObjectIdentifier: Binding] = [:]
    var peekOnShiftClick = true {
        didSet {
            guard peekOnShiftClick != oldValue else { return }
            for binding in pages.values where binding.owned {
                binding.page.setNativePeekCapability(true, onShiftClick: peekOnShiftClick)
            }
        }
    }
    private var closing: [ObjectIdentifier: [@MainActor (PageCloseOutcome) -> Void]] = [:]
    /// Copy the bridge's borrowed records before delivery returns.
    private struct SettledSpaceSwitch {
        let request: UInt64
        let group: UInt64
        let status: Int32
        let client: Int32
        let tab: Int32
        let prompts: [BarcSpaceSwitchPrompt]

        init?(_ result: BarcSpaceSwitchResult) {
            guard result.size >= MemoryLayout<BarcSpaceSwitchResult>.size,
                  result.prompt_count == 0 || result.prompts != nil else { return nil }
            let prompts = Array(UnsafeBufferPointer(start: result.prompts, count: result.prompt_count))
            guard prompts.allSatisfy({ $0.size >= MemoryLayout<BarcSpaceSwitchPrompt>.size }) else { return nil }
            request = result.request
            group = result.physical_group
            status = result.status
            client = result.selected_client
            tab = result.active_tab
            self.prompts = prompts
        }
    }

    @MainActor private final class SpaceSwitchDelivery {
        let finish: @MainActor (SettledSpaceSwitch?) -> Void
        init(_ finish: @escaping @MainActor (SettledSpaceSwitch?) -> Void) { self.finish = finish }
    }

    @MainActor private final class EmptySpaceOpening {
        weak var host: ChromiumNativePageHost?
        let key: CreationKey
        let group: UInt64
        var ready: [@MainActor (Int32?) -> Void] = []
        var pageRequests: [Request] = []
        init(host: ChromiumNativePageHost, key: CreationKey, group: UInt64) {
            self.host = host; self.key = key; self.group = group
        }
    }
    private var emptySpaceOpening: [CreationKey: EmptySpaceOpening] = [:]
    /// The window shows no page of its own: an empty space, or a page another window holds.
    var pageIsHidden: (BrowserWindowState) -> Bool = { $0.showsNativeEmptySpace }

    init(bridge: BarcBridge, blocker: ChromiumContentBlocker? = nil) {
        self.bridge = bridge
        self.blocker = blocker
    }

    /// Register one model/product shell for a real physical group. This is
    /// pure: discovered shells may remain unattached until native reflection.
    func registerWindow(_ window: BrowserWindowState, nativeOwner: Int32,
                        shell: NSView, initialBlankTab: Int32? = nil) -> Bool {
        guard mounts[window.id] == nil, let row = liveState(nativeOwner),
              !mounts.values.contains(where: { $0.shell === shell || $0.group == row.physical_group }),
              bridge.window_set_app_lifetime(nativeOwner) == 1 else { return false }
        let presenter = ChromiumWindowPresenters.make(bridge: bridge, client: nativeOwner, sidebar: shell)
        let owned = presenter.ownsSidebar(nativeOwner)
        mounts[window.id] = Mount(shell: shell, presenter: presenter, group: row.physical_group,
                                  attachedClient: owned ? nativeOwner : nil, model: window)
        presenter.setPageHidden(pageIsHidden(window), client: nativeOwner)
        if let initialBlankTab { blankTabs[nativeOwner] = BlankReservation(tab: initialBlankTab, group: row.physical_group) }
        return true
    }

    /// The window and the point in it a download that starts now in `window` flies from.
    func downloadLaunch(in window: BrowserWindowState) -> (window: NSWindow, point: NSPoint)? {
        guard let mount = mounts[window.id], mount.model === window else { return nil }
        return mount.presenter.downloadLaunch()
    }

    /// The empty-space panel covers the page Chromium keeps selected, so its page
    /// commands must do nothing until the window shows a page again.
    func setPageHidden(_ hidden: Bool, in window: BrowserWindowState) {
        guard let mount = mounts[window.id], mount.model === window,
              let client = liveClient(in: window.id) else { return }
        mount.presenter.setPageHidden(hidden, client: client)
    }

    /// Catalog disappearance ends registration, not any still-live moved tab.
    /// Actual terminal events remain authoritative for resource/model teardown.
    func unregisterWindow(_ window: BrowserWindowState, absentFrom snapshot: ChromiumDiscoverySnapshot) -> Bool {
        guard let mount = mounts[window.id], mount.model === window,
              !snapshot.windows.contains(where: { $0.physical_group == mount.group }) else { return false }
        mounts.removeValue(forKey: window.id)
        blankTabs = blankTabs.filter { $0.value.group != mount.group }
        // Keep batches retained until their promised C completion: userdata is
        // borrowed by the runtime. Late factory results still get released.
        for batch in opening.values.filter({ $0.key.window == window.id }) {
            for request in batch.requests {
                request.cancelled = true
                request.finish(.failure(HostError.missingWindow))
            }
        }
        return true
    }

    func createPage(for session: PageSession, profile: Profile, in window: BrowserWindowState,
                    completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void)
        -> (@MainActor () -> Void) {
        let request = Request(session: session, profile: profile, window: window, completion)
        enqueue(request)
        return {
            if !request.completed { request.cancelled = true }
        }
    }

    private func enqueue(_ request: Request) {
        guard !request.completed, !request.cancelled,
              request.session != nil, let profile = request.profile, let window = request.window else {
            request.finish(.failure(HostError.cancelled)); return
        }
        guard supports(profile, in: window) else {
            request.finish(.failure(HostError.unsupportedProfile))
            return
        }
        let key = CreationKey(window: window.id, profile: profile.id)
        guard let mount = mounts[window.id], mount.model === window, mount.shell != nil else {
            request.finish(.failure(HostError.missingWindow)); return
        }
        if let empty = emptySpaceOpening[key] {
            empty.pageRequests.append(request)
        } else if let batch = opening[key] {
            guard batch.group == mount.group, batch.mount === mount else { request.finish(.failure(HostError.missingWindow)); return }
            batch.requests.append(request)
            if batch.failedAdmission { retryCleanup(batch) }
        } else if let client = liveClient(in: window.id, profile: profile.id) {
            if let blocker {
                let batch = Batch(host: self, key: key, group: mount.group, request: request)
                opening[key] = batch
                batch.native = client
                Task { @MainActor [weak self, batch] in
                    let ready = await blocker.prepare(in: client)
                    self?.prepared(batch, client: client, ready: ready, fresh: false)
                }
            } else {
                request.finish(makePage(key: key, client: client))
            }
        } else {
            // Private pages may only reuse this session's exact live client;
            // a regular UUID factory must never recreate a private identity.
            guard !profile.isEphemeral else {
                request.finish(.failure(HostError.unsupportedProfile)); return
            }
            guard let owner = liveClient(in: window.id) else {
                request.finish(.failure(HostError.missingWindow)); return
            }
            let batch = Batch(host: self, key: key, group: mount.group, request: request)
            opening[key] = batch
            profile.id.uuidString.withCString { uuid in
                bridge.profile_open_in_native_window(owner, uuid, BARC_PROFILE_BLANK, { status, native, pointer in
                    MainActor.assumeIsolated {
                        guard let pointer else { return }
                        let batch = Unmanaged<Batch>.fromOpaque(pointer).takeUnretainedValue()
                        batch.host?.opened(batch, status: status, native: native)
                    }
                }, Unmanaged.passUnretained(batch).toOpaque())
            }
        }
    }

    /// Application construction precedes its model's blocker manager. Install
    /// exactly once before any native ownership or request can be admitted.
    func configureBlocker(_ blocker: ChromiumContentBlocker) -> Bool {
        guard self.blocker == nil, mounts.isEmpty, opening.isEmpty, pages.isEmpty,
              blankTabs.isEmpty, closing.isEmpty else { return false }
        self.blocker = blocker
        return true
    }

    private func opened(_ batch: Batch, status: barc_profile_status, native: Int32) {
        guard opening[batch.key] === batch else { return }
        let clientReady = batch.clientReady
        batch.clientReady.removeAll()
        var preparedClient: Int32?
        defer { for ready in clientReady { ready(preparedClient) } }
        if blocker != nil, status == BARC_PROFILE_OK, let row = liveState(native),
           row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue,
           bridge.identity(row) == batch.key.profile, row.physical_group == batch.group,
           !(mounts[batch.key.window] === batch.mount && batch.mount?.model != nil && batch.mount?.shell != nil) {
            batch.native = native; batch.blank = bridge.window_tab_at(native, 0)
            if let blank = batch.blank, blank > 0 { blankTabs[native] = BlankReservation(tab: blank, group: batch.group) }
            failAdmission(batch, pages: [], error: HostError.creationRefused)
            return
        }
        guard status == BARC_PROFILE_OK, let row = liveState(native),
              row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue,
              bridge.identity(row) == batch.key.profile,
              row.physical_group == batch.group,
              let mount = mounts[batch.key.window], mount.group == batch.group,
              mount.model != nil, mount.shell != nil else {
            if status == BARC_PROFILE_OK, let row = bridge.windowState(native),
               row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue,
               bridge.identity(row) == batch.key.profile { _ = bridge.window_close(native) }
            opening.removeValue(forKey: batch.key)
            batch.requests.forEach { $0.finish(.failure(HostError.creationRefused)) }
            return
        }
        batch.native = native
        preparedClient = native
        batch.blank = bridge.window_tab_at(native, 0)
        blankTabs[native] = BlankReservation(tab: batch.blank!, group: batch.group)
        if let blocker {
            Task { @MainActor [weak self, batch] in
                let ready = await blocker.prepare(in: native)
                self?.prepared(batch, client: native, ready: ready, fresh: true)
            }
            return
        }
        opening.removeValue(forKey: batch.key)
        // Create all admitted resources before calling user code: the first
        // completion may immediately close its page and otherwise kill client.
        let active = batch.requests.filter { !$0.cancelled }
        let owners = active.isEmpty ? Array(batch.requests.prefix(1)) : active
        let results = owners.map { ($0, makePage(key: batch.key, client: native)) }
        for request in batch.requests where !owners.contains(where: { $0 === request }) {
            request.finish(.failure(HostError.cancelled))
        }
        for (request, result) in results {
            if case .success(let navigation) = result,
               let page = navigation as? ChromiumPageNavigation, page.isClosed {
                request.finish(.failure(HostError.creationRefused))
            } else {
                // A cancelled sole owner receives its real late resource so
                // TabsController can release it via confirmed CLOSED.
                request.finish(result)
            }
        }
        if results.allSatisfy({ if case .failure = $0.1 { return true }; return false }) {
            _ = bridge.window_close(native) // Verified, unclaimed fresh blank client.
        }
    }

    private func requestIsCurrent(_ request: Request, key: CreationKey) -> Bool {
        guard !request.completed, !request.cancelled, let session = request.session,
              let profile = request.profile, let window = request.window,
              window.id == key.window, profile.id == key.profile,
              supports(profile, in: window), let controller = session.controller,
              controller.windowRegistry.windows[window.id] === window,
              controller.session(for: session.itemID) === session,
              controller.isProfileAvailable(profile.id) || profile.isEphemeral,
              let actual = session.profile, actual.id == profile.id,
              actual.isEphemeral == profile.isEphemeral else { return false }
        return !request.cancelled && !request.completed && controller.session(for: session.itemID) === session
    }

    private func prepared(_ batch: Batch, client: Int32, ready: Bool, fresh: Bool) {
        guard opening[batch.key] === batch, !batch.failedAdmission else { return }
        let current = liveState(client)
        let mounted = batch.mount != nil && mounts[batch.key.window] === batch.mount &&
            batch.mount?.model != nil && batch.mount?.shell != nil
        let validClient = current?.physical_group == batch.group && current.map {
            bridge.identity($0) == batch.key.profile &&
                ($0.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == (batch.mount?.model?.isIncognito == true)
        } == true
        guard ready, mounted, validClient else {
            if fresh, validClient {
                failAdmission(batch, pages: [], error: HostError.blockerUnavailable)
            } else {
                opening.removeValue(forKey: batch.key)
                batch.requests.forEach { $0.finish(.failure(HostError.blockerUnavailable)) }
            }
            return
        }
        let issued = batch.requests
        batch.requests = []
        let active = issued.filter { requestIsCurrent($0, key: batch.key) }
        if active.isEmpty {
            if fresh {
                batch.requests = issued + batch.requests
                failAdmission(batch, pages: [], error: HostError.cancelled)
            } else {
                if opening[batch.key] === batch { opening.removeValue(forKey: batch.key) }
                issued.forEach { $0.finish(.failure(HostError.cancelled)) }
                let waiting = batch.requests; batch.requests = []; waiting.forEach(enqueue)
            }
            return
        }
        // All resources and current exceptions are ready before any completion
        // can load/close one and thereby change the shared client's lifetime.
        var created: [(Request, ChromiumPageNavigation)] = []
        let results = active.map { request -> (Request, Result<any PageNavigation, Error>) in
            let result = makePage(key: batch.key, client: client, failedBlank: { batch.cleanupTabs.insert($0) })
            guard case .success(let navigation) = result, let page = navigation as? ChromiumPageNavigation
            else { return (request, result) }
            created.append((request, page))
            guard let session = request.session, requestIsCurrent(request, key: batch.key), !page.isClosed,
                  page.nativeWindowID == client, bridge.tab_copy_title(client, page.nativeTabID, nil, 0) > 0,
                  blocker?.apply(to: session, window: client, tab: page.nativeTabID) == true,
                  requestIsCurrent(request, key: batch.key) else {
                return (request, .failure(HostError.blockerUnavailable))
            }
            return (request, result)
        }
        let succeeded = Set(results.compactMap { pair -> ObjectIdentifier? in
            if case .success = pair.1 { return ObjectIdentifier(pair.0) }; return nil
        })
        // makePage records each fresh blank. Only unreturned blanks from this
        // operation may enter cleanup, never an existing/adopted document.
        let failedPages = created.filter { !succeeded.contains(ObjectIdentifier($0.0)) }.map { $0.1 }
        if !failedPages.isEmpty || !batch.cleanupTabs.isEmpty || (fresh && succeeded.isEmpty) {
            if fresh && created.isEmpty, let blank = batch.blank { batch.cleanupTabs.insert(blank) }
            batch.failedAdmission = true
            batch.cleanupPages = failedPages
            failedPages.forEach { pages[ObjectIdentifier($0)]?.cleanupBatch = batch }
        }
        for request in issued where !succeeded.contains(ObjectIdentifier(request)) &&
            !results.contains(where: { $0.0 === request }) { request.finish(.failure(HostError.cancelled)) }
        for (request, result) in results {
            if case .success(let navigation) = result, let page = navigation as? ChromiumPageNavigation,
               !(requestIsCurrent(request, key: batch.key) && !page.isClosed &&
                 page.nativeWindowID == client && bridge.tab_copy_title(client, page.nativeTabID, nil, 0) > 0 &&
                 request.session.map({ blocker?.apply(to: $0, window: client, tab: page.nativeTabID) == true }) == true &&
                 requestIsCurrent(request, key: batch.key)) {
                // An earlier completion can change policy or retire a later
                // request. Keep its unreturned blank under confirmed cleanup.
                batch.failedAdmission = true
                batch.cleanupPages.append(page)
                pages[ObjectIdentifier(page)]?.cleanupBatch = batch
                request.finish(.failure(HostError.blockerUnavailable))
            } else { request.finish(result) }
        }
        if batch.failedAdmission { retryCleanup(batch) }
        else {
            if opening[batch.key] === batch { opening.removeValue(forKey: batch.key) }
            let waiting = batch.requests; batch.requests = []; waiting.forEach(enqueue)
        }
    }

    private func failAdmission(_ batch: Batch, pages cleanup: [ChromiumPageNavigation], error: Error) {
        batch.failedAdmission = true
        batch.cleanupPages = cleanup
        let issued = batch.requests; batch.requests = []
        issued.forEach { $0.finish(.failure(error)) }
        retryCleanup(batch)
    }

    private func retryCleanup(_ batch: Batch) {
        guard opening[batch.key] === batch, batch.failedAdmission else { return }
        if let native = batch.native {
            // A missing immutable Browser SessionID, or its admitted terminal
            // flag, proves this owner's end. Missing tab membership alone does
            // not: the same tab may have moved to another live owner.
            let row = bridge.windowState(native)
            if row.map({ $0.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue != 0 }) == true ||
                (row == nil && bridge.readSnapshot().map({ snapshot in
                    !snapshot.windows.contains(where: { $0.window == native })
                }) == true) {
                if blankTabs[native]?.tab == batch.blank { blankTabs.removeValue(forKey: native) }
                opening.removeValue(forKey: batch.key)
                let waiting = batch.requests; batch.requests = []
                waiting.forEach(enqueue)
                return
            }
            if batch.cleanupPages.isEmpty, batch.cleanupTabs.isEmpty, let blank = batch.blank {
                batch.cleanupTabs.insert(blank)
            }
            for tab in batch.cleanupTabs {
                guard let row = liveState(native), row.physical_group == batch.group,
                      bridge.identity(row) == batch.key.profile,
                      bridge.tab_copy_title(native, tab, nil, 0) > 0,
                      let page = try? ChromiumPageNavigation(profileID: batch.key.profile, window: native, tab: tab,
                          bridge: bridge, privateSession: row.profile_kind == BARC_DISCOVERY_GUEST.rawValue) else { continue }
                if blankTabs[native]?.tab == tab { blankTabs.removeValue(forKey: native) }
                record(page, in: batch.key.window)
                batch.cleanupTabs.remove(tab)
                batch.cleanupPages.append(page)
                pages[ObjectIdentifier(page)]?.cleanupBatch = batch
            }
        }
        // Failed observation retains the original reservation/Batch. It cannot
        // invent a second blank or infer terminal closure from dispatch alone.
        for page in batch.cleanupPages where !batch.cleanupClosing.contains(ObjectIdentifier(page)) {
            if page.isClosed { cleanupEnded(batch, page: page); continue }
            let id = ObjectIdentifier(page)
            guard pages[id]?.cleanupBatch === batch, pages[id]?.admissionGeneration == 0,
                  page.nativeWindowID == batch.native, let row = liveState(page.nativeWindowID),
                  row.physical_group == batch.group, bridge.identity(row) == batch.key.profile,
                  (row.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == page.isPrivateSession,
                  bridge.tab_copy_title(page.nativeWindowID, page.nativeTabID, nil, 0) > 0,
                  page.state.url == nil || page.state.url?.absoluteString == "about:blank" else { continue }
            batch.cleanupClosing.insert(id)
            closePage(page) { [weak self, weak batch, weak page] outcome in
                guard let self, let batch, let page, self.opening[batch.key] === batch else { return }
                batch.cleanupClosing.remove(id)
                if outcome != .cancelled { self.cleanupEnded(batch, page: page) }
                else {
                    let issued = batch.requests; batch.requests = []
                    issued.forEach { $0.finish(.failure(HostError.blockerUnavailable)) }
                }
            }
        }
    }

    private func cleanupEnded(_ batch: Batch, page: ChromiumPageNavigation) {
        guard opening[batch.key] === batch, batch.cleanupPages.contains(where: { $0 === page }) else { return }
        batch.cleanupPages.removeAll { $0 === page }
        batch.cleanupClosing.remove(ObjectIdentifier(page))
        guard batch.cleanupPages.isEmpty, batch.cleanupTabs.isEmpty else { return }
        opening.removeValue(forKey: batch.key)
        let waiting = batch.requests.filter { !$0.completed }
        waiting.forEach(enqueue)
    }

    private func makePage(key: CreationKey, client: Int32, failedBlank: ((Int32) -> Void)? = nil) -> Result<any PageNavigation, Error> {
        guard let mount = mounts[key.window], let model = mount.model,
              let current = liveState(client), current.physical_group == mount.group,
              bridge.identity(current) == key.profile,
              (current.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == model.isIncognito else {
            return .failure(HostError.creationRefused)
        }
        let privateSession = model.isIncognito
        let tab = blankTabs.removeValue(forKey: client)?.tab ??
            "about:blank".withCString { bridge.tab_create(client, $0, 0) }
        guard tab > 0 else { return .failure(HostError.creationRefused) }
        do {
            let page = try ChromiumPageNavigation(profileID: key.profile, window: client, tab: tab, bridge: bridge, privateSession: privateSession)
            record(page, in: key.window)
            return .success(page)
        } catch {
            if let failedBlank { failedBlank(tab) }
            else if let current = liveState(client), current.physical_group == mount.group,
               bridge.identity(current) == key.profile,
               (current.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == privateSession,
               bridge.tab_copy_title(client, tab, nil, 0) > 0 {
                _ = bridge.tab_close(client, tab)
            }
            return .failure(error)
        }
    }

    private func record(_ page: ChromiumPageNavigation, in windowID: UUID, owned: Bool = true,
                        invalidatesUnclaimed: Bool = true) {
        let id = ObjectIdentifier(page)
        pages[id] = Binding(window: windowID, page: page, owned: owned,
                            invalidatesUnclaimed: invalidatesUnclaimed)
        if owned { page.setNativePeekCapability(true, onShiftClick: peekOnShiftClick) }
        page.onNativeCloseOutcome = { [weak self, weak page] outcome in
            guard let self, let page else { return }
            let cleanup = self.pages[id]?.cleanupBatch
            let provisionalOwner = self.pages[id].flatMap {
                !$0.owned && !$0.invalidatesUnclaimed ? $0.priorCloseOutcome : nil
            }
            if outcome != .cancelled {
                self.pages.removeValue(forKey: id)
                if self.blankTabs[page.nativeWindowID]?.tab == page.nativeTabID {
                    self.blankTabs.removeValue(forKey: page.nativeWindowID)
                }
            }
            let callbacks = self.closing.removeValue(forKey: id) ?? []
            callbacks.forEach { $0(outcome) }
            provisionalOwner?(outcome)
            if outcome != .cancelled, let cleanup { self.cleanupEnded(cleanup, page: page) }
            if outcome == .cancelled, let binding = self.pages[id] { self.discardUnclaimed(binding) }
        }
    }

    /// Bind a page that Chromium already created. Only clients already mounted
    /// for this model window/profile qualify; global discovery is separate.
    func bindExistingPage(nativeWindow: Int32, tab: Int32, profile: Profile,
                          in window: BrowserWindowState,
                          existingPage: ChromiumPageNavigation? = nil) -> Result<ChromiumExistingPageBinding, Error> {
        guard supports(profile, in: window) else {
            return .failure(HostError.unsupportedProfile)
        }
        guard let mount = mounts[window.id], mount.model === window, mount.shell != nil,
              let row = liveState(nativeWindow), row.physical_group == mount.group,
              bridge.identity(row) == profile.id,
              (row.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == profile.isEphemeral,
              tab > 0, bridge.tab_copy_title(nativeWindow, tab, nil, 0) > 0 else {
            return .failure(HostError.existingPageRefused)
        }
        if let binding = pages.values.first(where: { $0.page.nativeTabID == tab }) {
            guard binding.page.nativeWindowID == nativeWindow, !binding.page.isClosed,
                  binding.page.isPrivateSession == profile.isEphemeral,
                  binding.page.profileID == profile.id, closing[ObjectIdentifier(binding.page)] == nil else {
                return .failure(HostError.existingPageRefused)
            }
            let previous = binding.window
            binding.window = window.id
            guard canAdoptPage(binding.page, in: window) else {
                binding.window = previous
                return .failure(HostError.existingPageRefused)
            }
            return .success(beginAdmission(binding, previousWindow: previous == window.id ? nil : previous))
        }
        // That blank belongs to an app factory completion that has not claimed
        // it yet. Never steal its observer or make a second model page for it.
        guard blankTabs[nativeWindow]?.tab != tab else { return .failure(HostError.existingPageRefused) }
        do {
            if let existingPage {
                guard existingPage.nativeWindowID == nativeWindow, existingPage.nativeTabID == tab,
                      !existingPage.isClosed, existingPage.profileID == profile.id,
                      existingPage.isPrivateSession == profile.isEphemeral else {
                    return .failure(HostError.existingPageRefused)
                }
            }
            let page = try existingPage ?? ChromiumPageNavigation(profileID: profile.id, window: nativeWindow, tab: tab, bridge: bridge, privateSession: profile.isEphemeral)
            guard !page.isClosed, let current = liveState(page.nativeWindowID),
                  current.physical_group == mount.group,
                  bridge.identity(current) == profile.id,
                  bridge.tab_copy_title(page.nativeWindowID, tab, nil, 0) > 0 else {
                if existingPage == nil { page.invalidate() }
                return .failure(HostError.existingPageRefused)
            }
            record(page, in: window.id, owned: false, invalidatesUnclaimed: existingPage == nil)
            let binding = pages[ObjectIdentifier(page)]!
            guard canAdoptPage(page, in: window) else {
                discardUnclaimed(binding)
                return .failure(HostError.existingPageRefused)
            }
            return .success(beginAdmission(binding))
        } catch {
            // Observation failure is not ownership of the native resource.
            return .failure(error)
        }
    }

    /// Import the same detached adapter while native transfer still retains its
    /// source. A refused publication is rolled back natively before empty-strip
    /// notification; no second observer or post-return reverse transfer exists.
    func promoteDetachedPage(_ page: ChromiumPageNavigation, profile: Profile,
                             to destination: Int32, in window: BrowserWindowState,
                             peekSource: ChromiumPageNavigation? = nil,
                             commit: @escaping @MainActor () -> Bool) -> Bool {
        let source = page.nativeWindowID
        let existingBinding = pages[ObjectIdentifier(page)]
        if let peekSource {
            guard let existingBinding, existingBinding.page === page, existingBinding.owned,
                  existingBinding.window == window.id, closing[ObjectIdentifier(page)] == nil,
                  peekSource.nativeWindowID == destination, admission(peekSource, in: window) != nil,
                  bridge.readSnapshot()?.tabs.contains(where: {
                      $0.window == source && $0.tab == page.nativeTabID && $0.peek_source_tab == peekSource.nativeTabID
                  }) == true else { return false }
        } else if existingBinding != nil { return false }
        guard source != destination, supports(profile, in: window),
              page.profileID == profile.id, page.isPrivateSession == profile.isEphemeral,
              !page.isClosed,
              let mount = mounts[window.id], mount.model === window,
              let target = liveState(destination), target.physical_group == mount.group,
              bridge.identity(target) == profile.id,
              (target.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == profile.isEphemeral,
              bridge.tab_copy_title(source, page.nativeTabID, nil, 0) > 0,
              let origin = liveState(source), bridge.identity(origin) == profile.id,
              (origin.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == profile.isEphemeral else { return false }
        let previousOutcome = page.onNativeCloseOutcome
        let request = DetachedAdmission { [weak self, weak page, weak window] actual, tab in
            guard let self, let page, let window, actual == destination,
                  tab == page.nativeTabID, page.nativeWindowID == destination,
                  !page.isClosed, self.pages[ObjectIdentifier(page)] === existingBinding,
                  self.mounts[window.id] === mount, mount.model === window,
                  let current = self.liveState(actual), current.physical_group == mount.group,
                  self.bridge.identity(current) == profile.id,
                  self.bridge.tab_copy_title(actual, tab, nil, 0) > 0 else { return false }
            if existingBinding == nil {
                self.record(page, in: window.id, owned: false, invalidatesUnclaimed: false)
            }
            let binding = self.pages[ObjectIdentifier(page)]!
            // Keep a provisional nested failure from invalidating the adapter
            // still owned by the detached presenter.
            binding.attempts += 1
            let admitted = commit()
            binding.attempts -= 1
            if admitted { binding.owned = true; binding.page.setNativePeekCapability(true, onShiftClick: peekOnShiftClick) }
            return existingBinding == nil ? binding.owned : admitted
        }
        let result = withExtendedLifetime(request) {
            bridge.tab_transfer_with_admission(source, page.nativeTabID, destination, { context, window, tab in
                MainActor.assumeIsolated {
                    guard let context else { return 0 }
                    let request = Unmanaged<DetachedAdmission>.fromOpaque(context).takeUnretainedValue()
                    return request.commit(window, tab) ? 1 : 0
                }
            }, Unmanaged.passUnretained(request).toOpaque())
        }
        let id = ObjectIdentifier(page)
        if let binding = pages[id], !binding.owned, binding.attempts == 0 {
            pages.removeValue(forKey: id)
            if !page.isClosed { page.onNativeCloseOutcome = previousOutcome }
        }
        return result == 1
    }

    @MainActor private final class DetachedAdmission {
        let commit: (Int32, Int32) -> Bool
        init(_ commit: @escaping (Int32, Int32) -> Bool) { self.commit = commit }
    }

    /// Admit a moved Peek without moving or selecting it again. The native
    /// no-move admission branch clears its role only after model publication.
    func admitMovedPeek(_ page: ChromiumPageNavigation, commit: @escaping @MainActor () -> Bool) -> Bool {
        let window = page.nativeWindowID, tab = page.nativeTabID
        guard !page.isClosed, pages[ObjectIdentifier(page)]?.page === page else { return false }
        let request = DetachedAdmission { [weak page] actual, actualTab in
            guard let page, !page.isClosed, actual == window, actualTab == tab,
                  page.nativeWindowID == window, page.nativeTabID == tab else { return false }
            return commit()
        }
        return withExtendedLifetime(request) {
            bridge.tab_transfer_with_admission(window, tab, window, { context, owner, tab in
                MainActor.assumeIsolated {
                    guard let context else { return 0 }
                    let request = Unmanaged<DetachedAdmission>.fromOpaque(context).takeUnretainedValue()
                    return request.commit(owner, tab) ? 1 : 0
                }
            }, Unmanaged.passUnretained(request).toOpaque()) == 1
        }
    }

    private func beginAdmission(_ binding: Binding, previousWindow: UUID? = nil) -> ChromiumExistingPageBinding {
        binding.attempts += 1
        binding.admissionGeneration &+= 1
        let generation = binding.admissionGeneration
        let nativeOwner = binding.page.nativeWindowID
        let modelOwner = binding.window
        return ChromiumExistingPageBinding(navigation: binding.page) { [weak self, weak binding] adopted in
            guard let self, let binding, self.pages[ObjectIdentifier(binding.page)] === binding else { return }
            binding.attempts -= 1
            if adopted {
                binding.owned = true; binding.page.setNativePeekCapability(true, onShiftClick: peekOnShiftClick)
                if let cleanup = binding.cleanupBatch {
                    binding.cleanupBatch = nil
                    self.cleanupEnded(cleanup, page: binding.page)
                }
            } else if let previousWindow, binding.admissionGeneration == generation,
                    !binding.page.isClosed, self.closing[ObjectIdentifier(binding.page)] == nil,
                    binding.page.nativeWindowID == nativeOwner,
                    let destination = self.mounts[modelOwner],
                    let row = self.liveState(nativeOwner), row.physical_group == destination.group,
                    let previousMount = self.mounts[previousWindow], previousMount.model != nil,
                    let previousClient = previousMount.attachedClient,
                    self.liveState(previousClient)?.physical_group == previousMount.group {
                binding.window = previousWindow
            }
            self.discardUnclaimed(binding)
        }
    }

    private func discardUnclaimed(_ binding: Binding) {
        let id = ObjectIdentifier(binding.page)
        guard pages[id] === binding, !binding.owned, binding.attempts == 0,
              closing[id] == nil else { return }
        pages.removeValue(forKey: id)
        if binding.invalidatesUnclaimed { binding.page.invalidate() }
        else { binding.page.onNativeCloseOutcome = binding.priorCloseOutcome }
    }

    /// Cheap reconciliation identity check only. It grants no native admission;
    /// actual moves and rejected attempts still validate current C membership.
    func isBoundPage(_ page: ChromiumPageNavigation, in window: BrowserWindowState) -> Bool {
        guard !page.isClosed, let binding = pages[ObjectIdentifier(page)], binding.page === page,
              binding.window == window.id, closing[ObjectIdentifier(page)] == nil,
              let mount = mounts[window.id], mount.model === window, mount.shell != nil else { return false }
        return true
    }

    /// Background admission uses the current native owner, never a client cache.
    func canAdoptPage(_ navigation: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard let page = navigation as? ChromiumPageNavigation, page.isPrivateSession == window.isIncognito else { return false }
        return admission(page, in: window) != nil
    }

    private func admission(_ page: ChromiumPageNavigation, in window: BrowserWindowState) -> (Mount, BarcDiscoveryWindow)? {
        guard !page.isClosed, let profile = page.profileID,
              let binding = pages[ObjectIdentifier(page)], binding.page === page,
              binding.window == window.id, closing[ObjectIdentifier(page)] == nil,
              let mount = mounts[window.id], mount.model === window, mount.shell != nil,
              let row = liveState(page.nativeWindowID), row.physical_group == mount.group,
              bridge.identity(row) == profile,
              (row.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == window.isIncognito,
              (!window.isIncognito || window.ephemeralProfile?.id == profile),
              bridge.tab_copy_title(page.nativeWindowID, page.nativeTabID, nil, 0) > 0 else { return nil }
        return (mount, row)
    }

    private func selected(_ page: ChromiumPageNavigation, in window: BrowserWindowState) -> Bool {
        guard let (_, row) = admission(page, in: window) else { return false }
        return row.selected_client == page.nativeWindowID && row.presentedTab == page.nativeTabID
    }

    func isNativeSelection(_ navigation: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard let page = navigation as? ChromiumPageNavigation,
              let (mount, row) = admission(page, in: window), mount.shell != nil,
              row.selected_client == page.nativeWindowID, row.presentedTab == page.nativeTabID else { return false }
        return mount.presenter.ownsSidebar(page.nativeWindowID)
    }

    func acceptNativeSelection(_ navigation: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard let page = navigation as? ChromiumPageNavigation,
              let (mount, row) = admission(page, in: window),
              row.selected_client == page.nativeWindowID, row.presentedTab == page.nativeTabID else { return false }
        mount.generation &+= 1
        return attachSelected(page, in: window, mount: mount, attempt: mount.generation)
    }

    private func attachSelected(_ page: ChromiumPageNavigation, in window: BrowserWindowState,
                                mount: Mount, attempt: UInt64) -> Bool {
        guard mount.shell != nil else { return false }
        let presenter = mount.presenter
        func current() -> Bool {
            mounts[window.id] === mount && mount.generation == attempt && selected(page, in: window)
        }
        guard current() else { return false }
        reconcilePeekSidebar(mount)
        let target = page.nativeWindowID
        if presenter.ownsSidebar(target) {
            mount.attachedClient = target
            return current() && presenter.showPage(page.nativeTabID, of: target)
        }
        if let old = mount.attachedClient, old != target, presenter.ownsSidebar(old) {
            let detached = presenter.detachSidebar(from: old)
            guard current(), detached else { return false }
        }
        let attached = presenter.attachSidebar(to: target)
        let owns = presenter.ownsSidebar(target)
        // Native attachment may succeed physically but report supersession.
        // Remember that actual owner so the next reflection can detach it.
        if owns {
            if mount.generation == attempt {
                mount.attachedClient = target
            } else if mount.attachedClient != target {
                // A nested Swift mount already won. Release only this older
                // call's exact view, never its newer destination's header.
                _ = presenter.detachSidebar(from: target)
            }
        }
        return current() && attached && owns && presenter.showPage(page.nativeTabID, of: target)
    }

    /// Header view ownership only; the existing sidebar is the physical-group
    /// authority. Native attachment carries this exact pair through Peek/moves.
    func setPageHeader(_ header: NSView?, replacing expected: NSView?, height: Int32,
                       in window: BrowserWindowState) -> Bool {
        guard let mount = mounts[window.id], mount.model === window, mount.shell != nil else { return false }
        reconcilePeekSidebar(mount)
        guard let owner = mount.attachedClient else { return false }
        return mount.presenter.setHeader(header, replacing: expected, height: height, owner: owner)
    }

    private func reconcilePeekSidebar(_ mount: Mount) {
        guard let owners = mount.peekSidebarOwners, mount.shell != nil else { return }
        if mount.presenter.ownsSidebar(owners.source) { mount.attachedClient = owners.source }
        else if mount.presenter.ownsSidebar(owners.peek) { mount.attachedClient = owners.peek }
        else { mount.peekSidebarOwners = nil }
    }

    func presentPeek(source: ChromiumPageNavigation, page: ChromiumPageNavigation,
                     header: NSView, actions: NSView, in window: BrowserWindowState) -> UInt64 {
        guard source !== page, source.profileID == page.profileID,
              let (mount, _) = admission(source, in: window),
              let (peekMount, _) = admission(page, in: window), mount === peekMount,
              let shell = mount.shell else { return 0 }
        mount.generation &+= 1
        let attempt = mount.generation
        let owners = (source: source.nativeWindowID, peek: page.nativeWindowID)
        let generation = bridge.tab_present_peek(owners.source, source.nativeTabID, owners.peek, page.nativeTabID,
            Unmanaged.passUnretained(shell).toOpaque(), Unmanaged.passUnretained(header).toOpaque(),
            Unmanaged.passUnretained(actions).toOpaque())
        guard mount.generation == attempt else { return 0 }
        mount.peekSidebarOwners = owners
        reconcilePeekSidebar(mount)
        return generation
    }

    func isPeekPresented(sourceWindow: Int32, sourceTab: Int32, peekWindow: Int32, peekTab: Int32,
                         generation: UInt64, header: NSView, actions: NSView) -> Bool {
        guard generation != 0 else { return false }
        return bridge.tab_is_peek_presented(sourceWindow, sourceTab, peekWindow, peekTab, generation,
            Unmanaged.passUnretained(header).toOpaque(), Unmanaged.passUnretained(actions).toOpaque()) == 1
    }

    func hidePeek(sourceWindow: Int32, sourceTab: Int32, peekWindow: Int32, peekTab: Int32,
                  generation: UInt64, header: NSView, actions: NSView, in window: BrowserWindowState) {
        guard generation != 0 else { return }
        _ = bridge.tab_hide_peek(sourceWindow, sourceTab, peekWindow, peekTab, generation,
            Unmanaged.passUnretained(header).toOpaque(), Unmanaged.passUnretained(actions).toOpaque())
        if let mount = mounts[window.id], mount.model === window { reconcilePeekSidebar(mount) }
    }

    func selectPage(_ navigation: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard let page = navigation as? ChromiumPageNavigation,
              admission(page, in: window) != nil || moveHere(page, in: window),
              let (mount, before) = admission(page, in: window) else { return false }
        let previous = bridge.windowState(before.selected_client)
        mount.generation &+= 1
        let attempt = mount.generation
        guard page.selectNativePage(), mount.generation == attempt,
              selected(page, in: window) else { return false }
        if attachSelected(page, in: window, mount: mount, attempt: attempt) { return true }
        // Roll back only our still-current native selection. A callback may
        // have selected a third client without entering this Swift host.
        guard mount.generation == attempt, selected(page, in: window),
              let previous, let old = liveState(previous.window),
              old.physical_group == mount.group, old.active_tab == previous.active_tab,
              mount.shell != nil else { return false }
        let presenter = mount.presenter
        let target = page.nativeWindowID
        if target != old.window, presenter.ownsSidebar(target) {
            let detached = presenter.detachSidebar(from: target)
            guard detached, mount.generation == attempt, selected(page, in: window) else { return false }
        }
        guard bridge.window_select(old.window) == 1, mount.generation == attempt,
              let restored = liveState(old.window), restored.physical_group == mount.group,
              restored.selected_client == old.window, restored.active_tab == previous.active_tab else { return false }
        _ = presenter.attachSidebar(to: old.window)
        if presenter.ownsSidebar(old.window) {
            if mount.generation == attempt { mount.attachedClient = old.window }
            else if mount.attachedClient != old.window { _ = presenter.detachSidebar(from: old.window) }
        }
        return false
    }

    func switchSpace(to profile: Profile, page navigation: (any PageNavigation)?,
                     in window: BrowserWindowState, isCurrent: @escaping @MainActor () -> Bool,
                     completion: @escaping @MainActor (NativeSpaceSwitchOutcome) -> Void) {
        guard let mount = mounts[window.id], mount.model === window, mount.shell != nil else {
            completion(.closed); return
        }
        guard supports(profile, in: window), isCurrent() else { completion(.refused(retained: nil)); return }

        let submit = { [weak self, weak window] (client: Int32?, tab: Int32) in
            guard let self, let window, isCurrent() else { return }
            guard self.mounts[window.id] === mount, mount.shell != nil else { completion(.closed); return }
            let attached = mount.attachedClient.flatMap { client in
                self.liveState(client)?.physical_group == mount.group ? client : nil
            }
            guard let owner = attached ?? self.liveClient(in: window.id) else { completion(.unresolved); return }
            guard let client, let target = self.liveState(client),
                  target.physical_group == mount.group, self.bridge.identity(target) == profile.id else {
                completion(.refused(retained: nil)); return
            }
            mount.spaceSwitchSequence &+= 1
            let sequence = mount.spaceSwitchSequence
            let delivery = SpaceSwitchDelivery { [weak self, weak window] result in
                guard let self, let window, isCurrent(), mount.spaceSwitchSequence == sequence else { return }
                guard let result, result.request == sequence else { completion(.unresolved); return }
                let status = UInt32(bitPattern: result.status)
                if status == BARC_SPACE_SWITCH_CLOSED.rawValue, result.group == 0 || result.group == mount.group {
                    completion(.closed); return
                }
                guard result.group == mount.group,
                      self.mounts[window.id] === mount, mount.shell != nil,
                      let row = self.liveState(result.client), row.physical_group == mount.group,
                      row.selected_client == result.client, row.presentedTab == result.tab else {
                    completion(.unresolved); return
                }
                let applied = status == BARC_SPACE_SWITCH_APPLIED.rawValue
                let refused = status == BARC_SPACE_SWITCH_REFUSED.rawValue
                guard applied ? (result.client == client && tab == result.tab)
                              : (refused || status == BARC_SPACE_SWITCH_SUPERSEDED.rawValue) else {
                    completion(.unresolved); return
                }

                let selection: NativeSpaceSwitchSelection
                if result.tab == 0 {
                    guard let identity = self.bridge.identity(row),
                          self.attachEmptySpaceSidebar(result.client, mount: mount), isCurrent() else {
                        completion(.unresolved); return
                    }
                    mount.hasSettledEmptySelection = true
                    mount.presenter.setPageHidden(true, client: result.client)
                    selection = .empty(profileID: identity)
                } else {
                    guard let selected = self.pages.values.first(where: {
                        $0.window == window.id && $0.owned && $0.page.nativeWindowID == result.client &&
                            $0.page.nativeTabID == result.tab && !$0.page.isClosed
                    })?.page else { completion(.unresolved); return }
                    guard self.acceptNativeSelection(selected, in: window), isCurrent() else {
                        completion(.unresolved); return
                    }
                    mount.presenter.setPageHidden(false, client: result.client)
                    guard self.isNativeSelection(selected, in: window) else { completion(.unresolved); return }
                    mount.hasSettledEmptySelection = false
                    selection = .page(selected)
                }
                guard isCurrent() else { return }
                if refused { completion(.refused(retained: selection)) }
                else if !applied { completion(.superseded(selection)) }
                else {
                    switch selection {
                    case .page(let page): completion(.applied(page))
                    case .empty: completion(.applied(nil))
                    }
                }
            }
            var request = BarcSpaceSwitchRequest(size: UInt32(MemoryLayout<BarcSpaceSwitchRequest>.size),
                                                request: sequence, window: owner, client: client, tab: tab)
            let context = Unmanaged.passRetained(delivery).toOpaque()
            let accepted = self.bridge.window_switch_space(&request, { result, context in
                MainActor.assumeIsolated {
                    guard let context else { return }
                    let delivery = Unmanaged<SpaceSwitchDelivery>.fromOpaque(context).takeRetainedValue()
                    let copied = result.flatMap { pointer -> SettledSpaceSwitch? in
                        guard pointer.pointee.size >= MemoryLayout<BarcSpaceSwitchResult>.size else { return nil }
                        return SettledSpaceSwitch(pointer.pointee)
                    }
                    delivery.finish(copied)
                }
            }, context)
            if accepted != 1 {
                Unmanaged<SpaceSwitchDelivery>.fromOpaque(context).release()
                completion(.refused(retained: nil))
            }
        }
        if let navigation {
            guard let page = navigation as? ChromiumPageNavigation, page.profileID == profile.id,
                  admission(page, in: window) != nil || moveHere(page, in: window, isCurrent: isCurrent),
                  admission(page, in: window) != nil else { completion(.refused(retained: nil)); return }
            submit(page.nativeWindowID, page.nativeTabID)
        } else if let client = liveClient(in: window.id, profile: profile.id) {
            submit(client, 0)
        } else {
            prepareEmptySpaceClient(in: window, profile: profile.id) { submit($0, 0) }
        }
    }

    /// A page another window holds moves into this one, into its client of the page's profile.
    private func moveHere(_ page: ChromiumPageNavigation, in window: BrowserWindowState,
                          isCurrent: @escaping @MainActor () -> Bool = { true }) -> Bool {
        let id = ObjectIdentifier(page)
        guard !page.isClosed, !page.isPrivateSession, !window.isIncognito, let profile = page.profileID,
              let binding = pages[id], binding.page === page, binding.owned, binding.window != window.id,
              closing[id] == nil, let mount = mounts[window.id], mount.model === window, mount.shell != nil,
              let source = liveState(page.nativeWindowID), source.physical_group != mount.group,
              bridge.identity(source) == profile, let owner = liveClient(in: window.id) else { return false }
        var destination = liveClient(in: window.id, profile: profile) ?? 0
        let created = destination == 0
        if created { destination = bridge.window_new_peer_in_native_window(page.nativeWindowID, owner) }
        guard isCurrent(), destination > 0, let target = liveState(destination), target.physical_group == mount.group,
              bridge.identity(target) == profile else {
            if created && destination > 0 { _ = bridge.window_close(destination) }
            return false
        }
        let previous = binding.window
        let request = DetachedAdmission { [weak self, weak page, weak window] actual, tab in
            guard isCurrent(), let self, let page, let window, actual == destination, tab == page.nativeTabID,
                  page.nativeWindowID == destination, self.pages[id] === binding,
                  self.mounts[window.id] === mount else { return false }
            binding.window = window.id
            return true
        }
        let moved = withExtendedLifetime(request) {
            bridge.tab_transfer_with_admission(page.nativeWindowID, page.nativeTabID, destination, { context, owner, tab in
                MainActor.assumeIsolated {
                    guard let context else { return 0 }
                    return Unmanaged<DetachedAdmission>.fromOpaque(context).takeUnretainedValue().commit(owner, tab) ? 1 : 0
                }
            }, Unmanaged.passUnretained(request).toOpaque())
        } == 1
        guard moved else {
            if pages[id] === binding, page.nativeWindowID != destination { binding.window = previous }
            if created { _ = bridge.window_close(destination) }
            return false
        }
        return true
    }

    private func splitPages(_ record: SplitRecord, pages: [UUID: PageSession],
                            in window: BrowserWindowState) -> [ChromiumPageNavigation]? {
        let result = record.itemIDs.compactMap { pages[$0]?.navigation as? ChromiumPageNavigation }
        guard result.count == record.itemIDs.count, let first = result.first,
              (2...4).contains(result.count), Set(result.map(\.nativeTabID)).count == result.count,
              result.allSatisfy({ page in
                  admission(page, in: window) != nil &&
                  (!window.isIncognito || (page.profileID == first.profileID &&
                      page.nativeWindowID == first.nativeWindowID))
              }) else { return nil }
        return result
    }

    private func layout(_ record: SplitRecord, pages: [ChromiumPageNavigation], active: UUID?) -> BarcSplitLayout? {
        guard let active, let index = record.itemIDs.firstIndex(of: active),
              record.dividers.count + 1 == pages.count,
              record.dividers.allSatisfy(\.isFinite),
              zip([0] + record.dividers, record.dividers + [1]).allSatisfy({ $0 < $1 }) else { return nil }
        let handles = pages.map(\.nativeTabID), cuts = record.dividers
        let orientation = record.orientation == .horizontal ? BARC_SPLIT_SIDE_BY_SIDE : BARC_SPLIT_STACKED
        return BarcSplitLayout(size: MemoryLayout<BarcSplitLayout>.size, count: UInt32(pages.count), orientation: orientation.rawValue,
            tabs: (handles[0], handles[1], handles.count > 2 ? handles[2] : 0, handles.count > 3 ? handles[3] : 0),
            dividers: (cuts[0], cuts.count > 1 ? cuts[1] : 0, cuts.count > 2 ? cuts[2] : 0),
            active_tab: handles[index], collection: 0, kind: BARC_SPLIT_PHYSICAL.rawValue, generation: 0)
    }

    private func validSplitIdentity(_ value: BarcSplitLayout) -> Bool {
        value.kind == BARC_SPLIT_PHYSICAL.rawValue && value.collection == 0 && value.generation > 0
    }

    private func sameLayout(_ actual: BarcSplitLayout, _ requested: BarcSplitLayout,
                            active: Bool = true) -> Bool {
        guard actual.kind == requested.kind, actual.count == requested.count, (2...4).contains(actual.count),
              actual.orientation == requested.orientation,
              !active || actual.active_tab == requested.active_tab else { return false }
        let count = Int(actual.count)
        return Array([actual.tabs.0, actual.tabs.1, actual.tabs.2, actual.tabs.3].prefix(count)) ==
               Array([requested.tabs.0, requested.tabs.1, requested.tabs.2, requested.tabs.3].prefix(count)) &&
               Array([actual.dividers.0, actual.dividers.1, actual.dividers.2].prefix(count - 1)) ==
               Array([requested.dividers.0, requested.dividers.1, requested.dividers.2].prefix(count - 1))
    }

    func isSplit(_ record: SplitRecord?, pages: [UUID: PageSession], activeItemID: UUID?,
                 in window: BrowserWindowState) -> Bool {
        if laysOutSplits(in: window) {
            return hostShowsSplit(record, navigations: navigations(pages), activeItemID: activeItemID, in: window)
        }
        guard let record else {
            guard let activeItemID, let page = pages[activeItemID]?.navigation as? ChromiumPageNavigation else { return true }
            guard isNativeSelection(page, in: window) else { return false }
            var actual = BarcSplitLayout.sized
            return bridge.window_get_split(page.nativeWindowID, page.nativeTabID, &actual) == 0
        }
        guard let native = splitPages(record, pages: pages, in: window),
              let request = layout(record, pages: native, active: activeItemID),
              let index = activeItemID.flatMap({ record.itemIDs.firstIndex(of: $0) }),
              isNativeSelection(native[index], in: window) else { return false }
        var actual = BarcSplitLayout.sized
        return bridge.window_get_split(native[index].nativeWindowID, 0, &actual) == 1 && validSplitIdentity(actual) && sameLayout(actual, request)
    }

    func applySplit(_ record: SplitRecord?, replacing previous: SplitRecord?,
                    pages: [UUID: PageSession], activeItemID: UUID?,
                    in window: BrowserWindowState, isCurrent: () -> Bool) -> Bool {
        if laysOutSplits(in: window) {
            return applyHostSplit(record, navigations: navigations(pages), activeItemID: activeItemID, in: window, isCurrent: isCurrent)
        }
        guard isCurrent(), let mount = mounts[window.id], mount.model === window else { return false }
        var generation = mount.generation
        let selectedBefore = pages.values.compactMap { $0.navigation as? ChromiumPageNavigation }
            .first { self.isNativeSelection($0, in: window) }
        var old: (window: Int32, member: Int32, layout: BarcSplitLayout)?
        var unknownLiveOldGroup = false
        if let previous, let native = splitPages(previous, pages: pages, in: window),
           let sample = layout(previous, pages: native, active: previous.itemIDs.first) {
            var existing = BarcSplitLayout.sized
            if bridge.window_get_split(native[0].nativeWindowID, native[0].nativeTabID, &existing) == 1 {
                if sameLayout(existing, sample, active: false) {
                    old = (native[0].nativeWindowID, native[0].nativeTabID, existing)
                } else {
                    unknownLiveOldGroup = true
                }
            }
        } else if let previous {
            // A partly released model must not authorize cleanup of an unknown
            // native collection. Completely cold saved panes have nothing to clear.
            for id in previous.itemIDs {
                guard let page = pages[id]?.navigation as? ChromiumPageNavigation,
                      admission(page, in: window) != nil else { continue }
                var actual = BarcSplitLayout.sized
                if bridge.window_get_split(page.nativeWindowID, page.nativeTabID, &actual) == 1 {
                    unknownLiveOldGroup = true
                }
            }
        }
        // Reuse normal exact-owner/header admission for an explicitly chosen
        // active pane. Preparing hidden panes never selects their profiles.
        let requestedActive = activeItemID.flatMap { pages[$0]?.navigation as? ChromiumPageNavigation }
        let presentationBeforeSelection = old
        func restorePreviousSelection() {
            guard isCurrent(), mounts[window.id] === mount, mount.generation == generation,
                  let selectedBefore, let requestedActive,
                  isNativeSelection(requestedActive, in: window) || isNativeSelection(selectedBefore, in: window) else { return }
            if !isNativeSelection(selectedBefore, in: window) {
                guard selectPage(selectedBefore, in: window), isCurrent() else { return }
                generation = mount.generation
            }
            if var previous = presentationBeforeSelection, previous.layout.active_tab == selectedBefore.nativeTabID,
               isCurrent(), mount.generation == generation,
               bridge.window_set_split(selectedBefore.nativeWindowID, &previous.layout) == 1,
               mounts[window.id] === mount, mount.generation == generation,
               isCurrent(), isNativeSelection(selectedBefore, in: window) {
                var restored = BarcSplitLayout.sized
                if bridge.window_get_split(selectedBefore.nativeWindowID, 0, &restored) == 1,
                   sameLayout(restored, previous.layout), validSplitIdentity(restored) {
                    mount.presentedSplit = (selectedBefore.nativeWindowID, restored.tabs.0,
                        restored.collection, restored.kind, restored.generation, restored.count)
                }
            }
        }
        if let requestedActive, !isNativeSelection(requestedActive, in: window) {
            let selectionAttempt = mount.generation &+ 1
            guard selectPage(requestedActive, in: window) else {
                // selectPage already guards its selection/header rollback. If it
                // restored the old page, restore only that page's old layout.
                if isCurrent(), mount.generation == selectionAttempt,
                   let selectedBefore, isNativeSelection(selectedBefore, in: window) {
                    generation = selectionAttempt
                    restorePreviousSelection()
                }
                return false
            }
            generation = mount.generation
            guard isCurrent(), mounts[window.id] === mount else {
                restorePreviousSelection()
                return false
            }
            if var captured = old {
                var current = BarcSplitLayout.sized
                if bridge.window_get_split(captured.window, captured.member, &current) == 1,
                   current.kind == captured.layout.kind,
                   current.generation == captured.layout.generation,
                   current.collection == captured.layout.collection,
                   sameLayout(current, captured.layout, active: false) {
                    captured.layout = current
                    old = captured
                }
            }
        }
        if let record {
            guard let native = splitPages(record, pages: pages, in: window),
                  var request = layout(record, pages: native, active: activeItemID),
                  let index = activeItemID.flatMap({ record.itemIDs.firstIndex(of: $0) }),
                  let (currentMount, row) = admission(native[index], in: window),
                  currentMount === mount, mounts[window.id] === mount,
                  row.selected_client == native[index].nativeWindowID,
                  mount.shell != nil,
                  mount.presenter.ownsSidebar(native[index].nativeWindowID),
                  isCurrent() else {
                restorePreviousSelection()
                return false
            }
            guard mount.generation == generation, bridge.window_set_split(native[index].nativeWindowID, &request) == 1,
                  mounts[window.id] === mount, mount.generation == generation,
                  isCurrent(), isSplit(record, pages: pages, activeItemID: activeItemID, in: window) else {
                restorePreviousSelection()
                return false
            }
            if let previous, Set(previous.itemIDs).isDisjoint(with: record.itemIDs), var old {
                // Exact identity rejects a replaced/reconfigured old collection.
                // Its refusal never rolls back the successfully admitted new split.
                if old.window == native[index].nativeWindowID {
                    // Set chose a disjoint pane in this same client. Only this
                    // expected own selection change is ours to reconcile.
                    old.layout.active_tab = 0
                }
                _ = bridge.window_clear_split(old.window, old.member, &old.layout)
            }
            guard mounts[window.id] === mount, mount.generation == generation,
                  isCurrent(), isSplit(record, pages: pages, activeItemID: activeItemID, in: window) else {
                restorePreviousSelection()
                return false
            }
            var admitted = BarcSplitLayout.sized
            guard bridge.window_get_split(native[index].nativeWindowID, 0, &admitted) == 1,
                  sameLayout(admitted, request), validSplitIdentity(admitted) else {
                restorePreviousSelection()
                return false
            }
            mount.presentedSplit = (native[index].nativeWindowID, native[0].nativeTabID, admitted.collection, admitted.kind, admitted.generation, admitted.count)
            return true
        }
        guard !unknownLiveOldGroup else { restorePreviousSelection(); return false }
        let active = activeItemID.flatMap { pages[$0]?.navigation as? ChromiumPageNavigation }
        if let active {
            guard let (currentMount, row) = admission(active, in: window), currentMount === mount,
                  row.selected_client == active.nativeWindowID, mount.shell != nil,
                  mount.presenter.ownsSidebar(active.nativeWindowID) else {
                restorePreviousSelection()
                return false
            }
        }
        if var old {
            guard bridge.window_clear_split(old.window, old.member, &old.layout) == 1 else {
                // Restore only a still-unchanged refused presentation. If Clear
                // returned views and a callback chose a newer native collection,
                // preserve that actual state instead of remounting the old split.
                var retained = BarcSplitLayout.sized
                if bridge.window_get_split(old.window, old.member, &retained) == 1,
                   retained.kind == old.layout.kind, retained.collection == old.layout.collection,
                   retained.generation == old.layout.generation, sameLayout(retained, old.layout) {
                    restorePreviousSelection()
                }
                return false
            }
        }
        guard mounts[window.id] === mount, mount.generation == generation, isCurrent() else {
            restorePreviousSelection()
            return false
        }
        if let active, !isNativeSelection(active, in: window) {
            // Separating the selected pane can choose its neighbour, but only
            // after exact native clear succeeded. A refused clear never focuses it.
            guard let (_, row) = admission(active, in: window), row.selected_client == active.nativeWindowID,
                  mount.shell != nil, mount.generation == generation,
                  mount.presenter.ownsSidebar(active.nativeWindowID),
                  active.selectNativePage(), mounts[window.id] === mount,
                  mount.generation == generation, isCurrent() else {
                restorePreviousSelection()
                return false
            }
        }
        guard isCurrent(), isSplit(nil, pages: pages, activeItemID: activeItemID, in: window) else {
            restorePreviousSelection()
            return false
        }
        // Retain only the last observed identity, never a layout or live claim.
        // A cleared/ending group must not look like a fresh cold-start mount.
        return true
    }

    /// Only a fresh product mount needs automatic cold restoration. Owner-ended
    /// pages must not be recreated merely because a catalog callback arrived.
    func needsInitialSplitRestore(in window: BrowserWindowState) -> Bool {
        guard let mount = mounts[window.id], mount.model === window else { return false }
        if mount.presenter.laysOutSplits { return !mount.hostSplitApplied }
        return mount.presentedSplit == nil
    }

    /// Called only from the coalesced catalog drain. nil means preserve the saved
    /// split (including ordinary unrelated-tab selection), not 'clear layout'.
    func nativeSplitUpdate(in window: BrowserWindowState, selected: BarcDiscoveryWindow,
                           sessions: [Int32: PageSession], savedPages: [PageSession])
        -> (record: SplitRecord?, validate: () -> Bool, remountLive: Bool)? {
        guard let mount = mounts[window.id], mount.model === window, !mount.presenter.laysOutSplits,
              let activeSession = sessions[selected.active_tab],
              let active = activeSession.navigation as? ChromiumPageNavigation,
              active.nativeWindowID == selected.window, isNativeSelection(active, in: window) else { return nil }
        func currentSelection() -> Bool {
            mounts[window.id] === mount &&
                liveState(selected.window)?.physical_group == mount.group &&
                isNativeSelection(active, in: window)
        }
        func read(_ client: Int32, _ member: Int32) -> BarcSplitLayout? {
            var value = BarcSplitLayout.sized
            return bridge.window_get_split(client, member, &value) == 1 ? value : nil
        }
        func decode(_ value: BarcSplitLayout) -> SplitRecord? {
            guard (2...4).contains(value.count), validSplitIdentity(value), value.orientation <= BARC_SPLIT_STACKED.rawValue else { return nil }
            let ids = Array([value.tabs.0, value.tabs.1, value.tabs.2, value.tabs.3].prefix(Int(value.count)))
            let pages = ids.compactMap { sessions[$0] }
            guard pages.count == ids.count, pages.allSatisfy({ session in
                guard let page = session.navigation as? ChromiumPageNavigation else { return false }
                return admission(page, in: window) != nil
            }) else { return nil }
            let cuts = Array([value.dividers.0, value.dividers.1, value.dividers.2].prefix(Int(value.count) - 1))
            return SplitRecord(pages.map(\.itemID), orientation: value.orientation == BARC_SPLIT_SIDE_BY_SIDE.rawValue ? .horizontal : .vertical,
                               dividers: cuts)
        }
        func snapshot(_ value: BarcSplitLayout, client: Int32, member: Int32)
            -> (record: SplitRecord?, validate: () -> Bool, remountLive: Bool)? {
            guard let record = decode(value), currentSelection() else { return nil }
            mount.presentedSplit = (client, member, value.collection, value.kind, value.generation, value.count)
            return (record, {
                guard currentSelection(), let actual = read(client, member) else { return false }
                return actual.collection == value.collection && actual.kind == value.kind &&
                    actual.generation == value.generation && self.sameLayout(actual, value)
            }, false)
        }
        let hasLiveRemainder = mount.presentedSplit.map { presented in
            presented.kind == BARC_SPLIT_PHYSICAL.rawValue && window.split.map {
                $0.contains(activeSession.itemID) && $0.itemIDs.count < Int(presented.count)
            } == true
        } ?? false
        if let value = read(selected.window, 0), !hasLiveRemainder || value.kind == BARC_SPLIT_PHYSICAL.rawValue {
            return snapshot(value, client: selected.window, member: value.tabs.0)
        }
        guard mount.presentedSplit != nil, let saved = window.split,
              saved.contains(activeSession.itemID) else { return nil }
        // A separate/close-native-group action can leave another retained group.
        // Bound reads to the four saved members; never scan/create/load pages.
        let oldPages = savedPages
        guard oldPages.map(\.itemID) == saved.itemIDs,
              oldPages.allSatisfy({ session in
                  guard let page = session.navigation as? ChromiumPageNavigation else { return false }
                  return admission(page, in: window) != nil
              }) else { return nil } // Owner ending/cold state preserves saved metadata.
        for session in oldPages {
            guard let page = session.navigation as? ChromiumPageNavigation else { continue }
            if let value = read(page.nativeWindowID, page.nativeTabID), !hasLiveRemainder || value.kind == BARC_SPLIT_PHYSICAL.rawValue {
                return snapshot(value, client: page.nativeWindowID, member: page.nativeTabID)
            }
        }
        if let presented = mount.presentedSplit, presented.kind == BARC_SPLIT_PHYSICAL.rawValue,
           saved.itemIDs.count < Int(presented.count) {
            // One live-only attempt for this ended presentation. Never turn an
            // admitted owner into a cold-start mount or recreate missing pages.
            guard mount.attemptedLiveRemainder != presented.generation else { return nil }
            mount.attemptedLiveRemainder = presented.generation
            let native = oldPages.compactMap { $0.navigation as? ChromiumPageNavigation }
            let owners = native.map(\.nativeWindowID)
            guard native.count == oldPages.count else { return nil }
            return (saved, {
                guard currentSelection(), window.split == saved else { return false }
                for index in native.indices {
                    guard oldPages[index].navigation === native[index], !native[index].isClosed,
                          native[index].nativeWindowID == owners[index],
                          self.admission(native[index], in: window) != nil else { return false }
                }
                return true
            }, true)
        }
        return (nil, {
            guard currentSelection(), read(selected.window, 0) == nil else { return false }
            for session in oldPages {
                guard let page = session.navigation as? ChromiumPageNavigation,
                      self.admission(page, in: window) != nil,
                      read(page.nativeWindowID, page.nativeTabID) == nil else { return false }
            }
            return true
        }, false)
    }

    // MARK: - Splits in a Bark window

    /// Whether `window`'s root lays out its split panes: a Bark window. The engine holds no split
    /// there; the panes are page views the root places.
    func laysOutSplits(in window: BrowserWindowState) -> Bool {
        guard let mount = mounts[window.id], mount.model === window else { return false }
        return mount.presenter.laysOutSplits
    }

    private func navigations(_ pages: [UUID: PageSession]) -> [UUID: ChromiumPageNavigation] {
        pages.compactMapValues { $0.navigation as? ChromiumPageNavigation }
    }

    /// `record` as the root shows it, `active` focused: each pane an admitted page of one of the
    /// window's clients. nil when a pane is missing or closed.
    private func hostSplit(_ record: SplitRecord, navigations: [UUID: ChromiumPageNavigation], activeItemID: UUID?,
                           mount: Mount, in window: BrowserWindowState) -> ChromiumWindowRoot.Split? {
        guard let activeItemID, record.contains(activeItemID), let focused = navigations[activeItemID] else { return nil }
        var panes: [ChromiumWindowRoot.Pane?] = []
        for id in record.itemIDs {
            guard let page = navigations[id], admission(page, in: window)?.0 === mount else { return nil }
            panes.append(.init(client: page.nativeWindowID, tab: page.nativeTabID))
        }
        return .init(panes: panes, vertical: record.orientation == .vertical, dividers: record.dividers.map { CGFloat($0) },
                     focused: focused.nativeTabID)
    }

    /// Whether `window`'s root shows `record` with `activeItemID`'s page focused and selected in
    /// Chromium; with no record, that page alone.
    func hostShowsSplit(_ record: SplitRecord?, navigations: [UUID: ChromiumPageNavigation], activeItemID: UUID?,
                        in window: BrowserWindowState) -> Bool {
        guard let mount = mounts[window.id], mount.model === window, mount.presenter.laysOutSplits else { return false }
        let active = activeItemID.flatMap { navigations[$0] }
        guard let record else {
            return mount.presenter.shownSplit == nil && (active.map { isNativeSelection($0, in: window) } ?? true)
        }
        guard let active, let split = hostSplit(record, navigations: navigations, activeItemID: activeItemID, mount: mount, in: window)
        else { return false }
        return mount.presenter.shownSplit == split && isNativeSelection(active, in: window)
    }

    /// Shows `record` in `window`'s root with `activeItemID`'s page focused and selected in
    /// Chromium; with no record, that page alone. Places views only: nothing reaches the engine's
    /// own split.
    func applyHostSplit(_ record: SplitRecord?, navigations: [UUID: ChromiumPageNavigation], activeItemID: UUID?,
                        in window: BrowserWindowState, isCurrent: () -> Bool) -> Bool {
        guard isCurrent(), let mount = mounts[window.id], mount.model === window, mount.presenter.laysOutSplits else { return false }
        let active = activeItemID.flatMap { navigations[$0] }
        if let record {
            guard active != nil,
                  let split = hostSplit(record, navigations: navigations, activeItemID: activeItemID, mount: mount, in: window),
                  mount.presenter.showSplit(split) else { return false }
        } else if mount.presenter.shownSplit != nil {
            guard mount.presenter.showSplit(nil) else { return false }
        }
        if let active, !isNativeSelection(active, in: window) {
            guard selectPage(active, in: window), isCurrent() else { return false }
        }
        mount.hostSplitApplied = true
        return isCurrent() && hostShowsSplit(record, navigations: navigations, activeItemID: activeItemID, in: window)
    }

    func splitResizeRoot(in keyWindow: NSWindow?) -> ChromiumWindowRoot? {
        guard let keyWindow else { return nil }
        return mounts.values.lazy.compactMap { ($0.presenter as? ChromiumHostPresenter)?.root }
            .first { $0.window === keyWindow && $0.canResizeSplit }
    }

    func moveSplitDivider(_ index: Int, to position: CGFloat, length: CGFloat, in window: BrowserWindowState) {
        guard laysOutSplits(in: window), var record = window.split, length > 0 else { return }
        record.moveDivider(index, to: Double(position),
                           minimum: SplitRecord.minimumPaneFraction(count: record.itemIDs.count, length: Double(length)))
        window.split = record
        _ = showSplitDividers(record, in: window)
    }

    /// A divider moved: the root re-frames the panes it shows, in the same turn.
    func showSplitDividers(_ record: SplitRecord, in window: BrowserWindowState) -> Bool {
        guard let mount = mounts[window.id], mount.model === window,
              var split = mount.presenter.shownSplit, split.panes.count == record.itemIDs.count else { return false }
        split.dividers = record.dividers.map { CGFloat($0) }
        return mount.presenter.showSplit(split)
    }

    /// What the window's model shows changed: `panes` are the split's tabs in order (nil for Add
    /// Split View's empty pane), or nil for no split. The root follows once Chromium selects the
    /// focused page and every pane's page exists; while a split is being prepared, the preparation
    /// decides.
    func showModelSplit(_ panes: [UUID?]?, vertical: Bool, dividers: [CGFloat], focused: UUID?,
                        page: (UUID) -> ChromiumPageNavigation?, in window: BrowserWindowState) {
        guard let mount = mounts[window.id], mount.model === window, mount.presenter.laysOutSplits,
              !window.nativePresentationIsPreparing else { return }
        guard let panes else {
            if mount.presenter.shownSplit != nil { _ = mount.presenter.showSplit(nil) }
            return
        }
        guard let focused = focused.flatMap(page), isNativeSelection(focused, in: window) else { return }
        var placed: [ChromiumWindowRoot.Pane?] = []
        for id in panes {
            guard let id else { placed.append(nil); continue }
            guard let navigation = page(id), admission(navigation, in: window)?.0 === mount else { return }
            placed.append(.init(client: navigation.nativeWindowID, tab: navigation.nativeTabID))
        }
        let split = ChromiumWindowRoot.Split(panes: placed, vertical: vertical, dividers: dividers, focused: focused.nativeTabID)
        if mount.presenter.shownSplit != split { _ = mount.presenter.showSplit(split) }
    }

    /// Refusal cleanup may dispose only an empty fresh host or our own header,
    /// never a replacement installed by a reentrant product admission.
    func canCloseUnadmittedWindow(_ native: Int32) -> Bool {
        guard let row = liveState(native) else { return false }
        if bridge.window_native_shell_is_owned(native, nil) == 1 { return true }
        guard let mount = mounts.values.first(where: { $0.group == row.physical_group }),
              mount.shell != nil else { return false }
        return mount.presenter.ownsSidebar(native)
    }

    /// A failed restore closes its logical window but keeps the existing page
    /// observation until actual terminal/cancelled outcome. Reuse close callbacks.
    func closeUnadmittedWindow(_ navigation: any PageNavigation,
                               completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        guard let page = navigation as? ChromiumPageNavigation else { completion(.cancelled); return }
        if page.isClosed { completion(page.nativeCloseOutcome ?? .ownerEnded); return }
        let id = ObjectIdentifier(page)
        guard pages[id]?.page === page, canCloseUnadmittedWindow(page.nativeWindowID) else { completion(.cancelled); return }
        if closing[id] != nil { closing[id]?.append(completion); return }
        closing[id] = [completion]
        let accepted = bridge.window_close(page.nativeWindowID)
        if accepted != 1, let callbacks = closing.removeValue(forKey: id) {
            callbacks.forEach { $0(.cancelled) }
        }
    }

    func closePage(_ navigation: any PageNavigation, completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        closePage(navigation, successor: nil, completion: completion)
    }

    func closePage(_ navigation: any PageNavigation, showing successor: any PageNavigation,
                   completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        closePage(navigation, successor: successor as? ChromiumPageNavigation, completion: completion)
    }

    private func closePage(_ navigation: any PageNavigation, successor: ChromiumPageNavigation?,
                           completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        guard let page = navigation as? ChromiumPageNavigation else { completion(.cancelled); return }
        if page.isClosed { completion(page.nativeCloseOutcome ?? .closed); return }
        let id = ObjectIdentifier(page)
        guard pages[id]?.page === page else { completion(.cancelled); return }
        if closing[id] != nil { closing[id]?.append(completion); return }
        closing[id] = [completion]
        let accepted = page.requestNativeClose(showing: successor)
        // Terminal/cancellation delivery may have completed synchronously.
        if !accepted, let callbacks = closing.removeValue(forKey: id) {
            callbacks.forEach { $0(.cancelled) }
        }
    }

    private func supports(_ profile: Profile, in window: BrowserWindowState) -> Bool {
        guard profile.engine == .chromium else { return false }
        return profile.isEphemeral
            ? window.isIncognito && window.ephemeralProfile === profile && window.privateTree != nil
            : !window.isIncognito && window.privateTree == nil
    }

    private func liveState(_ native: Int32) -> BarcDiscoveryWindow? {
        guard native > 0, let row = bridge.windowState(native), row.window == native,
              row.physical_group != 0, row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0,
              bridge.identity(row) != nil else { return nil }
        return row
    }

    func liveClient(in window: UUID, profile: UUID? = nil) -> Int32? {
        guard let mount = mounts[window], mount.shell != nil,
              let snapshot = bridge.readSnapshot() else { return nil }
        let candidates = snapshot.windows.filter {
            $0.physical_group == mount.group && $0.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 &&
            ($0.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == (mount.model?.isIncognito == true) &&
            bridge.identity($0) != nil &&
            (profile == nil || bridge.identity($0) == profile) &&
            ($0.active_tab > 0 || $0.flags & BARC_DISCOVERY_EMPTY_STRIP.rawValue != 0)
        }
        return (candidates.first(where: { $0.selected_client == $0.window }) ?? candidates.first)?.window
    }

    /// Chromium routes a link only to the selected client, so an empty space shows its own
    /// profile's client with the sidebar. Without one, `open` starts it and nil means wait.
    func emptySpaceClient(in window: BrowserWindowState, profile: UUID, open: Bool) -> Int32? {
        guard let mount = mounts[window.id], mount.model === window, mount.shell != nil else { return nil }
        if let client = liveClient(in: window.id, profile: profile) {
            return selectEmptySpaceClient(client, mount: mount) ? client : nil
        }
        if open { prepareEmptySpaceClient(in: window, profile: profile) { _ in } }
        return nil
    }

    private func prepareEmptySpaceClient(in window: BrowserWindowState, profile: UUID,
                                         ready: @escaping @MainActor (Int32?) -> Void) {
        guard let mount = mounts[window.id], mount.model === window, mount.shell != nil,
              !window.isIncognito, let owner = liveClient(in: window.id) else { ready(nil); return }
        let key = CreationKey(window: window.id, profile: profile)
        if let request = emptySpaceOpening[key] { request.ready.append(ready); return }
        if let batch = opening[key] {
            if let native = batch.native { ready(native) }
            else { batch.clientReady.append(ready) }
            return
        }
        let request = EmptySpaceOpening(host: self, key: key, group: mount.group)
        request.ready.append(ready)
        emptySpaceOpening[key] = request
        profile.uuidString.withCString { uuid in
            bridge.profile_open_in_native_window(owner, uuid, BARC_PROFILE_BLANK, { status, native, pointer in
                MainActor.assumeIsolated {
                    guard let pointer else { return }
                    let request = Unmanaged<EmptySpaceOpening>.fromOpaque(pointer).takeRetainedValue()
                    request.host?.openedEmptySpaceClient(request, status: status, native: native)
                }
            }, Unmanaged.passRetained(request).toOpaque())
        }
    }

    private func openedEmptySpaceClient(_ request: EmptySpaceOpening, status: barc_profile_status, native: Int32) {
        guard emptySpaceOpening[request.key] === request else { return }
        emptySpaceOpening.removeValue(forKey: request.key)
        var client: Int32?
        if status == BARC_PROFILE_OK, let row = liveState(native), row.physical_group == request.group,
           bridge.identity(row) == request.key.profile, row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue {
            // The profile factory contributes exactly one blank. A page request
            // may have arrived meanwhile, so leave that creation to enqueue.
            let blank = bridge.window_tab_at(native, 0)
            if blank > 0 {
                _ = bridge.tab_close(native, blank)
            }
            if liveState(native)?.physical_group == request.group { client = native }
        }
        for ready in request.ready { ready(client) }
        request.pageRequests.forEach(enqueue)
    }

    private func selectEmptySpaceClient(_ client: Int32, mount: Mount) -> Bool {
        guard mount.shell != nil, let row = liveState(client), row.physical_group == mount.group else { return false }
        if row.selected_client != client, bridge.window_select(client) != 1 { return false }
        return attachEmptySpaceSidebar(client, mount: mount)
    }

    private func attachEmptySpaceSidebar(_ client: Int32, mount: Mount) -> Bool {
        guard let window = mount.model, mounts[window.id] === mount, mount.shell != nil else { return false }
        mount.generation &+= 1
        let attempt = mount.generation
        func current() -> Bool {
            mounts[window.id] === mount && mount.generation == attempt &&
                liveState(client).map { $0.physical_group == mount.group && $0.selected_client == client } == true
        }
        guard current() else { return false }
        reconcilePeekSidebar(mount)
        let presenter = mount.presenter
        if !presenter.ownsSidebar(client) {
            if let old = mount.attachedClient, old != client, presenter.ownsSidebar(old) {
                guard presenter.detachSidebar(from: old), current() else { return false }
            }
            let attached = presenter.attachSidebar(to: client)
            let owns = presenter.ownsSidebar(client)
            if owns {
                if mount.generation == attempt { mount.attachedClient = client }
                else if mount.attachedClient != client { _ = presenter.detachSidebar(from: client) }
            }
            guard attached, current(), owns else { return false }
        }
        mount.attachedClient = client
        return true
    }

    /// Discovery can distinguish an independent selection from a still-parked
    /// native strip once the bridge has settled this window's empty-space intent.
    func replacedEmptySpaceSelection(in window: BrowserWindowState) -> Bool {
        window.showsNativeEmptySpace && mounts[window.id]?.hasSettledEmptySelection == true
    }

    /// Chromium keeps every emptied client of an app-owned window, Peek's included.
    func closeSurplusClients(in window: BrowserWindowState, snapshot: ChromiumDiscoverySnapshot) {
        guard let mount = mounts[window.id], mount.model === window else { return }
        let empty = BARC_DISCOVERY_EMPTY_STRIP.rawValue
        let busy = Set(opening.values.compactMap(\.native)).union(blankTabs.keys)
        let rows = snapshot.windows.filter {
            $0.physical_group == mount.group && $0.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0
        }.sorted {
            ($0.flags & empty, $0.selected_client == $0.window ? 0 : 1, $0.window) <
                ($1.flags & empty, $1.selected_client == $1.window ? 0 : 1, $1.window)
        }
        var kept: Set<String> = []
        for row in rows {
            guard let identity = bridge.identity(row) else { continue }
            let key = "\(identity.uuidString)/\(row.profile_kind)"
            if kept.contains(key), row.flags & empty != 0, row.selected_client != row.window,
               row.window != mount.attachedClient, !busy.contains(row.window),
               row.flags & BARC_DISCOVERY_AWAITING_ADMISSION.rawValue == 0,
               let current = bridge.windowState(row.window), current.flags & empty != 0,
               current.selected_client != current.window, bridge.window_tab_at(row.window, 0) == 0 {
                _ = bridge.window_close(row.window)
            } else {
                kept.insert(key)
            }
        }
    }

    enum HostError: Error { case unsupportedProfile, missingWindow, creationRefused, cancelled, existingPageRefused, blockerUnavailable }
}
