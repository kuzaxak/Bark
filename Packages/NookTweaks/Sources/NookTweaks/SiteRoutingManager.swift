// Licensed under GPL-3.0. See LICENSE.
//
//  SiteRoutingManager.swift
//  Nook
//

import Foundation
import NookBlocker
import NookSettings
import OSLog

@MainActor
public final class SiteRoutingManager {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SiteRouting")

    private let settings: NookSettingsService

    public init(settings: NookSettingsService) {
        self.settings = settings
    }

    // MARK: - Matching

    public func resolve(url: URL) -> SiteRoutingRule? {
        SiteRoutingRule.best(for: url, in: settings.siteRoutingRules)
    }

    /// Apply a typed route through the caller that owns the editing window.
    public func applyRoute(navigating current: URL?, to url: URL, openInSpace: (UUID) -> Bool) -> Bool {
        func site(_ url: URL?) -> String {
            let host = url?.host?.lowercased() ?? ""
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let from = site(current), to = site(url)
        guard !from.isEmpty, !to.isEmpty, from != to, !OAuthDetector.isLikelyOAuthURL(url) else { return false }
        return applyRule(to: url, openInSpace)
    }

    private func applyRule(to url: URL, _ route: (UUID) -> Bool) -> Bool {
        guard let rule = resolve(url: url), route(rule.targetSpaceId) else { return false }
        logger.info("Route matched: \(url.host ?? "", privacy: .public) → space \(rule.targetSpaceId, privacy: .public)")
        return true
    }

    // MARK: - CRUD

    public func addRule(_ rule: SiteRoutingRule) {
        settings.siteRoutingRules.append(rule)
    }

    public func updateRule(_ rule: SiteRoutingRule) {
        guard let index = settings.siteRoutingRules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.siteRoutingRules[index] = rule
    }

    public func deleteRule(id: UUID) {
        settings.siteRoutingRules.removeAll(where: { $0.id == id })
    }

    public func rules() -> [SiteRoutingRule] {
        settings.siteRoutingRules
    }

    // MARK: - Migration

    /// Rules used to name a space and a profile. A space that was merged away is no longer live,
    /// and the space that took over its login is the one the old profile id names, so that becomes
    /// the target. Rules pointing nowhere are dropped. Runs once per launch and writes only when
    /// something changed.
    public func dropMergedProfileTargets(liveSpaceIDs live: Set<UUID>) {
        var changed = false
        let updated = settings.siteRoutingRules.compactMap { rule -> SiteRoutingRule? in
            guard !live.contains(rule.targetSpaceId) else { return rule }
            guard let heir = rule.legacyProfileId, live.contains(heir) else {
                logger.info("Dropping routing rule for \(rule.domain, privacy: .public): its space is gone")
                changed = true
                return nil
            }
            changed = true
            var moved = rule
            moved.targetSpaceId = heir
            moved.legacyProfileId = nil
            return moved
        }
        guard changed else { return }
        settings.siteRoutingRules = updated
    }
}
