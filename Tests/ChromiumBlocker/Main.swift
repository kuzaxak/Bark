import BarcChromium
import Foundation
import NookBlocker
import NookSettings
#if BARK_CATALOG_FRAMEWORK
@testable import NookNativeShell
#endif

@MainActor private enum Native {
    struct Source {
        let revision: UInt64, generation: UInt64
        let bytes: UnsafePointer<UInt8>?, count: Int, checksum: UInt64
        let callback: BarcBlockerCallback, reply: UnsafeMutableRawPointer?
    }
    struct Preparation { let window: Int32; let callback: BarcBlockerCallback; let reply: UnsafeMutableRawPointer? }
    static var sources: [Source] = [], preparations: [Preparation] = []
    static var windows: [Int32: UInt64] = [1: 101, 2: 101]
    static var installed: [UInt64: UInt64] = [:]
    static var revision: UInt64 = 0, generation: UInt64 = 0, serial: UInt64 = 0
    static var required: UInt64 = 0
    static var failed: Set<UInt64> = []
    static var policy: Int32 = -1, domains: [String] = [], policyCalls = 0
    static var tabPolicies: [(Int32, Int32)] = []
    static var onPolicy: (() -> Void)?
    static var onGlobalPolicy: (() -> Void)?
    static var refuseBytes = false
    static func hash(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64(bytes[$1])) &* 0x100000001b3 }
    }
    static func reset() {
        precondition(sources.isEmpty && preparations.isEmpty)
        windows = [1: 101, 2: 101]; installed = [:]; revision = 0; generation = 0; serial = 0
        policy = -1; required = 0; failed = []; domains = []; policyCalls = 0; tabPolicies = []; onPolicy = nil; onGlobalPolicy = nil; refuseBytes = false
    }
    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.blocker_publish_rules = { bytes, count, generation, callback, reply in MainActor.assumeIsolated {
            guard let callback, generation != 0, (bytes != nil || count == 0) else { return 0 }
            if Native.refuseBytes && bytes != nil { return 0 }
            Native.serial += 1
            Native.sources.append(Source(revision: Native.serial, generation: generation, bytes: bytes, count: count,
                checksum: bytes.map { Native.hash($0, count) } ?? 0, callback: callback, reply: reply)); return 1
        } }
        bridge.blocker_set_policy = { policy, required, domains, count in MainActor.assumeIsolated {
            Native.policy = policy; Native.required = required; Native.domains = (0..<count).map { String(cString: domains![$0]!) }; Native.policyCalls += 1; Native.onGlobalPolicy?(); return 1
        } }
        bridge.blocker_prepare = { window, callback, reply in MainActor.assumeIsolated {
            guard Native.windows[window] != nil, let callback else { return 0 }
            if Native.failed.contains(Native.required), Native.policy == 1 {
                callback(reply, 0, Int32(BARC_BLOCKER_INVALID_RULES.rawValue))
            } else { Native.preparations.append(Preparation(window: window, callback: callback, reply: reply)) }
            return 1
        } }
        bridge.blocker_set_tab_policy = { window, tab, _, _, _ in MainActor.assumeIsolated {
            guard Native.windows[window] != nil else { return 0 }
            Native.tabPolicies.append((window, tab)); Native.onPolicy?(); return 1
        } }
        bridge.blocker_state = { window, output in MainActor.assumeIsolated {
            guard let output, output.pointee.size >= MemoryLayout<BarcBlockerState>.size, let id = Native.windows[window] else { return 0 }
            let size = output.pointee.size
            output.pointee = BarcBlockerState(); output.pointee.size = size; output.pointee.context_id = id
            output.pointee.publication_revision = Native.revision; output.pointee.source_generation = Native.generation
            output.pointee.required_source_generation = Native.required
            output.pointee.installed_revision = Native.installed[id] ?? 0; output.pointee.requested_policy = Native.policy
            output.pointee.ready = Native.policy == 0 || (Native.policy == 1 && Native.generation == Native.required && Native.revision != 0 && Native.installed[id] == Native.revision) ? 1 : 0
            return 1
        } }
        return bridge
    }
    static func finishSource(_ result: BarcBlockerResult, index: Int = 0) {
        precondition(sources.indices.contains(index), "Missing source callback")
        let source = sources.remove(at: index)
        precondition((source.bytes.map { hash($0, source.count) } ?? 0) == source.checksum)
        if result == BARC_BLOCKER_READY { revision = source.revision; generation = source.generation }
        if result == BARC_BLOCKER_INVALID_RULES { failed.insert(source.generation) }
        source.callback(source.reply, source.revision, Int32(result.rawValue))
        if result == BARC_BLOCKER_INVALID_RULES, source.generation == required {
            let waiting = preparations; preparations = []
            waiting.forEach { $0.callback($0.reply, revision, Int32(BARC_BLOCKER_INVALID_RULES.rawValue)) }
        }
    }
    static func finishPreparation(_ result: BarcBlockerResult = BARC_BLOCKER_READY, index: Int = 0, line: Int = #line) {
        precondition(preparations.indices.contains(index), "Missing prepare callback at \(line)")
        let p = preparations.remove(at: index)
        if result == BARC_BLOCKER_READY, let id = windows[p.window], policy == 1 { installed[id] = revision }
        p.callback(p.reply, policy == 0 ? 0 : revision, Int32(result.rawValue))
    }
}

private struct NoCredentials: KagiTokenStore { func load() -> String? { nil }; func save(_ token: String?) {} }
@MainActor private final class Fixture {
    let suite = "ChromiumBlockerAdapter-\(UUID().uuidString)"
    let defaults: UserDefaults, directory: URL, settings: NookSettingsService, manager: ContentBlockerManager
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".etags"), withIntermediateDirectories: true)
        for (index, list) in FilterListManager.defaultLists.enumerated() {
            try (index == 0 ? "||ads.test^$script" : "! synthetic empty list").write(to: directory.appendingPathComponent(list.filename), atomically: true, encoding: .utf8)
        }
        for list in FilterListManager.defaultLists + FilterListManager.optionalLists {
            try String(Date().timeIntervalSince1970).write(to: directory.appendingPathComponent(".etags/\(list.filename).checked"), atomically: true, encoding: .utf8)
        }
        settings = NookSettingsService(kagiTokenStore: NoCredentials(), userDefaults: defaults,
            boostStore: .init(fileURL: directory.appendingPathComponent("Boosts.json")))
        settings.adBlockerEnabled = true; settings.adBlockerWhitelist = []; settings.enabledOptionalFilterLists = []
        manager = ContentBlockerManager(settings: settings, storageDirectory: directory)
    }
    func start() async { manager.setEnabled(true); await manager.activationTask?.value; precondition(manager.networkRules != nil) }
    func cleanup() { manager.setEnabled(false); settings.flushBoosts(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
}
@MainActor private func drain() async {
    for _ in 0..<8 { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
}

@MainActor private final class Page: BlockablePage {
    let itemID = UUID()
    var isOAuthFlow = false
    var isPrivate = false
    var blockingURL: URL? { nil }
    func reloadForBlocking() -> Bool { false }
}

private func check(_ condition: Bool) { precondition(condition) }

@main struct Checks {
    @MainActor static func main() async throws {
        let f = try Fixture(); defer { f.cleanup() }; await f.start()
        Native.reset(); Native.windows = [:]
        var adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        // Proactive source publication does not depend on any browser/context.
        precondition(Native.sources.count == 1 && Native.policy == 1)
        Native.finishSource(BARC_BLOCKER_READY); await drain()
        Native.windows = [1: 101, 2: 101, 3: 202]
        let a = Task { await adapter.prepare(in: 1) }, b = Task { await adapter.prepare(in: 2) }
        await drain(); precondition(Native.sources.isEmpty && Native.preparations.count == 2)
        // Source acceptance is not context readiness, nor another OTR context.
        let page = Page()
        precondition(!adapter.apply(to: page, window: 1, tab: 10))
        Native.finishPreparation(); Native.finishPreparation()
        check(await a.value); check(await b.value)
        precondition(adapter.apply(to: page, window: 1, tab: 10))
        precondition(!adapter.apply(to: page, window: 3, tab: 30))
        f.manager.allowDomain("ALLOWED.TEST", from: nil)
        precondition(Native.domains == ["allowed.test"] && Native.sources.isEmpty)
        await drain() // Finish the settings observer before the direct disable below.
        let acceptedSerial = Native.serial, acceptedToken = f.manager.networkSourceGeneration
        check(await !f.manager.updateFilterLists())
        precondition(Native.sources.isEmpty && Native.serial == acceptedSerial && f.manager.networkSourceGeneration == acceptedToken)
        adapter.stop()

        // Disabled policy releases without bytes; later publication cannot
        // turn it back on. Borrowed bytes remain live through shutdown callback.
        f.manager.setEnabled(false); Native.reset()
        adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        precondition(Native.policy == 0 && Native.sources.isEmpty)
        let disabled = Task { await adapter.prepare(in: 1) }; await drain()
        Native.finishPreparation(); check(await disabled.value)
        await f.start(); precondition(Native.sources.count == 1)
        f.manager.setEnabled(false); precondition(Native.policy == 0)
        adapter.stop(); Native.finishSource(BARC_BLOCKER_READY); await drain()
        precondition(Native.policy == 0)

        // Source validation is intentionally suspended. Disabled readiness must
        // settle without completing that producer or consuming its borrowed bytes.
        await f.start(); Native.reset(); adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        precondition(Native.revision == 0 && Native.sources.count == 1)
        let waitingForSource = Task { await adapter.prepare(in: 1) }; await drain()
        precondition(Native.preparations.count == 1)
        f.manager.setEnabled(false)
        Native.finishPreparation(); check(await waitingForSource.value)
        precondition(Native.sources.count == 1 && Native.policy == 0)
        Native.finishSource(BARC_BLOCKER_READY); await drain(); precondition(Native.policy == 0)
        adapter.stop()

        // New source ordering is synchronous, independent of task scheduling.
        await f.start(); Native.reset(); adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        let firstGeneration = Native.sources[0].generation
        f.manager.setEnabled(false); await f.start()
        precondition(Native.sources.count == 2 && Native.sources[1].generation != firstGeneration)
        Native.finishSource(BARC_BLOCKER_READY, index: 1)
        Native.finishSource(BARC_BLOCKER_SUPERSEDED); await drain()
        let current = Task { await adapter.prepare(in: 1) }; await drain()
        Native.finishPreparation(); check(await current.value)
        precondition(Native.policy == 1 && Native.sources.isEmpty)
        adapter.stop()

        // Invalid source cannot earn readiness or duplicate publication.
        Native.reset(); adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        Native.finishSource(BARC_BLOCKER_INVALID_RULES); await drain()
        check(await !adapter.prepare(in: 1)); precondition(Native.sources.isEmpty && Native.preparations.isEmpty)
        adapter.stop()

        // Synchronous byte rejection owns no callback; the bounded failure
        // marker settles its requirement instead of leaving native waiters held.
        Native.reset(); Native.refuseBytes = true
        adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        precondition(Native.sources.count == 1 && Native.sources[0].bytes == nil)
        let refusedBytes = Task { await adapter.prepare(in: 1) }; await drain()
        Native.finishSource(BARC_BLOCKER_INVALID_RULES); check(await !refusedBytes.value)
        precondition(Native.preparations.isEmpty)
        adapter.stop()

        // Exact-context callback, supersession and shutdown each finish once.
        Native.reset(); adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        Native.finishSource(BARC_BLOCKER_READY); await drain()
        let changed = Task { await adapter.prepare(in: 1) }; await drain()
        Native.finishPreparation(); Native.windows[1] = 303
        check(await !changed.value)
        let ended = Task { await adapter.prepare(in: 2) }; await drain()
        adapter.stop(); Native.finishPreparation(BARC_BLOCKER_OWNER_ENDED); check(await !ended.value)

        // Front-only admission retains a live peer, then cached preparation
        // publishes once and pure ready queries do not wake themselves.
        Native.reset(); adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        Native.finishSource(BARC_BLOCKER_READY); await drain()
        let peer = Page(); var live = true, livePeer = true
        precondition(adapter.admitApplicationPage(window: 1, tab: 10, session: page,
            isPending: { live }, canAdmit: { true }) == -1)
        await drain()
        precondition(adapter.admitApplicationPage(window: 2, tab: 20, session: peer,
            isPending: { livePeer }, canAdmit: { true }) == -1)
        Native.onPolicy = { DispatchQueue.main.async {
            precondition(adapter.admitApplicationPage(window: 1, tab: 10, session: page,
                isPending: { live }, canAdmit: { true }) == 1)
        } }
        Native.finishPreparation(); await drain(); Native.onPolicy = nil
        precondition(Native.tabPolicies.count == 1)
        live = false
        _ = adapter.admitApplicationPage(window: 2, tab: 20, session: peer,
            isPending: { livePeer }, canAdmit: { true })
        await drain(); Native.finishPreparation(); await drain()
        precondition(adapter.admitApplicationPage(window: 2, tab: 20, session: peer,
            isPending: { livePeer }, canAdmit: { true }) == 1)
        precondition(Native.tabPolicies.count == 2 && Native.sources.isEmpty)
        var validations = 0; live = true
        precondition(adapter.admitApplicationPage(window: 2, tab: 20, session: peer,
            isPending: { livePeer }, canAdmit: {
                validations += 1
                if validations == 2 {
                    livePeer = false
                    precondition(adapter.admitApplicationPage(window: 1, tab: 10, session: page,
                        isPending: { live }, canAdmit: { true }) == -1)
                }
                return true
            }) == 0)
        await drain(); Native.finishPreparation(); await drain()
        precondition(adapter.admitApplicationPage(window: 1, tab: 10, session: page,
            isPending: { live }, canAdmit: { true }) == 1)
        precondition(Native.tabPolicies.count == 3)
        adapter.stop()

        // Closed/superseded fronts and cancelled waiters never publish late
        // page readiness, while native completions retain exact-once ownership.
        Native.reset(); adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        Native.finishSource(BARC_BLOCKER_READY); await drain()
        live = true
        _ = adapter.admitApplicationPage(window: 1, tab: 10, session: page,
            isPending: { live }, canAdmit: { true })
        await drain(); live = false; Native.finishPreparation(); await drain()
        precondition(Native.tabPolicies.isEmpty)
        _ = adapter.admitApplicationPage(window: 1, tab: 11, session: peer,
            isPending: { true }, canAdmit: { true })
        await drain(); adapter.cancelApplicationPreparation()
        Native.finishPreparation(); await drain()
        precondition(Native.tabPolicies.isEmpty)
        adapter.stop()

        Native.reset(); adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        Native.finishSource(BARC_BLOCKER_INVALID_RULES); await drain(); live = true
        _ = adapter.admitApplicationPage(window: 1, tab: 10, session: page,
            isPending: { live }, canAdmit: { true })
        await drain()
        precondition(adapter.admitApplicationPage(window: 1, tab: 10, session: page,
            isPending: { live }, canAdmit: { true }) == 0)
        precondition(Native.tabPolicies.count == 1 && Native.preparations.isEmpty && Native.sources.isEmpty)
        adapter.stop()
        // Atomic policy is a callout. A newer disable during it must not be
        // overwritten in the cache or followed by an obsolete publication.
        Native.reset()
        Native.onGlobalPolicy = {
            Native.onGlobalPolicy = nil
            f.manager.setEnabled(false)
        }
        adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        precondition(Native.policy == 0 && Native.policyCalls == 2 && Native.sources.isEmpty)
        let reentrantDisabled = Task { await adapter.prepare(in: 1) }; await drain()
        Native.finishPreparation(); check(await reentrantDisabled.value)
        precondition(Native.policyCalls == 2)
        adapter.stop()
        // A current producer failure explicitly settles the native requirement
        // while retaining the prior accepted publication for future reuse.
        Native.reset(); await f.start()
        adapter = ChromiumContentBlocker(bridge: Native.bridge, manager: f.manager)
        Native.finishSource(BARC_BLOCKER_READY)
        let accepted = Native.revision
        f.manager.setEnabled(false)
        f.manager.setEnabled(true)
        let producer = f.manager.activationTask!
        producer.cancel()
        let failedProducer = Task { await adapter.prepare(in: 1) }
        await producer.value; await drain()
        precondition(Native.sources.count == 1 && Native.sources[0].bytes == nil && Native.sources[0].count == 0)
        Native.finishSource(BARC_BLOCKER_INVALID_RULES)
        check(await !failedProducer.value)
        precondition(Native.revision == accepted && Native.preparations.isEmpty)
        adapter.stop()
        print("Chromium factory blocker checks PASS")
    }
}
