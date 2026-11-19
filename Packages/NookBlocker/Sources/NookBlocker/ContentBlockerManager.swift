// Licensed under GPL-3.0. See LICENSE.
//
//  ContentBlockerManager.swift
//  Nook
//
//  Builds Chromium network and cosmetic policy, with per-domain whitelist,
//  per-tab disable, and OAuth exemptions.
//

import Foundation
import Observation
import NookSettings
import OSLog

private let cbLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "ContentBlocker")

@MainActor
public final class ContentBlockerManager {
    public weak var host: ContentBlockerHost?
    private let settings: NookSettingsService
    public private(set) var isEnabled = false
    public private(set) var isCompiling = false

    private var nativeRequestedEnabled = false
    private var nativePolicyGeneration: UInt64 = 0
    private static var lastNativeSourceGeneration: UInt64 = 0
    /// Process-monotonic source intent, allocated before its bytes exist.
    public private(set) var networkSourceGeneration: UInt64 = 0
    /// Producer result (nil while pending), not native acceptance/readiness.
    public private(set) var networkSourceSucceeded: Bool?
    /// Last accepted serialized policy, not a claim of native installation.
    public private(set) var networkRules: BlockerEngine.NetworkRules?
    public private(set) var lastBuildSucceeded = false

    /// Requested network policy, including while its rules are still compiling.
    /// The native adapter holds first navigation until its exact context is ready.
    public var networkBlockingRequested: Bool {
        nativeRequestedEnabled && settings.adBlockerEnabled
    }

    public var networkAllowedDomains: [String] { allowedDomains.sorted() }

    public struct NetworkPagePolicy: Equatable, Sendable {
        public let isOAuthFlow: Bool
        public let continuedHost: String?
        public let disabledUntil: Date?
        public init(isOAuthFlow: Bool, continuedHost: String?, disabledUntil: Date?) {
            self.isOAuthFlow = isOAuthFlow
            self.continuedHost = continuedHost
            self.disabledUntil = disabledUntil
        }
    }

    /// Export existing exception authority without deciding against the old URL.
    /// Continuing a blocked target publishes before that navigation is started.
    public func networkPolicy(for session: any BlockablePage) -> NetworkPagePolicy {
        let until = temporarilyDisabledTabs[session.itemID]
        return NetworkPagePolicy(isOAuthFlow: session.isOAuthFlow,
            continuedHost: continuedHosts[session.itemID],
            disabledUntil: until.flatMap { $0 > Date() ? $0 : nil })
    }

    public init(settings: NookSettingsService, storageDirectory: URL) {
        self.settings = settings
        self.filterListManager = FilterListManager(directory: storageDirectory)
        self.engine = BlockerEngine(cacheFile: storageDirectory.appendingPathComponent("Cache/engine.dat"))
        // Seed persisted choices before the first policy is built or installed.
        allowedDomains = Set(settings.adBlockerWhitelist.map { $0.lowercased() })
        filterListManager.enabledOptionalFilterListFilenames = Set(settings.enabledOptionalFilterLists)
        observeNativeSettings()
    }

    public let filterListManager: FilterListManager
    public let engine: BlockerEngine
    public private(set) var trackingParamStripper = TrackingParamStripper()
    private var linkCleaningTask: Task<Void, Never>?
    private var urlSkipper: URLSkipper?

    /// In-flight activation; startup tab loading waits on it so the first page is protected.
    public private(set) var activationTask: Task<Void, Never>?
    private var hasActivated = false

    private var updateTimer: Timer?
    /// How often to look for due lists; each list's own `! Expires:` decides whether it is fetched.
    private static let updateCheckInterval: TimeInterval = 60 * 60

    // MARK: - Exceptions

    private var temporarilyDisabledTabs: [UUID: Date] = [:]
    private var allowedDomains: Set<String> = []
    /// Hosts a page continued to past the blocked-page card. Dropped when that page navigates to
    /// another host, so a redirector opens and its destination is blocked as usual.
    private var continuedHosts: [UUID: String] = [:]

    /// Lets `session` load `url`'s host unblocked until it navigates to another host.
    @discardableResult public func continueToBlockedPage(_ url: URL, in session: any BlockablePage) -> Bool {
        continuedHosts[session.itemID] = url.host?.lowercased()
        return session.applyNetworkBlockingPolicy(networkPolicy(for: session))
    }

    public func isTemporarilyDisabled(tabId: UUID) -> Bool {
        if let until = temporarilyDisabledTabs[tabId] {
            if until > Date() { return true }
            temporarilyDisabledTabs.removeValue(forKey: tabId)
        }
        return false
    }

    public func disableTemporarily(for session: any BlockablePage, duration: TimeInterval) {
        temporarilyDisabledTabs[session.itemID] = Date().addingTimeInterval(duration)
        reconcileAndReload(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak session] in
            guard let self, let session else { return }
            if let exp = self.temporarilyDisabledTabs[session.itemID], exp <= Date() {
                self.temporarilyDisabledTabs.removeValue(forKey: session.itemID)
                self.reconcileAndReload(session)
            }
        }
    }

    /// Saves the choice for every profile; `page` is the page it was made on, nil from Settings.
    @discardableResult public func allowDomain(_ host: String, allowed: Bool = true, from page: (any BlockablePage)?) -> Bool {
        guard page?.isPrivate != true else { return false }
        let norm = host.lowercased()
        if allowed { allowedDomains.insert(norm) } else { allowedDomains.remove(norm) }
        settings.adBlockerWhitelist = Array(allowedDomains)

        publishPolicyChange()
        for session in self.host?.blockablePages ?? [] {
            guard let h = session.blockingURL?.host?.lowercased(), h == norm || h.hasSuffix("." + norm) else { continue }
            reconcileAndReload(session, publishing: false)
        }
        return true
    }

    /// Whitelist matches the host and any subdomain of it.
    public func isDomainAllowed(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return allowedDomains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The site or tab is left alone by both the blocker and link cleaning.
    private func isSiteExempt(_ session: any BlockablePage, host: String?) -> Bool {
        isTemporarilyDisabled(tabId: session.itemID) || isDomainAllowed(host) || session.isOAuthFlow
            || (host != nil && continuedHosts[session.itemID] == host?.lowercased())
    }

    private func isExempt(_ session: any BlockablePage, host: String?) -> Bool {
        !isEnabled || !settings.adBlockerEnabled || isSiteExempt(session, host: host)
    }

    public func shouldApplyBlocking(to session: any BlockablePage) -> Bool {
        let host = session.blockingURL?.host
        if let continued = continuedHosts[session.itemID], continued != host?.lowercased() {
            continuedHosts[session.itemID] = nil
        }
        return !isExempt(session, host: host)
    }

    /// A native page start retires a continued-host exception after departure.
    /// OAuth changes use the same exact-page seam, without a global tab sweep.
    public func refreshNetworkPolicy(for session: any BlockablePage, navigationStarted: Bool = false) {
        if navigationStarted {
            let previousHost = continuedHosts[session.itemID]
            _ = shouldApplyBlocking(to: session)
            // Ordinary navigation retains the already-installed policy. Avoid
            // revising it and restarting pending native matches on every load.
            guard previousHost != continuedHosts[session.itemID] else { return }
        }
        session.applyNetworkBlockingPolicy(networkPolicy(for: session))
    }

    private func reconcileAndReload(_ session: any BlockablePage, publishing: Bool = true) {
        if publishing { publishPolicyChange() }
        if session.applyNetworkBlockingPolicy(networkPolicy(for: session)) {
            session.reloadForBlocking()
        }
    }

    // MARK: - Lifecycle

    public func attach(host: ContentBlockerHost) {
        self.host = host

        allowedDomains = Set(settings.adBlockerWhitelist.map { $0.lowercased() })
        filterListManager.enabledOptionalFilterListFilenames = Set(settings.enabledOptionalFilterLists)
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !nativeRequestedEnabled || (!isCompiling && !isEnabled) else { return }
            nativeRequestedEnabled = true
            startNativeBuild()
        } else {
            guard nativeRequestedEnabled || isEnabled || isCompiling || networkRules != nil else { return }
            nativeRequestedEnabled = false
            nativePolicyGeneration += 1
            activationTask?.cancel()
            activationTask = nil
            isCompiling = false
            networkRules = nil
            deactivateBlocking()
        }
    }

    private func observeNativeSettings() {
        withObservationTracking {
            _ = settings.adBlockerEnabled
            _ = settings.adBlockerWhitelist
            _ = settings.enabledOptionalFilterLists
        } onChange: { [weak self] in
            // Observation fires before the write. Requery once on the actor,
            // coalescing edits without polling or another policy store.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeNativeSettings()
                let domains = Set(self.settings.adBlockerWhitelist.map { $0.lowercased() })
                let lists = Set(self.settings.enabledOptionalFilterLists)
                let domainsChanged = self.allowedDomains != domains
                let listsChanged = self.filterListManager.enabledOptionalFilterListFilenames != lists
                self.allowedDomains = domains
                self.filterListManager.enabledOptionalFilterListFilenames = lists
                let generation = self.nativePolicyGeneration
                self.setEnabled(self.settings.adBlockerEnabled)
                if listsChanged, self.nativeRequestedEnabled,
                   self.nativePolicyGeneration == generation { self.startNativeBuild() }
                if domainsChanged { self.publishPolicyChange() }
            }
        }
    }

    private func publishPolicyChange() {
        NotificationCenter.default.post(name: .adBlockerStateChanged, object: self)
    }

    // Same activation task owns native enable/rebuild. A replacement invalidates
    // publication before any disk/network/engine await, including disable.
    private func beginNativeSource() {
        precondition(Self.lastNativeSourceGeneration < UInt64.max)
        Self.lastNativeSourceGeneration += 1
        networkSourceGeneration = Self.lastNativeSourceGeneration
        networkSourceSucceeded = nil
    }

    func startNativeBuild(refresh: Bool? = nil) {
        guard nativeRequestedEnabled else { return }
        nativePolicyGeneration += 1
        let generation = nativePolicyGeneration
        activationTask?.cancel()
        isCompiling = true
        let lists = Set(settings.enabledOptionalFilterLists)
        // A routine update check retains its accepted source. Explicit source
        // edits announce before production, even when downloads later no-op.
        let announceImmediately = refresh != false || networkSourceSucceeded != true ||
            lists != filterListManager.enabledOptionalFilterListFilenames
        filterListManager.enabledOptionalFilterListFilenames = lists
        if announceImmediately { beginNativeSource() }
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var announced = announceImmediately
            defer {
                if self.nativePolicyGeneration == generation {
                    self.isCompiling = false
                    // A changed saved intent is superseded; its existing
                    // observation will announce the replacement. Cancellation
                    // alone still fails a source that remains wanted.
                    if announced && self.networkSourceSucceeded == nil && self.networkBlockingRequested &&
                        Set(self.settings.enabledOptionalFilterLists) == lists {
                        self.networkSourceSucceeded = false
                        self.publishPolicyChange()
                    }
                }
            }
            guard self.nativeBuildIsCurrent(generation, lists: lists) else { return }
            if let refresh {
                let updated = await self.filterListManager.downloadAllLists(force: refresh)
                guard self.nativeBuildIsCurrent(generation, lists: lists) else { return }
                self.settings.adBlockerLastUpdate = Date()
                if !refresh, !updated, !announced {
                    self.isCompiling = false
                    self.publishPolicyChange()
                    return
                }
                if !announced {
                    self.beginNativeSource()
                    announced = true
                    self.publishPolicyChange()
                }
            }
            let built = await self.rebuild(nativeGeneration: generation, nativeLists: lists)
            guard self.nativeBuildIsCurrent(generation, lists: lists) else { return }
            self.isCompiling = false
            self.lastBuildSucceeded = built
            guard built, let rules = self.engine.networkRules else {
                self.networkSourceSucceeded = false
                self.publishPolicyChange()
                return
            }
            let firstActivation = !self.hasActivated
            self.networkRules = rules
            self.networkSourceSucceeded = true
            self.isEnabled = true
            self.hasActivated = true
            self.publishPolicyChange()
            guard self.nativeBuildIsCurrent(generation, lists: lists), self.isEnabled,
                  self.networkRules?.generation == rules.generation else { return }
            if firstActivation || refresh == nil { self.scheduleAutoUpdate() }
        }
        if announceImmediately { publishPolicyChange() }
    }

    private func nativeBuildIsCurrent(_ generation: UInt64, lists: Set<String>? = nil) -> Bool {
        nativeRequestedEnabled && settings.adBlockerEnabled && generation == nativePolicyGeneration &&
            !Task.isCancelled && (lists == nil || lists == Set(settings.enabledOptionalFilterLists))
    }

    // MARK: - Activation

    private func deactivateBlocking() {
        updateTimer?.invalidate()
        updateTimer = nil
        isEnabled = false
        publishPolicyChange()
        cbLog.info("Deactivated")
    }

    /// Load filter sources from disk or bundled snapshots for the native matcher.
    private func rebuild(nativeGeneration: UInt64, nativeLists: Set<String>) async -> Bool {
        let loadStart = CFAbsoluteTimeGetCurrent()
        let sources = await Task.detached(priority: .userInitiated) { [filterListManager] in
            filterListManager.loadFilterSources(enabledFilenames: nativeLists)
        }.value
        cbLog.info("Loaded \(sources.count) filter sources in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - loadStart), privacy: .public)s")

        // The three consumers share nothing but the input, and launch waits on all of them.
        let texts = sources.map(\.rules)
        let stripper = Task.detached(priority: .userInitiated) {
            TrackingParamStripper(rules: FilterLineSearch.lines(containing: "removeparam", in: texts))
        }
        let skipper = Task.detached(priority: .userInitiated) {
            URLSkipper(rules: FilterLineSearch.lines(containing: "urlskip=", in: texts))
        }
        guard nativeBuildIsCurrent(nativeGeneration, lists: nativeLists) else { return false }
        async let engineBuilt = engine.build(sources: sources, accepting: { [weak self] in
            self?.nativeBuildIsCurrent(nativeGeneration, lists: nativeLists) == true
        })

        let built = await engineBuilt
        let acceptedStripper = await stripper.value
        let acceptedSkipper = await skipper.value
        guard built, nativeBuildIsCurrent(nativeGeneration, lists: nativeLists) else { return false }
        trackingParamStripper = acceptedStripper
        urlSkipper = acceptedSkipper
        cbLog.info("urlskip: \(self.urlSkipper?.ruleCount ?? 0, privacy: .public) rules")
        return true
    }

    // MARK: - Filter List Updates

    /// Update filter lists from remote sources. Returns true if lists were updated and recompiled.
    @discardableResult
    public func updateFilterLists() async -> Bool {
        guard isEnabled, !isCompiling else { return false }
        let previous = networkRules?.generation
        startNativeBuild(refresh: false)
        await activationTask?.value
        return networkRules?.generation != previous
    }

    /// Force recompile after enabling or disabling an optional list.
    public func recompileFilterLists() async {
        guard nativeRequestedEnabled else { return }
        startNativeBuild(refresh: true)
        await activationTask?.value
    }

    private func scheduleAutoUpdate() {
        updateTimer?.invalidate()

        // Immediate check: only lists whose own expiry has elapsed are fetched (conditional GET).
        Task { await updateFilterLists() }

        updateTimer = Timer.scheduledTimer(withTimeInterval: Self.updateCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateFilterLists()
            }
        }
        updateTimer?.tolerance = 15 * 60
    }

    // MARK: - Tracking parameter removal ($removeparam)

    /// The URL with tracking parameters removed, or nil when nothing should change. Works with the
    /// blocker off once `prepareLinkCleaning()` has loaded the rules.
    public func strippedTrackingParams(for url: URL, tab session: any BlockablePage) -> URL? {
        guard !isSiteExempt(session, host: url.host), let stripped = trackingParamStripper.strip(url) else { return nil }
        cbLog.info("removeparam \(url.host ?? "-", privacy: .private(mask: .hash)): \(url.query?.count ?? 0, privacy: .public) -> \(stripped.query?.count ?? 0, privacy: .public) query chars")
        return stripped
    }

    /// Loads the `$removeparam` rules for link cleaning while the blocker, which otherwise loads
    /// them with everything else, is off.
    public func prepareLinkCleaning() {
        guard settings.removeTrackingFromLinks != .off, !isEnabled, !isCompiling,
              trackingParamStripper.ruleCount == 0, linkCleaningTask == nil else { return }
        let enabledFilenames = filterListManager.enabledOptionalFilterListFilenames
        linkCleaningTask = Task {
            let stripper = await Task.detached(priority: .utility) { [filterListManager] in
                let texts = filterListManager.loadFilterSources(enabledFilenames: enabledFilenames).map(\.rules)
                return TrackingParamStripper(rules: FilterLineSearch.lines(containing: "removeparam", in: texts))
            }.value
            if trackingParamStripper.ruleCount == 0 { trackingParamStripper = stripper }
            linkCleaningTask = nil
            cbLog.info("Link cleaning loaded \(stripper.ruleCount, privacy: .public) removeparam rules")
        }
    }

    /// Where a navigation to a known redirector really goes (`urlskip=`), or nil.
    public func urlSkipTarget(for url: URL, from source: URL?, tab session: any BlockablePage) -> URL? {
        guard isEnabled, !isExempt(session, host: url.host),
              let target = urlSkipper?.target(for: url, from: source) else { return nil }
        cbLog.info("urlskip \(url.host ?? "-", privacy: .private(mask: .hash)) -> \(target.host ?? "-", privacy: .private(mask: .hash))")
        return target
    }
}
