import AppKit
import Darwin
import NookWeb

struct ChromiumPageHostAPI {
    typealias Callback = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void
    typealias Open = @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Callback?, UnsafeMutableRawPointer?) -> Void
    typealias Create = @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32
    typealias TabAt = @convention(c) (Int32, Int) -> Int32
    typealias WindowCommand = @convention(c) (Int32) -> Int32
    typealias Attach = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32
    let open: Open
    let create: Create
    let tabAt: TabAt
    let selectWindow: WindowCommand
    let closeWindow: WindowCommand
    let attach: Attach

    init(library: UnsafeMutableRawPointer) throws {
        func load<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw ChromiumNavigationError.missingSymbol(name) }
            return unsafeBitCast(address, to: T.self)
        }
        open = try load("barc_profile_open_in_native_window", Open.self)
        create = try load("barc_tab_create", Create.self)
        tabAt = try load("barc_window_tab_at", TabAt.self)
        selectWindow = try load("barc_window_select", WindowCommand.self)
        closeWindow = try load("barc_window_close", WindowCommand.self)
        attach = try load("barc_window_attach_native_shell", Attach.self)
    }

    init(open: @escaping Open, create: @escaping Create, tabAt: @escaping TabAt,
         selectWindow: @escaping WindowCommand, closeWindow: @escaping WindowCommand,
         attach: @escaping Attach) {
        self.open = open; self.create = create; self.tabAt = tabAt
        self.selectWindow = selectWindow; self.closeWindow = closeWindow; self.attach = attach
    }
}

/// Only native handles are cached here. TabsController remains the model owner.
/// The app retains this host until Chromium stops delivering callbacks.
@MainActor
final class ChromiumNativePageHost: NativePageHost {
    private struct ClientKey: Hashable { let window: UUID; let profile: UUID }
    @MainActor private final class Mount {
        weak var shell: NSView?
        var client: Int32
        var generation: UInt64 = 0
        init(shell: NSView, client: Int32) { self.shell = shell; self.client = client }
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
        let key: ClientKey
        var requests: [Request]
        init(host: ChromiumNativePageHost, key: ClientKey, request: Request) {
            self.host = host; self.key = key; requests = [request]
        }
    }
    private struct Binding {
        let window: UUID
        let page: ChromiumPageNavigation
    }
    private let api: ChromiumPageHostAPI
    private let navigationAPI: ChromiumNavigationAPI
    private var mounts: [UUID: Mount] = [:]
    private var clients: [ClientKey: Int32] = [:]
    private var blankTabs: [Int32: Int32] = [:]
    private var opening: [ClientKey: Batch] = [:]
    private var pages: [ObjectIdentifier: Binding] = [:]
    private var closing: [ObjectIdentifier: [@MainActor (PageCloseOutcome) -> Void]] = [:]

    init(api: ChromiumPageHostAPI, navigationAPI: ChromiumNavigationAPI) {
        self.api = api; self.navigationAPI = navigationAPI
    }

    /// Register the caller's already-attached product shell; never create a
    /// demo view or a second hosting view. Call only after successful attachment.
    /// initialBlankTab is supplied only for a real BLANK(5) factory result.
    func registerWindow(_ window: BrowserWindowState, nativeOwner: Int32,
                        shell: NSView, initialBlankTab: Int32? = nil) -> Bool {
        guard mounts[window.id] == nil, let profile = profileID(nativeOwner),
              !mounts.values.contains(where: { $0.shell === shell || $0.client == nativeOwner }) else { return false }
        mounts[window.id] = Mount(shell: shell, client: nativeOwner)
        clients[ClientKey(window: window.id, profile: profile)] = nativeOwner
        if let initialBlankTab { blankTabs[nativeOwner] = initialBlankTab }
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
        let key = ClientKey(window: window.id, profile: profile.id)
        if let client = clients[key], profileID(client) == profile.id, api.tabAt(client, 0) > 0 {
            request.finish(makePage(key: key, client: client))
        } else if let batch = opening[key] {
            batch.requests.append(request)
        } else {
            clients.removeValue(forKey: key)
            guard let owner = liveClient(in: window.id) else {
                request.finish(.failure(HostError.missingWindow))
                return {}
            }
            let batch = Batch(host: self, key: key, request: request)
            opening[key] = batch // Before the C API can complete reentrantly.
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
        guard status == 0, native > 0, profileID(native) == batch.key.profile else {
            batch.requests.forEach { $0.finish(.failure(HostError.creationRefused)) }
            return
        }
        clients[batch.key] = native
        blankTabs[native] = api.tabAt(native, 0)
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
            clients.removeValue(forKey: batch.key)
            _ = api.closeWindow(native) // Verified, unclaimed fresh blank client.
        }
    }

    private func makePage(key: ClientKey, client: Int32) -> Result<any PageNavigation, Error> {
        let tab = blankTabs.removeValue(forKey: client) ??
            "about:blank".withCString { api.create(client, $0, 0) }
        guard tab > 0 else { return .failure(HostError.creationRefused) }
        do {
            let page = try ChromiumPageNavigation(profileID: key.profile, window: client, tab: tab, api: navigationAPI)
            let id = ObjectIdentifier(page)
            pages[id] = Binding(window: key.window, page: page)
            page.onNativeCloseOutcome = { [weak self, weak page] outcome in
                guard let self, let page else { return }
                if outcome != .cancelled {
                    self.pages.removeValue(forKey: id)
                    self.blankTabs.removeValue(forKey: page.nativeWindowID)
                }
                if outcome == .ownerEnded {
                    let owner = page.nativeWindowID
                    for key in self.clients.keys.filter({ self.clients[$0] == owner }) {
                        self.clients.removeValue(forKey: key)
                    }
                    self.blankTabs.removeValue(forKey: owner)
                    for mount in self.mounts.values where mount.client == owner {
                        mount.generation &+= 1
                        mount.client = 0
                    }
                }
                let callbacks = self.closing.removeValue(forKey: id) ?? []
                callbacks.forEach { $0(outcome) }
            }
            return .success(page)
        } catch {
            if profileID(client) == key.profile { _ = navigationAPI.close(client, tab) }
            return .failure(error)
        }
    }

    func selectPage(_ navigation: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard let page = navigation as? ChromiumPageNavigation,
              let binding = pages[ObjectIdentifier(page)], binding.window == window.id,
              let mount = mounts[window.id], let shell = mount.shell,
              profileID(page.nativeWindowID) == page.profileID else { return false }
        // Cross-window transfer is explicitly unsupported until attachment and
        // last-tab source lifetime can be admitted transactionally.
        let old = mount.client
        mount.generation &+= 1
        let attempt = mount.generation
        // Native callbacks may supersede this request. Never select an older
        // client merely because the runtime rejected a superseded admission.
        guard page.selectNativePage(), mount.generation == attempt else { return false }
        let target = page.nativeWindowID
        if old == target { return true }
        let oldAlive = profileID(old) != nil
        if oldAlive {
            let detached = api.attach(old, nil)
            guard mount.generation == attempt else { return false }
            if detached != 1 {
                _ = api.selectWindow(old)
                return false
            }
        }
        let attached = api.attach(target, Unmanaged.passUnretained(shell).toOpaque())
        guard mount.generation == attempt else { return false }
        guard attached == 1 else {
            if oldAlive, profileID(old) != nil {
                _ = api.selectWindow(old)
                guard mount.generation == attempt else { return false }
                _ = api.attach(old, Unmanaged.passUnretained(shell).toOpaque())
            }
            return false
        }
        mount.client = target
        return true
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
        var buffer = [CChar](repeating: 0, count: 37)
        guard native > 0, navigationAPI.profileUUID(native, &buffer, buffer.count) == buffer.count else { return nil }
        return UUID(uuidString: String(decoding: buffer.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    private func liveClient(in window: UUID) -> Int32? {
        guard let mount = mounts[window], mount.shell != nil else { return nil }
        if profileID(mount.client) != nil, api.tabAt(mount.client, 0) > 0 { return mount.client }
        // Last-tab closure can destroy the cached Browser while a sibling
        // logical client still owns the same physical native window.
        for (key, native) in clients where key.window == window {
            if profileID(native) != nil, api.tabAt(native, 0) > 0 { return native }
            clients.removeValue(forKey: key)
        }
        return nil
    }

    enum HostError: Error { case unsupportedProfile, missingWindow, creationRefused, cancelled }
}
