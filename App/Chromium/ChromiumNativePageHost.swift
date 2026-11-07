import AppKit
import BarcChromium
import Darwin
import NookWeb

struct ChromiumPageHostAPI {
    typealias Callback = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void
    typealias Open = @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Callback?, UnsafeMutableRawPointer?) -> Void
    typealias Create = @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32
    typealias TabAt = @convention(c) (Int32, Int) -> Int32
    typealias WindowCommand = @convention(c) (Int32) -> Int32
    typealias TabTitle = @convention(c) (Int32, Int32, UnsafeMutablePointer<CChar>?, Int) -> Int
    typealias Attach = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32
    let open: Open
    let create: Create
    let tabAt: TabAt
    let tabTitle: TabTitle
    let selectWindow: WindowCommand
    let closeWindow: WindowCommand
    let attach: Attach
    let shellIsOwned: Attach
    let detachIfOwned: Attach

    init(library: UnsafeMutableRawPointer) throws {
        func load<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw ChromiumNavigationError.missingSymbol(name) }
            return unsafeBitCast(address, to: T.self)
        }
        open = try load("barc_profile_open_in_native_window", Open.self)
        create = try load("barc_tab_create", Create.self)
        tabAt = try load("barc_window_tab_at", TabAt.self)
        tabTitle = try load("barc_tab_copy_title", TabTitle.self)
        selectWindow = try load("barc_window_select", WindowCommand.self)
        closeWindow = try load("barc_window_close", WindowCommand.self)
        attach = try load("barc_window_attach_native_shell", Attach.self)
        shellIsOwned = try load("barc_window_native_shell_is_owned", Attach.self)
        detachIfOwned = try load("barc_window_detach_native_shell_if_owned", Attach.self)
    }

    init(open: @escaping Open, create: @escaping Create, tabAt: @escaping TabAt, tabTitle: @escaping TabTitle,
         selectWindow: @escaping WindowCommand, closeWindow: @escaping WindowCommand,
         attach: @escaping Attach, shellIsOwned: @escaping Attach, detachIfOwned: @escaping Attach) {
        self.open = open; self.create = create; self.tabAt = tabAt; self.tabTitle = tabTitle
        self.selectWindow = selectWindow; self.closeWindow = closeWindow; self.attach = attach
        self.shellIsOwned = shellIsOwned; self.detachIfOwned = detachIfOwned
    }
}

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
final class ChromiumNativePageHost: NativePageHost {
    private struct CreationKey: Hashable { let window: UUID; let profile: UUID }
    @MainActor private final class Mount {
        weak var shell: NSView?
        weak var model: BrowserWindowState?
        let group: UInt64
        // Only our last successful header attachment, never native selection.
        var attachedClient: Int32?
        var generation: UInt64 = 0
        init(shell: NSView, group: UInt64, attachedClient: Int32?, model: BrowserWindowState) {
            self.shell = shell; self.group = group; self.attachedClient = attachedClient; self.model = model
        }
    }
    @MainActor private final class Request {
        var cancelled = false
        var completed = false
        var completion: (@MainActor (Result<any PageNavigation, Error>) -> Void)?
        init(_ completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void) {
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
        init(host: ChromiumNativePageHost, key: CreationKey, group: UInt64, request: Request) {
            self.host = host; self.key = key; self.group = group; requests = [request]
        }
    }
    @MainActor private final class Binding {
        var window: UUID
        var admissionGeneration: UInt64 = 0
        let page: ChromiumPageNavigation
        var owned: Bool
        var attempts = 0
        init(window: UUID, page: ChromiumPageNavigation, owned: Bool) {
            self.window = window; self.page = page; self.owned = owned
        }
    }
    private let api: ChromiumPageHostAPI
    private let navigationAPI: ChromiumNavigationAPI
    private let discoveryAPI: ChromiumDiscoveryAPI
    private struct BlankReservation { let tab: Int32; let group: UInt64 }
    private var mounts: [UUID: Mount] = [:]
    private var blankTabs: [Int32: BlankReservation] = [:]
    private var opening: [CreationKey: Batch] = [:]
    private var pages: [ObjectIdentifier: Binding] = [:]
    private var closing: [ObjectIdentifier: [@MainActor (PageCloseOutcome) -> Void]] = [:]

    init(api: ChromiumPageHostAPI, navigationAPI: ChromiumNavigationAPI, discoveryAPI: ChromiumDiscoveryAPI) {
        self.api = api; self.navigationAPI = navigationAPI; self.discoveryAPI = discoveryAPI
    }

    /// Register one model/product shell for a real physical group. This is
    /// pure: discovered shells may remain unattached until native reflection.
    func registerWindow(_ window: BrowserWindowState, nativeOwner: Int32,
                        shell: NSView, initialBlankTab: Int32? = nil) -> Bool {
        guard mounts[window.id] == nil, let row = liveState(nativeOwner),
              !mounts.values.contains(where: { $0.shell === shell || $0.group == row.physical_group }) else { return false }
        let owned = api.shellIsOwned(nativeOwner, Unmanaged.passUnretained(shell).toOpaque()) == 1
        mounts[window.id] = Mount(shell: shell, group: row.physical_group,
                                  attachedClient: owned ? nativeOwner : nil, model: window)
        if let initialBlankTab { blankTabs[nativeOwner] = BlankReservation(tab: initialBlankTab, group: row.physical_group) }
        return true
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
        let request = Request(completion)
        guard profile.engine == .chromium, !profile.isEphemeral, !window.isIncognito else {
            request.finish(.failure(HostError.unsupportedProfile))
            return {}
        }
        let key = CreationKey(window: window.id, profile: profile.id)
        guard let mount = mounts[window.id], mount.model === window, mount.shell != nil else {
            request.finish(.failure(HostError.missingWindow)); return {}
        }
        if let batch = opening[key] {
            guard batch.group == mount.group else { request.finish(.failure(HostError.missingWindow)); return {} }
            batch.requests.append(request)
        } else if let client = liveClient(in: window.id, profile: profile.id) {
            request.finish(makePage(key: key, client: client))
        } else {
            guard let owner = liveClient(in: window.id) else {
                request.finish(.failure(HostError.missingWindow)); return {}
            }
            let batch = Batch(host: self, key: key, group: mount.group, request: request)
            opening[key] = batch
            profile.id.uuidString.withCString { uuid in
                api.open(owner, uuid, 5, { status, native, pointer in
                    MainActor.assumeIsolated {
                        guard let pointer else { return }
                        let batch = Unmanaged<Batch>.fromOpaque(pointer).takeUnretainedValue()
                        batch.host?.opened(batch, status: status, native: native)
                    }
                }, Unmanaged.passUnretained(batch).toOpaque())
            }
        }
        return { if !request.completed { request.cancelled = true } }
    }

    private func opened(_ batch: Batch, status: Int32, native: Int32) {
        guard opening[batch.key] === batch else { return }
        opening.removeValue(forKey: batch.key)
        guard status == 0, let row = liveState(native),
              ChromiumDiscoveryAPI.profileID(row) == batch.key.profile,
              row.physical_group == batch.group,
              let mount = mounts[batch.key.window], mount.group == batch.group,
              mount.model != nil, mount.shell != nil else {
            if status == 0, let row = discoveryAPI.windowState(native),
               ChromiumDiscoveryAPI.profileID(row) == batch.key.profile { _ = api.closeWindow(native) }
            batch.requests.forEach { $0.finish(.failure(HostError.creationRefused)) }
            return
        }
        blankTabs[native] = BlankReservation(tab: api.tabAt(native, 0), group: batch.group)
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
            _ = api.closeWindow(native) // Verified, unclaimed fresh blank client.
        }
    }

    private func makePage(key: CreationKey, client: Int32) -> Result<any PageNavigation, Error> {
        let tab = blankTabs.removeValue(forKey: client)?.tab ??
            "about:blank".withCString { api.create(client, $0, 0) }
        guard tab > 0 else { return .failure(HostError.creationRefused) }
        do {
            let page = try ChromiumPageNavigation(profileID: key.profile, window: client, tab: tab, api: navigationAPI)
            record(page, in: key.window)
            return .success(page)
        } catch {
            if profileID(client) == key.profile { _ = navigationAPI.close(client, tab) }
            return .failure(error)
        }
    }

    private func record(_ page: ChromiumPageNavigation, in windowID: UUID, owned: Bool = true) {
        let id = ObjectIdentifier(page)
        pages[id] = Binding(window: windowID, page: page, owned: owned)
        page.onNativeCloseOutcome = { [weak self, weak page] outcome in
            guard let self, let page else { return }
            if outcome != .cancelled {
                self.pages.removeValue(forKey: id)
                self.blankTabs.removeValue(forKey: page.nativeWindowID)
            }
            let callbacks = self.closing.removeValue(forKey: id) ?? []
            callbacks.forEach { $0(outcome) }
            if outcome == .cancelled, let binding = self.pages[id] { self.discardUnclaimed(binding) }
        }
    }

    /// Bind a page that Chromium already created. Only clients already mounted
    /// for this model window/profile qualify; global discovery is separate.
    func bindExistingPage(nativeWindow: Int32, tab: Int32, profile: Profile,
                          in window: BrowserWindowState) -> Result<ChromiumExistingPageBinding, Error> {
        guard profile.engine == .chromium, !profile.isEphemeral, !window.isIncognito else {
            return .failure(HostError.unsupportedProfile)
        }
        guard let mount = mounts[window.id], mount.model === window, mount.shell != nil,
              let row = liveState(nativeWindow), row.physical_group == mount.group,
              ChromiumDiscoveryAPI.profileID(row) == profile.id,
              tab > 0, api.tabTitle(nativeWindow, tab, nil, 0) > 0 else {
            return .failure(HostError.existingPageRefused)
        }
        if let binding = pages.values.first(where: { $0.page.nativeTabID == tab }) {
            guard binding.page.nativeWindowID == nativeWindow, !binding.page.isClosed,
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
            let page = try ChromiumPageNavigation(profileID: profile.id, window: nativeWindow, tab: tab, api: navigationAPI)
            guard !page.isClosed, let current = liveState(page.nativeWindowID),
                  current.physical_group == mount.group,
                  ChromiumDiscoveryAPI.profileID(current) == profile.id,
                  api.tabTitle(page.nativeWindowID, tab, nil, 0) > 0 else {
                page.invalidate()
                return .failure(HostError.existingPageRefused)
            }
            record(page, in: window.id, owned: false)
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

    private func beginAdmission(_ binding: Binding, previousWindow: UUID? = nil) -> ChromiumExistingPageBinding {
        binding.attempts += 1
        binding.admissionGeneration &+= 1
        let generation = binding.admissionGeneration
        let nativeOwner = binding.page.nativeWindowID
        let modelOwner = binding.window
        return ChromiumExistingPageBinding(navigation: binding.page) { [weak self, weak binding] adopted in
            guard let self, let binding, self.pages[ObjectIdentifier(binding.page)] === binding else { return }
            binding.attempts -= 1
            if adopted { binding.owned = true }
            else if let previousWindow, binding.admissionGeneration == generation,
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
        binding.page.invalidate()
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
        guard let page = navigation as? ChromiumPageNavigation else { return false }
        return admission(page, in: window) != nil
    }

    private func admission(_ page: ChromiumPageNavigation, in window: BrowserWindowState) -> (Mount, BarcDiscoveryWindow)? {
        guard !page.isClosed, let profile = page.profileID,
              let binding = pages[ObjectIdentifier(page)], binding.page === page,
              binding.window == window.id, closing[ObjectIdentifier(page)] == nil,
              let mount = mounts[window.id], mount.model === window, mount.shell != nil,
              let row = liveState(page.nativeWindowID), row.physical_group == mount.group,
              ChromiumDiscoveryAPI.profileID(row) == profile,
              api.tabTitle(page.nativeWindowID, page.nativeTabID, nil, 0) > 0 else { return nil }
        return (mount, row)
    }

    private func selected(_ page: ChromiumPageNavigation, in window: BrowserWindowState) -> Bool {
        guard let (_, row) = admission(page, in: window) else { return false }
        return row.selected_client == page.nativeWindowID && row.active_tab == page.nativeTabID
    }

    func isNativeSelection(_ navigation: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard let page = navigation as? ChromiumPageNavigation,
              let (mount, row) = admission(page, in: window), let shell = mount.shell,
              row.selected_client == page.nativeWindowID, row.active_tab == page.nativeTabID else { return false }
        return api.shellIsOwned(page.nativeWindowID, Unmanaged.passUnretained(shell).toOpaque()) == 1
    }

    func acceptNativeSelection(_ navigation: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard let page = navigation as? ChromiumPageNavigation,
              let (mount, row) = admission(page, in: window),
              row.selected_client == page.nativeWindowID, row.active_tab == page.nativeTabID else { return false }
        mount.generation &+= 1
        return attachSelected(page, in: window, mount: mount, attempt: mount.generation)
    }

    private func attachSelected(_ page: ChromiumPageNavigation, in window: BrowserWindowState,
                                mount: Mount, attempt: UInt64) -> Bool {
        guard let shell = mount.shell else { return false }
        let pointer = Unmanaged.passUnretained(shell).toOpaque()
        func current() -> Bool {
            mounts[window.id] === mount && mount.generation == attempt && selected(page, in: window)
        }
        guard current() else { return false }
        let target = page.nativeWindowID
        if api.shellIsOwned(target, pointer) == 1 { mount.attachedClient = target; return current() }
        if let old = mount.attachedClient, old != target, api.shellIsOwned(old, pointer) == 1 {
            let detached = api.detachIfOwned(old, pointer)
            guard current(), detached == 1 else { return false }
        }
        let attached = api.attach(target, pointer)
        let owns = api.shellIsOwned(target, pointer) == 1
        // Native attachment may succeed physically but report supersession.
        // Remember that actual owner so the next reflection can detach it.
        if owns {
            if mount.generation == attempt {
                mount.attachedClient = target
            } else if mount.attachedClient != target {
                // A nested Swift mount already won. Release only this older
                // call's exact view, never its newer destination's header.
                _ = api.detachIfOwned(target, pointer)
            }
        }
        return current() && attached == 1 && owns
    }

    func selectPage(_ navigation: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard let page = navigation as? ChromiumPageNavigation,
              let (mount, before) = admission(page, in: window) else { return false }
        let previous = discoveryAPI.windowState(before.selected_client)
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
              let shell = mount.shell else { return false }
        let pointer = Unmanaged.passUnretained(shell).toOpaque()
        let target = page.nativeWindowID
        if target != old.window, api.shellIsOwned(target, pointer) == 1 {
            let detached = api.detachIfOwned(target, pointer)
            guard detached == 1, mount.generation == attempt, selected(page, in: window) else { return false }
        }
        guard api.selectWindow(old.window) == 1, mount.generation == attempt,
              let restored = liveState(old.window), restored.physical_group == mount.group,
              restored.selected_client == old.window, restored.active_tab == previous.active_tab else { return false }
        _ = api.attach(old.window, pointer)
        if api.shellIsOwned(old.window, pointer) == 1 {
            if mount.generation == attempt { mount.attachedClient = old.window }
            else if mount.attachedClient != old.window { _ = api.detachIfOwned(old.window, pointer) }
        }
        return false
    }

    func closePage(_ navigation: any PageNavigation, completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        guard let page = navigation as? ChromiumPageNavigation else { completion(.cancelled); return }
        if page.isClosed { completion(page.nativeCloseOutcome ?? .closed); return }
        let id = ObjectIdentifier(page)
        guard pages[id]?.page === page else { completion(.cancelled); return }
        if closing[id] != nil { closing[id]?.append(completion); return }
        closing[id] = [completion]
        let accepted = page.requestNativeClose()
        // Terminal/cancellation delivery may have completed synchronously.
        if !accepted, let callbacks = closing.removeValue(forKey: id) {
            callbacks.forEach { $0(.cancelled) }
        }
    }

    private func profileID(_ native: Int32) -> UUID? {
        discoveryAPI.windowState(native).flatMap(ChromiumDiscoveryAPI.profileID)
    }

    private func liveState(_ native: Int32) -> BarcDiscoveryWindow? {
        guard native > 0, let row = discoveryAPI.windowState(native), row.window == native,
              row.physical_group != 0, row.flags & 32 == 0,
              ChromiumDiscoveryAPI.profileID(row) != nil else { return nil }
        return row
    }

    private func liveClient(in window: UUID, profile: UUID? = nil) -> Int32? {
        guard let mount = mounts[window], mount.shell != nil,
              let snapshot = discoveryAPI.readSnapshot() else { return nil }
        let candidates = snapshot.windows.filter {
            $0.physical_group == mount.group && $0.flags & 32 == 0 &&
            ChromiumDiscoveryAPI.profileID($0) != nil &&
            (profile == nil || ChromiumDiscoveryAPI.profileID($0) == profile) && $0.active_tab > 0
        }
        return (candidates.first(where: { $0.selected_client == $0.window }) ?? candidates.first)?.window
    }

    enum HostError: Error { case unsupportedProfile, missingWindow, creationRefused, cancelled, existingPageRefused }
}
