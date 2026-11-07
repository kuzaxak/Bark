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
    typealias Admit = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32
    let read: Read
    let state: State
    let observe: Observe
    let unobserve: Unobserve
    let admit: Admit

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
    }

    init(read: @escaping Read, state: @escaping State, observe: @escaping Observe,
         unobserve: @escaping Unobserve, admit: @escaping Admit) {
        self.read = read; self.state = state; self.observe = observe
        self.unobserve = unobserve; self.admit = admit
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

    func windowState(_ window: Int32) -> BarcDiscoveryWindow? {
        var row = BarcDiscoveryWindow()
        return state(window, &row) == 1 ? row : nil
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
