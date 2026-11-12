import BarcChromium
import Darwin
import Foundation
import NookBlocker

/// One authoritative factory source. Native Profile/OTR services own context
/// installation and readiness, including contexts with no browser window.
@MainActor
final class ChromiumContentBlocker {
    @MainActor private final class Publication {
        let generation: UInt64
        let bytes: NSData?
        init(generation: UInt64, rules: BlockerEngine.NetworkRules?) {
            self.generation = generation; bytes = rules.map { $0.bytes as NSData }
        }
    }
    @MainActor private final class Reply {
        // Own the immutable source until native's exact-once UI completion.
        let publication: Publication?
        let completion: (UInt64, Int32) -> Void
        init(_ publication: Publication? = nil, completion: @escaping (UInt64, Int32) -> Void) {
            self.publication = publication; self.completion = completion
        }
    }
    @MainActor private final class ApplicationPreparation {
        let window: Int32
        let tab: Int32
        weak var session: (any BlockablePage)?
        let isPending: @MainActor () -> Bool
        var task: Task<Void, Never>?
        var result = BARC_APPLICATION_TARGET_ORDINARY_WINDOW.rawValue
        var policy: ContentBlockerManager.NetworkPagePolicy?
        init(window: Int32, tab: Int32, session: any BlockablePage, isPending: @escaping @MainActor () -> Bool) {
            self.window = window; self.tab = tab; self.session = session; self.isPending = isPending
        }
    }
    // The native producer owns the pending URLs/order. This is only the one
    // current front's asynchronous policy preparation, never a URL queue.
    private var applicationPreparation: ApplicationPreparation?
    private let bridge: BarcBridge
    private weak var manager: ContentBlockerManager?
    private var publication: Publication?
    private var policy: (enabled: Bool, generation: UInt64, domains: [String])?
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(bridge: BarcBridge, manager: ContentBlockerManager) {
        self.bridge = bridge; self.manager = manager
        observer = NotificationCenter.default.addObserver(forName: .adBlockerStateChanged, object: manager, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.synchronize() }
        }
        _ = synchronize()
    }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func stop() {
        stopped = true
        cancelApplicationPreparation()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        // Pending publications retain their bytes until native completion.
    }

    /// Publishes saved policy and rules without requiring any page or window.
    /// A source completion never changes the newer requested policy.
    @discardableResult func synchronize() -> Bool {
        guard !stopped, let manager else { return false }
        let enabled = manager.networkBlockingRequested, domains = manager.networkAllowedDomains
        let generation = enabled ? manager.networkSourceGeneration : 0
        guard !enabled || generation != 0 else { return false }
        if policy?.enabled != enabled || policy?.generation != generation || policy?.domains != domains {
            let strings = domains.map { strdup($0)! }
            defer { strings.forEach { free($0) } }
            let pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
            let requested = enabled ? BARC_BLOCKER_ENABLED : BARC_BLOCKER_DISABLED
            guard pointers.withUnsafeBufferPointer({ bridge.blocker_set_policy(requested.rawValue, generation, $0.baseAddress, $0.count) }) == 1 else { return false }
            guard !stopped, self.manager === manager,
                  manager.networkBlockingRequested == enabled, manager.networkAllowedDomains == domains,
                  (enabled ? manager.networkSourceGeneration : 0) == generation else { return false }
            policy = (enabled, generation, domains)
        }
        guard !stopped, self.manager === manager,
              manager.networkBlockingRequested == enabled, manager.networkAllowedDomains == domains,
              (enabled ? manager.networkSourceGeneration : 0) == generation else { return false }
        if enabled, let succeeded = manager.networkSourceSucceeded, publication?.generation != generation {
            let rules = succeeded ? manager.networkRules : nil
            guard !succeeded || rules != nil else { return false }
            let source = Publication(generation: generation, rules: rules)
            publication = source
            // Assign native arrival order synchronously. Completion only owns
            // source acceptance/lifetime; it never changes requested policy.
            Self.publish(source, bridge: bridge)
        }
        return true
    }

    private static let callback: BarcBlockerCallback = { pointer, revision, result in
        guard let pointer else { return }
        MainActor.assumeIsolated {
            let reply = Unmanaged<Reply>.fromOpaque(pointer).takeRetainedValue()
            reply.completion(revision, result)
        }
    }
    private static func publish(_ source: Publication, bridge: BarcBridge, failure: Bool = false) {
        let reply = Reply(source) { _, _ in }
        let pointer = Unmanaged.passRetained(reply).toOpaque()
        let accepted = bridge.blocker_publish_rules(failure ? nil : source.bytes?.bytes.assumingMemoryBound(to: UInt8.self),
            failure ? 0 : source.bytes?.length ?? 0,
            source.generation, callback, pointer)
        if accepted != 1 {
            let refused = Unmanaged<Reply>.fromOpaque(pointer).takeRetainedValue()
            refused.completion(0, Int32(BARC_BLOCKER_OWNER_ENDED.rawValue))
            // A rejected byte handoff must settle its announced requirement;
            // this one failure marker cannot qualify older accepted bytes.
            if !failure, source.bytes != nil { publish(source, bridge: bridge, failure: true) }
        }
    }
    private func prepareContext(_ window: Int32) async -> (UInt64, Int32, UInt64?) {
        await withCheckedContinuation { continuation in
            let reply = Reply { [weak self] revision, result in
                let context = result == Int32(BARC_BLOCKER_READY.rawValue) && self?.stopped == false
                    ? self?.state(window)?.context_id : nil
                continuation.resume(returning: (revision, result, context))
            }
            let pointer = Unmanaged.passRetained(reply).toOpaque()
            if bridge.blocker_prepare(window, Self.callback, pointer) != 1 {
                let refused = Unmanaged<Reply>.fromOpaque(pointer).takeRetainedValue()
                refused.completion(0, Int32(BARC_BLOCKER_OWNER_ENDED.rawValue))
            }
        }
    }
    private func state(_ window: Int32) -> BarcBlockerState? {
        var value = BarcBlockerState.sized
        guard bridge.blocker_state(window, &value) == 1, value.context_id != 0 else { return nil }
        return value
    }
    func prepare(in window: Int32) async -> Bool {
        while !Task.isCancelled && !stopped {
            guard let manager, synchronize() else { return false }
            let required = manager.networkBlockingRequested ? manager.networkSourceGeneration : 0
            // Native owns this wait, including a producer that is suspended or
            // validating. A disable releases it without awaiting that producer.
            let result = await prepareContext(window)
            guard !Task.isCancelled, !stopped else { return false }
            if result.1 == Int32(BARC_BLOCKER_READY.rawValue), result.2 != nil,
               state(window)?.context_id == result.2, isPrepared(in: window) { return true }
            let current = manager.networkBlockingRequested ? manager.networkSourceGeneration : 0
            if result.1 != Int32(BARC_BLOCKER_OWNER_ENDED.rawValue), current != required { continue }
            return false
        }
        return false
    }
    private func isPrepared(in window: Int32) -> Bool {
        guard !stopped, let manager, policy?.enabled == manager.networkBlockingRequested,
              policy?.domains == manager.networkAllowedDomains, let current = state(window), current.ready == 1,
              current.requested_policy == (manager.networkBlockingRequested ? BARC_BLOCKER_ENABLED : BARC_BLOCKER_DISABLED).rawValue else { return false }
        if !manager.networkBlockingRequested { return true }
        let generation = manager.networkSourceGeneration
        return generation != 0 && manager.networkSourceSucceeded == true &&
            policy?.generation == generation && current.required_source_generation == generation &&
            current.source_generation == generation && current.publication_revision != 0 &&
            current.installed_revision == current.publication_revision
    }

    func cancelApplicationPreparation() {
        let old = applicationPreparation; applicationPreparation = nil
        old?.task?.cancel() // Cancels this waiter, never the shared installation.
    }

    /// A pending page: ORDINARY_WINDOW holds the native-owned front, REFUSED refuses
    /// it, FOUND admits only the exact prepared page. A different still-live front
    /// cannot steal this slot.
    func admitApplicationPage(window: Int32, tab: Int32, session: any BlockablePage,
                              isPending: @escaping @MainActor () -> Bool,
                              canAdmit: @escaping @MainActor () -> Bool) -> Int32 {
        guard let manager, isPending(), canAdmit() else { return BARC_APPLICATION_TARGET_REFUSED.rawValue }
        if let current = applicationPreparation, !current.isPending() { cancelApplicationPreparation() }
        if let current = applicationPreparation {
            guard current.window == window, current.tab == tab else { return BARC_APPLICATION_TARGET_ORDINARY_WINDOW.rawValue }
            guard current.session === session else { return BARC_APPLICATION_TARGET_REFUSED.rawValue }
            if current.result != BARC_APPLICATION_TARGET_FOUND.rawValue { return current.result }
            if isPrepared(in: window), current.policy == manager.networkPolicy(for: session) {
                guard canAdmit(), applicationPreparation === current,
                      current.isPending(), current.session === session else { return BARC_APPLICATION_TARGET_REFUSED.rawValue }
                return BARC_APPLICATION_TARGET_FOUND.rawValue
            }
            guard applicationPreparation === current, current.isPending() else { return BARC_APPLICATION_TARGET_REFUSED.rawValue }
            cancelApplicationPreparation()
        }
        let request = ApplicationPreparation(window: window, tab: tab, session: session, isPending: isPending)
        let initialPolicy = manager.networkPolicy(for: session)
        applicationPreparation = request
        request.task = Task { @MainActor [weak self, weak request] in
            guard let self, let request else { return }
            let prepared = await self.prepare(in: window)
            guard !Task.isCancelled, self.applicationPreparation === request, request.isPending() else { return }
            request.result = BARC_APPLICATION_TARGET_REFUSED.rawValue
            guard let session = request.session, canAdmit(), let manager = self.manager else {
                // The exact intrinsic blank still belongs to this native front.
                // Publish only to wake terminal refusal, never to admit a load.
                if self.applicationPreparation === request, request.isPending() {
                    _ = self.apply(initialPolicy, window: window, tab: tab)
                }
                return
            }
            guard self.applicationPreparation === request, request.isPending(), !Task.isCancelled else { return }
            let policy = manager.networkPolicy(for: session)
            let ready = prepared && self.isPrepared(in: window)
            let published = self.apply(policy, window: window, tab: tab)
            // Publication posts the native non-nestable wake. Settle this state
            // synchronously before returning; there is no further await.
            if ready, published, self.applicationPreparation === request,
               request.isPending(), canAdmit(), self.isPrepared(in: window),
               manager.networkPolicy(for: session) == policy,
               self.applicationPreparation === request, request.isPending() {
                request.policy = policy
                request.result = BARC_APPLICATION_TARGET_FOUND.rawValue
            }
        }
        return BARC_APPLICATION_TARGET_ORDINARY_WINDOW.rawValue
    }

    @discardableResult func apply(to session: any BlockablePage, window: Int32, tab: Int32) -> Bool {
        guard let manager, synchronize(), isPrepared(in: window) else { return false }
        return apply(manager.networkPolicy(for: session), window: window, tab: tab)
    }

    @discardableResult func apply(_ policy: ContentBlockerManager.NetworkPagePolicy,
                                 window: Int32, tab: Int32) -> Bool {
        let remaining = max(0, policy.disabledUntil?.timeIntervalSinceNow ?? 0)
        let milliseconds = UInt64(min(remaining * 1_000, Double(UInt64.max).nextDown).rounded(.up))
        if let host = policy.continuedHost {
            return host.withCString { bridge.blocker_set_tab_policy(window, tab, policy.isOAuthFlow ? 1 : 0, $0, milliseconds) == 1 }
        }
        return bridge.blocker_set_tab_policy(window, tab, policy.isOAuthFlow ? 1 : 0, nil, milliseconds) == 1
    }
}
