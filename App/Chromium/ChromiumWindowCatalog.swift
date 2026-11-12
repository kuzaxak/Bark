import Darwin
import Foundation
import BarcChromium

struct ChromiumDiscoverySnapshot {
    let revision: UInt64
    let windows: [BarcDiscoveryWindow]
    let tabs: [BarcDiscoveryTab]
}

/// The header's contract: the side that allocates a bridge struct sets its size.
protocol BarcSized { init(); var size: Int { get set } }
extension BarcSized {
    static var sized: Self { var value = Self(); value.size = MemoryLayout<Self>.size; return value }
}
extension BarcDiscoveryWindow: BarcSized {}
extension BarcDiscoveryTab: BarcSized {}
extension BarcDiscoverySnapshot: BarcSized {}
extension BarcSplitLayout: BarcSized {}
extension BarcBlockerState: BarcSized {}

/// Snapshots are callback-local, never a persistent copy of Chromium's
/// browser/tab collections.
extension BarcBridge {
    func readSnapshot() -> ChromiumDiscoverySnapshot? {
        var size = BarcDiscoverySnapshot.sized
        let status = discovery_snapshot(nil, 0, nil, 0, &size)
        guard status == BARC_DISCOVERY_READ_CAPACITY.rawValue || status == BARC_DISCOVERY_READ_OK.rawValue else { return nil }
        var windows = [BarcDiscoveryWindow](repeating: .sized, count: size.window_count)
        var tabs = [BarcDiscoveryTab](repeating: .sized, count: size.tab_count)
        let revision = size.revision
        let result = windows.withUnsafeMutableBufferPointer { windowRows in
            tabs.withUnsafeMutableBufferPointer { tabRows in
                discovery_snapshot(windowRows.baseAddress, windowRows.count, tabRows.baseAddress, tabRows.count, &size)
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
        let count = tab_copy_launch_space(window, tab, &bytes, bytes.count)
        guard count != 0 else { return (false, nil) }
        guard count == 37, bytes[36] == 0, !bytes[..<36].contains(0) else { return (true, nil) }
        let text = String(cString: bytes)
        guard let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { return (true, nil) }
        return (true, id)
    }

    func windowState(_ window: Int32) -> BarcDiscoveryWindow? {
        var row = BarcDiscoveryWindow.sized
        return window_discovery_state(window, &row) == 1 ? row : nil
    }

    /// Guest kind alone is insufficient: only the native query admits an exact
    /// manager-owned Barc session. Stock Guest/incognito never becomes regular.
    func privateSessionID(_ row: BarcDiscoveryWindow) -> UUID? {
        guard row.profile_kind == BARC_DISCOVERY_GUEST.rawValue else { return nil }
        var bytes = [CChar](repeating: 0, count: 37)
        guard window_private_session_uuid(row.window, &bytes, bytes.count) == 37, bytes[36] == 0,
              !bytes[..<36].contains(0) else { return nil }
        return UUID(uuidString: String(cString: bytes))
    }

    func identity(_ row: BarcDiscoveryWindow) -> UUID? {
        row.profileID ?? privateSessionID(row)
    }
}

extension BarcDiscoveryWindow {
    var profileID: UUID? {
        guard profile_kind == BARC_DISCOVERY_REGULAR.rawValue else { return nil }
        let bytes = withUnsafeBytes(of: regular_profile_uuid) { Array($0) }
        guard let end = bytes.firstIndex(of: 0), end == 36 else { return nil }
        return UUID(uuidString: String(decoding: bytes[..<end], as: UTF8.self))
    }
}

/// Owns the one invalidation subscription, not a second browser registry.
@MainActor
final class ChromiumWindowCatalog {
    private let bridge: BarcBridge
    private var observation: UInt64 = 0
    var onSnapshot: ((ChromiumDiscoverySnapshot) -> Void)?

    init(bridge: BarcBridge) { self.bridge = bridge }

    func start() -> Bool {
        guard observation == 0 else { return true }
        observation = bridge.discovery_observe({ context, token, _ in
            MainActor.assumeIsolated {
                guard let context else { return }
                let catalog = Unmanaged<ChromiumWindowCatalog>.fromOpaque(context).takeUnretainedValue()
                guard catalog.observation == token, token != 0,
                      let snapshot = catalog.bridge.readSnapshot() else { return }
                catalog.onSnapshot?(snapshot)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        return observation != 0
    }

    func stop() {
        let token = observation
        observation = 0
        onSnapshot = nil
        if token != 0 { bridge.discovery_unobserve(token) }
    }

    isolated deinit { if observation != 0 { bridge.discovery_unobserve(observation) } }
}
