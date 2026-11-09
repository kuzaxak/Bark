import Darwin
import Foundation
import BarcChromium

struct ChromiumDiscoverySnapshot {
    let revision: UInt64
    let windows: [BarcDiscoveryWindow]
    let tabs: [BarcDiscoveryTab]
}

/// Typed imports of the existing C boundary; snapshots are callback-local,
/// never a persistent copy of Chromium's browser/tab collections.
struct ChromiumDiscoveryAPI {
    typealias Read = @convention(c) (UnsafeMutablePointer<BarcDiscoveryWindow>?, Int,
        UnsafeMutablePointer<BarcDiscoveryTab>?, Int, UnsafeMutablePointer<BarcDiscoverySnapshot>?) -> Int32
    typealias State = @convention(c) (Int32, UnsafeMutablePointer<BarcDiscoveryWindow>?) -> Int32
    typealias Observe = @convention(c) (BarcDiscoveryCallback?, UnsafeMutableRawPointer?) -> UInt64
    typealias Unobserve = @convention(c) (UInt64) -> Void
    typealias PrivateUUID = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int
    typealias LaunchSpace = @convention(c) (Int32, Int32, UnsafeMutablePointer<CChar>?, Int) -> Int
    typealias Pending = @convention(c) (Int32, Int32) -> Int32
    typealias Admit = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32
    let read: Read
    let state: State
    let observe: Observe
    let unobserve: Unobserve
    let admit: Admit
    let privateUUID: PrivateUUID
    let launchSpace: LaunchSpace
    let applicationPending: Pending
    let show: @convention(c) (Int32) -> Int32

    init(library: UnsafeMutableRawPointer) throws {
        func load<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw ChromiumNavigationError.missingSymbol(name) }
            return unsafeBitCast(address, to: T.self)
        }
        read = try load("barc_discovery_snapshot", Read.self)
        state = try load("barc_window_discovery_state", State.self)
        observe = try load("barc_discovery_observe", Observe.self)
        unobserve = try load("barc_discovery_unobserve", Unobserve.self)
        admit = try load("barc_window_admit_discovered", Admit.self)
        privateUUID = try load("barc_window_private_session_uuid", PrivateUUID.self)
        launchSpace = try load("barc_tab_copy_launch_space", LaunchSpace.self)
        applicationPending = try load("barc_tab_application_pending", Pending.self)
        show = try load("barc_window_show", (@convention(c) (Int32) -> Int32).self)
    }

    init(read: @escaping Read, state: @escaping State, observe: @escaping Observe,
         unobserve: @escaping Unobserve, admit: @escaping Admit,
         privateUUID: @escaping PrivateUUID = { _, _, _ in 0 },
         launchSpace: @escaping LaunchSpace = { _, _, _, _ in 0 },
         applicationPending: @escaping Pending = { _, _ in 0 },
         show: @escaping @convention(c) (Int32) -> Int32 = { _ in 0 }) {
        self.read = read; self.state = state; self.observe = observe
        self.unobserve = unobserve; self.admit = admit; self.privateUUID = privateUUID; self.show = show
        self.launchSpace = launchSpace; self.applicationPending = applicationPending
    }

    func readSnapshot() -> ChromiumDiscoverySnapshot? {
        var size = BarcDiscoverySnapshot()
        let status = read(nil, 0, nil, 0, &size)
        guard status == BARC_DISCOVERY_READ_CAPACITY.rawValue || status == BARC_DISCOVERY_READ_OK.rawValue else { return nil }
        var windows = [BarcDiscoveryWindow](repeating: BarcDiscoveryWindow(), count: size.window_count)
        var tabs = [BarcDiscoveryTab](repeating: BarcDiscoveryTab(), count: size.tab_count)
        let revision = size.revision
        let result = windows.withUnsafeMutableBufferPointer { windowRows in
            tabs.withUnsafeMutableBufferPointer { tabRows in
                read(windowRows.baseAddress, windowRows.count, tabRows.baseAddress, tabRows.count, &size)
            }
        }
        // No client callout/yield occurs between these two pure reads.
        guard result == BARC_DISCOVERY_READ_OK.rawValue, revision == size.revision,
              windows.count == size.window_count, tabs.count == size.tab_count else { return nil }
        return ChromiumDiscoverySnapshot(revision: size.revision, windows: windows, tabs: tabs)
    }

    /// A one-shot native request hint, read only for newly unmodeled pages.
    /// Missing and malformed are distinct: a supplied stale target cannot fall
    /// back to an unrelated profile/space.
    func requestedSpace(window: Int32, tab: Int32) -> (supplied: Bool, id: UUID?) {
        var bytes = [CChar](repeating: 0, count: 37)
        let count = launchSpace(window, tab, &bytes, bytes.count)
        guard count != 0 else { return (false, nil) }
        guard count == 37, bytes[36] == 0, !bytes[..<36].contains(0) else { return (true, nil) }
        let text = String(cString: bytes)
        guard let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { return (true, nil) }
        return (true, id)
    }

    func windowState(_ window: Int32) -> BarcDiscoveryWindow? {
        var row = BarcDiscoveryWindow()
        return state(window, &row) == 1 ? row : nil
    }

    /// Guest kind alone is insufficient: only the native query admits an exact
    /// manager-owned Barc session. Stock Guest/incognito never becomes regular.
    func privateSessionID(_ row: BarcDiscoveryWindow) -> UUID? {
        guard row.profile_kind == BARC_DISCOVERY_GUEST.rawValue else { return nil }
        var bytes = [CChar](repeating: 0, count: 37)
        guard privateUUID(row.window, &bytes, bytes.count) == 37, bytes[36] == 0,
              !bytes[..<36].contains(0) else { return nil }
        return UUID(uuidString: String(cString: bytes))
    }

    func identity(_ row: BarcDiscoveryWindow) -> UUID? {
        Self.profileID(row) ?? privateSessionID(row)
    }

    static func profileID(_ row: BarcDiscoveryWindow) -> UUID? {
        guard row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue else { return nil }
        let bytes = withUnsafeBytes(of: row.regular_profile_uuid) { Array($0) }
        guard let end = bytes.firstIndex(of: 0), end == 36 else { return nil }
        return UUID(uuidString: String(decoding: bytes[..<end], as: UTF8.self))
    }
}

/// Owns the one invalidation subscription, not a second browser registry.
@MainActor
final class ChromiumWindowCatalog {
    private let api: ChromiumDiscoveryAPI
    private var observation: UInt64 = 0
    var onSnapshot: ((ChromiumDiscoverySnapshot) -> Void)?

    init(api: ChromiumDiscoveryAPI) { self.api = api }

    func start() -> Bool {
        guard observation == 0 else { return true }
        observation = api.observe({ context, token, _ in
            MainActor.assumeIsolated {
                guard let context else { return }
                let catalog = Unmanaged<ChromiumWindowCatalog>.fromOpaque(context).takeUnretainedValue()
                guard catalog.observation == token, token != 0,
                      let snapshot = catalog.api.readSnapshot() else { return }
                catalog.onSnapshot?(snapshot)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        return observation != 0
    }

    func stop() {
        let token = observation
        observation = 0
        onSnapshot = nil
        if token != 0 { api.unobserve(token) }
    }

    isolated deinit { if observation != 0 { api.unobserve(observation) } }
}
