// Licensed under GPL-3.0. See LICENSE.
//
//  ContentBlockerManager.swift
//  Nook
//
//  Orchestrator for native ad blocking.
//  Manages enable/disable, per-domain whitelist, per-tab disable, OAuth exemption.
//  Three layers:
//  - Network blocking + simple element hiding: WKContentRuleList (native, out of process)
//  - Cosmetic rules the rule list cannot express (procedural filters):
//    AdvancedRulesEngine lookup + nook-cosmetic.js injected in every frame
//  - Site-specific blockers (YouTube, Facebook, X): bundled scripts, main frame only
//
//  Foundation + WebKit only; nothing here is AppKit-specific.
//

import Foundation
import Observation
import NookSettings
import WebKit
import OSLog

private let cbLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "ContentBlocker")

@MainActor
public final class ContentBlockerManager: NSObject {
    public weak var host: ContentBlockerHost?
    private var webKitHost: (any WebKitContentBlockerHost)? {
        guard !nativeNetworkBlocking else { return nil }
        return host as? any WebKitContentBlockerHost
    }
    private let settings: NookSettingsService
    public private(set) var isEnabled = false
    public private(set) var isCompiling = false

    private let nativeNetworkBlocking: Bool
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
        nativeNetworkBlocking && nativeRequestedEnabled && settings.adBlockerEnabled
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

    public init(settings: NookSettingsService, storageDirectory: URL? = nil,
                nativeNetworkBlocking: Bool = false) {
        precondition(!nativeNetworkBlocking || storageDirectory != nil,
                     "Native blocking requires an explicit app-owned cache directory")
        self.settings = settings
        self.nativeNetworkBlocking = nativeNetworkBlocking
        self.filterListManager = FilterListManager(directory: storageDirectory)
        let engine = storageDirectory.map { BlockerEngine(cacheFile: $0.appendingPathComponent("Cache/engine.dat")) }
            ?? BlockerEngine()
        self.advancedRulesEngine = AdvancedRulesEngine(engine: engine)
        super.init()
        if nativeNetworkBlocking {
            // Observation handles later edits; seed persisted choices before
            // the first native compilation or exported exception policy.
            allowedDomains = Set(settings.adBlockerWhitelist.map { $0.lowercased() })
            filterListManager.enabledOptionalFilterListFilenames = Set(settings.enabledOptionalFilterLists)
            observeNativeSettings()
        }
    }

    public let filterListManager: FilterListManager
    public let advancedRulesEngine: AdvancedRulesEngine
    public private(set) var trackingParamStripper = TrackingParamStripper()
    private var linkCleaningTask: Task<Void, Never>?
    private var urlSkipper: URLSkipper?
    private var lastRulesHash: String?

    /// In-flight activation; startup tab loading waits on it so the first page is protected.
    public private(set) var activationTask: Task<Void, Never>?
    private var hasActivated = false

    private var compiledRuleLists: [WKContentRuleList] = []
    /// The person's own cosmetic filters, compiled apart from the big lists.
    private var userRuleList: WKContentRuleList?
    private var userRuleGeneration = 0
    private var userRuleKey: String?
    private var activeRuleLists: [WKContentRuleList] { compiledRuleLists + (userRuleList.map { [$0] } ?? []) }
    private var updateTimer: Timer?
    /// How often to look for due lists; each list's own `! Expires:` decides whether it is fetched.
    private static let updateCheckInterval: TimeInterval = 60 * 60

    /// Webviews whose blocking has been removed (whitelisted domain, temporary disable, OAuth flow).
    private let exemptedWebViews = NSHashTable<WKWebView>.weakObjects()

    // MARK: - Exceptions

    private var temporarilyDisabledTabs: [UUID: Date] = [:]
    private var allowedDomains: Set<String> = []
    /// Hosts a page continued to past the blocked-page card. Dropped when that page navigates to
    /// another host, so a redirector opens and its destination is blocked as usual.
    private var continuedHosts: [UUID: String] = [:]

    /// Lets `session` load `url`'s host unblocked until it navigates to another host.
    @discardableResult public func continueToBlockedPage(_ url: URL, in session: any BlockablePage) -> Bool {
        continuedHosts[session.itemID] = url.host?.lowercased()
        return !nativeNetworkBlocking || session.applyNetworkBlockingPolicy(networkPolicy(for: session))
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

        if nativeNetworkBlocking { publishPolicyChange() }
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
        !isEnabled || (nativeNetworkBlocking && !settings.adBlockerEnabled) || isSiteExempt(session, host: host)
    }

    public func shouldApplyBlocking(to session: any BlockablePage) -> Bool {
        let host = session.blockingURL?.host
        if nativeNetworkBlocking, let continued = continuedHosts[session.itemID], continued != host?.lowercased() {
            continuedHosts[session.itemID] = nil
        }
        return !isExempt(session, host: host)
    }

    /// A native page start retires a continued-host exception after departure.
    /// OAuth changes use the same exact-page seam, without a global tab sweep.
    public func refreshNetworkPolicy(for session: any BlockablePage, navigationStarted: Bool = false) {
        guard nativeNetworkBlocking else { return }
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
        if nativeNetworkBlocking {
            if publishing { publishPolicyChange() }
            if session.applyNetworkBlockingPolicy(networkPolicy(for: session)) {
                session.reloadForBlocking()
            }
            return
        }
        guard let wv = session.webView else { return }
        reconcile(wv, exempt: !shouldApplyBlocking(to: session))
        session.reloadForBlocking()
    }

    // MARK: - Lifecycle

    public func attach(host: ContentBlockerHost) {
        self.host = host

        allowedDomains = Set(settings.adBlockerWhitelist.map { $0.lowercased() })
        filterListManager.enabledOptionalFilterListFilenames = Set(settings.enabledOptionalFilterLists)

        // Every new user content controller gets the reply handler (always) and rule lists (when enabled).
        webKitHost?.onNewUserContentController { [weak self] controller in
            self?.configureNewController(controller)
        }
    }

    public func setEnabled(_ enabled: Bool) {
        if nativeNetworkBlocking {
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
            return
        }
        cbLog.info("setEnabled(\(enabled)) — current isEnabled=\(self.isEnabled)")
        guard enabled != isEnabled, !isCompiling else { return }
        if enabled {
            isCompiling = true  // set synchronously so a second setEnabled(true) before the Task starts is a no-op
            activationTask = Task { @MainActor in await activateBlocking() }
        } else {
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
        guard nativeNetworkBlocking, nativeRequestedEnabled else { return }
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
            guard built, let rules = self.advancedRulesEngine.engine.networkRules else {
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

    private func activateBlocking() async {
        let start = CFAbsoluteTimeGetCurrent()
        isCompiling = true

        // The person's zaps load beside the big lists, so the first page already has them.
        Task { [settings] in
            await settings.waitForBoosts()
            await setUserCosmeticRules(Boost.zapFilterLines(settings.boosts))
        }

        // Bundled snapshots of every default list guarantee rules on first run; the
        // network refresh happens afterwards via scheduleAutoUpdate().
        await rebuild()

        isCompiling = false
        isEnabled = true
        applyToSharedConfiguration()
        // Later activations are a Settings toggle: those pages were loaded unblocked on purpose.
        let isFirstActivation = !hasActivated
        hasActivated = true
        applyToExistingWebViews(reloadingPagesLoadedWithoutBlocking: isFirstActivation)
        NotificationCenter.default.post(name: .adBlockerStateChanged, object: nil)
        scheduleAutoUpdate()

        cbLog.info("Activated with \(self.compiledRuleLists.count) rule list(s) in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start), privacy: .public)s")
    }

    private func deactivateBlocking() {
        updateTimer?.invalidate()
        updateTimer = nil
        isEnabled = false
        removeFromSharedConfiguration()
        removeFromExistingWebViews()
        if nativeNetworkBlocking { publishPolicyChange() }
        else { NotificationCenter.default.post(name: .adBlockerStateChanged, object: nil) }
        cbLog.info("Deactivated")
    }

    /// Load rules (disk cache, else bundled snapshot), compile rule lists, build the advanced engine.
    @discardableResult
    private func rebuild(nativeGeneration: UInt64? = nil, nativeLists: Set<String>? = nil) async -> Bool {
        let loadStart = CFAbsoluteTimeGetCurrent()
        let enabledFilenames = nativeLists ?? filterListManager.enabledOptionalFilterListFilenames
        let native = nativeNetworkBlocking
        let (sources, rules) = await Task.detached(priority: .userInitiated) { [filterListManager] in
            let sources = filterListManager.loadFilterSources(enabledFilenames: enabledFilenames)
            return (sources, native ? [] : FilterListManager.lines(from: sources))
        }.value
        cbLog.info("Loaded \(sources.count) filter sources in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - loadStart), privacy: .public)s")

        // The four consumers share nothing but the input, and launch waits on all of them.
        let compileStart = CFAbsoluteTimeGetCurrent()
        let texts = sources.map(\.rules)
        let stripper = Task.detached(priority: .userInitiated) {
            TrackingParamStripper(rules: FilterLineSearch.lines(containing: "removeparam", in: texts))
        }
        let skipper = Task.detached(priority: .userInitiated) {
            URLSkipper(rules: FilterLineSearch.lines(containing: "urlskip=", in: texts))
        }
        if let nativeGeneration, !nativeBuildIsCurrent(nativeGeneration, lists: nativeLists) { return false }
        let accept: (@MainActor () -> Bool)? = nativeGeneration.map { generation in
            { [weak self] in self?.nativeBuildIsCurrent(generation, lists: nativeLists) == true }
        }
        async let engineBuilt = advancedRulesEngine.build(sources: sources,
            exportingNetworkRules: native, accepting: accept)
        let result = native ? nil : await ContentRuleListCompiler.compile(rules: rules)
        cbLog.info("Compile completed in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - compileStart), privacy: .public)s")

        let built = await engineBuilt
        let acceptedStripper = await stripper.value
        let acceptedSkipper = await skipper.value
        if let nativeGeneration, !nativeBuildIsCurrent(nativeGeneration, lists: nativeLists) { return false }
        if native, !built { return false }
        if let result { compiledRuleLists = result.ruleLists }
        trackingParamStripper = acceptedStripper
        urlSkipper = acceptedSkipper
        cbLog.info("urlskip: \(self.urlSkipper?.ruleCount ?? 0, privacy: .public) rules")
        lastRulesHash = result?.rulesHash
        return true
    }

    // MARK: - Filter List Updates

    /// Update filter lists from remote sources. Returns true if lists were updated and recompiled.
    @discardableResult
    public func updateFilterLists() async -> Bool {
        if nativeNetworkBlocking {
            guard isEnabled, !isCompiling else { return false }
            let previous = networkRules?.generation
            startNativeBuild(refresh: false)
            await activationTask?.value
            return networkRules?.generation != previous
        }
        guard isEnabled, !isCompiling else { return false }
        isCompiling = true
        defer { isCompiling = false }

        let updated = await filterListManager.downloadAllLists()
        if updated {
            await rebuild()
            applyToSharedConfiguration()
            applyToExistingWebViews()
            cbLog.info("Filter lists updated and recompiled")
        }
        settings.adBlockerLastUpdate = Date()
        return updated
    }

    /// Force recompile (e.g. after enabling/disabling an optional list).
    public func recompileFilterLists() async {
        if nativeNetworkBlocking {
            guard nativeRequestedEnabled else { return }
            startNativeBuild(refresh: true)
            await activationTask?.value
            return
        }
        guard isEnabled, !isCompiling else { return }
        isCompiling = true
        defer { isCompiling = false }

        await filterListManager.downloadAllLists(force: true)
        await rebuild()
        applyToSharedConfiguration()
        applyToExistingWebViews()
        settings.adBlockerLastUpdate = Date()
        NotificationCenter.default.post(name: .adBlockerStateChanged, object: nil)
        cbLog.info("Filter lists recompiled")
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

    /// Replaces the person's own cosmetic filters (`host##selector` lines). Only this small list
    /// is compiled; the filter lists stay as they are.
    /// Returns false when the compile failed, so the caller can retry. A call overtaken by a
    /// newer one changes nothing.
    @discardableResult
    public func setUserCosmeticRules(_ lines: [String]) async -> Bool {
        // Native cosmetic/scriptlet transport is separate; never invoke a WK
        // compiler or pretend a native cosmetic replacement was installed.
        guard !nativeNetworkBlocking else { return lines.isEmpty }
        // Empty to empty: nothing in the store, nothing to apply.
        if userRuleList == nil, ContentRuleListCompiler.userListIsAbsent(for: lines) { return true }
        let key = ContentRuleListCompiler.userKey(lines)
        if key == userRuleKey { return true }
        userRuleGeneration += 1
        let generation = userRuleGeneration
        let result = await ContentRuleListCompiler.compileUser(rules: lines)
        guard generation == userRuleGeneration else { return true }
        if result.ok { userRuleKey = key }
        let changed = result.list !== userRuleList
        userRuleList = result.list
        if changed, isEnabled, host != nil {
            applyToSharedConfiguration()
            applyToExistingWebViews()
        }
        return result.ok
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

    // MARK: - Per-Navigation (main frame, from PageSession.decidePolicyFor)

    public func setupContentBlockerScripts(for url: URL, in webView: WKWebView, tab session: any BlockablePage) {
        guard !nativeNetworkBlocking else { return }
        if let continued = continuedHosts[session.itemID], continued != url.host?.lowercased() {
            continuedHosts[session.itemID] = nil
        }
        guard isEnabled else { return }
        setupContentBlockerScripts(for: url, in: webView, exempt: isExempt(session, host: url.host))
    }

    private func setupContentBlockerScripts(for url: URL, in webView: WKWebView, exempt: Bool) {
        reconcile(webView, exempt: exempt)
        // Empty until the Boosts have loaded; the style script's own lookup covers that page.
        let boostCSS = settings.boostsLoaded ? Boost.css(for: url, in: settings.boosts) : ""
        let config = exempt ? nil : advancedRulesEngine.configUserScript(for: url, boostCSS: boostCSS)
        replaceConfigScript(in: webView.configuration.userContentController, with: config)
        cbLog.info("main frame \(url.host ?? "-", privacy: .private(mask: .hash)): exempt=\(exempt) config=\(config?.source.count ?? 0, privacy: .public)B ruleLists=\(self.compiledRuleLists.count)")
    }

    /// Swap the main-frame configuration script. It must precede the runtime script, so it goes first.
    private func replaceConfigScript(in ucc: WKUserContentController, with script: WKUserScript?) {
        let marker = AdvancedRulesEngine.configScriptMarker
        // `userScripts` is bridged lazily from WebKit's NSArray; evaluate everything we need from it
        // BEFORE removeAllUserScripts(), or the stale proxy traps on the next index read (Release-only crash).
        let all = ucc.userScripts
        // Only Nook's own scripts are re-added; see WKUserScript+NookOwned.
        let others = all.nookOwned.filter { !$0.source.hasPrefix(marker) }
        let current = all.first { $0.source.hasPrefix(marker) }?.source

        // Nothing changed, so leave the list alone. WKUserContentController has no
        // remove-one API, so any edit costs one addUserScript IPC per surviving
        // script. configUserScript never returns nil, so the old `script != nil`
        // test was always true and this rewrote the whole list on every
        // navigation, which froze redirect-heavy sites. The tweak managers have
        // always compared content here; this one did not.
        guard current != script?.source else { return }

        ucc.removeAllUserScripts()
        if let script { ucc.addUserScript(script) }
        others.forEach { ucc.addUserScript($0) }
    }

    // MARK: - New controllers (from BrowserConfiguration.freshUserContentController)

    private func configureNewController(_ controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: AdvancedRulesEngine.messageHandlerName)
        guard isEnabled else { return }
        for list in activeRuleLists { controller.add(list) }
        // Static scripts arrive by copy from the shared configuration.
    }

    // MARK: - Shared Configuration

    private func applyToSharedConfiguration() {
        guard let ucc = webKitHost?.sharedUserContentController else { return }
        ucc.removeAllContentRuleLists()
        for list in activeRuleLists { ucc.add(list) }
        ensureStaticScripts(in: ucc)
    }

    private func removeFromSharedConfiguration() {
        guard let ucc = webKitHost?.sharedUserContentController else { return }
        ucc.removeAllContentRuleLists()
        removeOwnScripts(from: ucc)
    }

    // MARK: - Per-WebView

    private func reconcile(_ webView: WKWebView, exempt: Bool) {
        let isExempt = exemptedWebViews.contains(webView)
        if exempt && !isExempt {
            removeBlocking(from: webView)
        } else if !exempt && isExempt {
            applyBlocking(to: webView)
        }
    }

    private func applyBlocking(to webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        for list in activeRuleLists { ucc.add(list) }
        ensureStaticScripts(in: ucc)
        exemptedWebViews.remove(webView)
    }

    private func removeBlocking(from webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        removeOwnScripts(from: ucc)
        exemptedWebViews.add(webView)
    }

    /// A page that committed before blocking was ready can only be fixed by reloading it:
    /// rule lists are evaluated at navigation time and document-start scripts have already run.
    private func applyToExistingWebViews(reloadingPagesLoadedWithoutBlocking reloading: Bool = false) {
        guard !nativeNetworkBlocking else { return }
        for session in self.host?.blockablePages ?? [] {
            guard let wv = session.webView else { continue }
            // Exempt pages (allowlist, per-tab off, OAuth) loaded as intended; never reload them.
            guard shouldApplyBlocking(to: session) else { removeBlocking(from: wv); continue }
            applyBlocking(to: wv)
            guard reloading, let url = wv.url, url.scheme != "about" else { continue }
            wv.reload()
        }
    }

    private func removeFromExistingWebViews() {
        guard !nativeNetworkBlocking else { return }
        for session in self.host?.blockablePages ?? [] {
            guard let wv = session.webView else { continue }
            removeBlocking(from: wv)
        }
        exemptedWebViews.removeAllObjects()
    }

    private func ensureStaticScripts(in ucc: WKUserContentController) {
        let marker = AdvancedRulesEngine.scriptMarker
        guard !ucc.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        AdvancedRulesEngine.staticUserScripts.forEach { ucc.addUserScript($0) }
    }

    private func removeOwnScripts(from ucc: WKUserContentController) {
        let markers = [AdvancedRulesEngine.scriptMarker, AdvancedRulesEngine.configScriptMarker]
        let all = ucc.userScripts
        let ours = all.nookOwned
        let remaining = ours.filter { script in !markers.contains { script.source.hasPrefix($0) } }
        guard remaining.count != ours.count else { return }
        ucc.removeAllUserScripts()
        remaining.forEach { ucc.addUserScript($0) }
    }

    private func session(for webView: WKWebView) -> (any BlockablePage)? {
        webKitHost?.blockablePage(for: webView)
    }
}

// MARK: - Subframe lookups (nook-cosmetic.js asks by its own frame URL)

extension ContentBlockerManager: WKScriptMessageHandlerWithReply {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard isEnabled, let webView = message.webView else { replyHandler(nil, nil); return }

        let body = message.body as? [String: Any]
        let frameURL = message.frameInfo.request.url
            ?? (body?["url"] as? String).flatMap { URL(string: $0) }
        guard let pageUrl = frameURL, let scheme = pageUrl.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            replyHandler(nil, nil); return
        }

        let topUrl = webView.url
        if let session = session(for: webView) {
            if isExempt(session, host: topUrl?.host) { replyHandler(nil, nil); return }
        } else if isDomainAllowed(topUrl?.host) {
            replyHandler(nil, nil); return
        }

        let conf = advancedRulesEngine.configuration(for: pageUrl, topUrl: message.frameInfo.isMainFrame ? nil : topUrl)
        cbLog.info("frame lookup \(pageUrl.host ?? "-", privacy: .private(mask: .hash)) main=\(message.frameInfo.isMainFrame) rules=\(conf == nil ? 0 : 1, privacy: .public)")
        replyHandler(conf, nil)
    }
}
