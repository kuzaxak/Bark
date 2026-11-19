// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Tweaks.swift
//  Nook
//
//  Created by Bain Gurley on 17/09/2026.
//
//  Window and space work for Air Traffic Control.
//

import Foundation
import OSLog
import NookTabsCore
import NookTweaks
import NookWeb

private let tweaksLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SiteRouting")

extension BrowserManager: SiteRoutingHost {
    func submitTypedAddress(_ url: URL, from page: PageSession, in window: BrowserWindowState,
                            whileCurrent: () -> Bool) {
        guard let handle = window.window else { return }
        let space = window.spaceID
        func isCurrent() -> Bool {
            whileCurrent() && windowRegistry?.windows[window.id] === window &&
                windowRegistry?.activeWindow === window && window.window === handle &&
                CommandWindow.key === handle && window.spaceID == space && frontPage(in: window) === page
        }

        guard isCurrent() else { return }
        if !window.isIncognito, !page.isPrivate, !page.isAgentPage,
           siteRoutingManager.applyRoute(navigating: page.url, to: url, openInSpace: { target in
               guard target != space, tabs.space(target) != nil, isCurrent() else { return false }
               return tabs.open(url: url, in: window, placement: .newTab, parent: .tabs(spaceID: target)) != nil
           }) { return }
        guard isCurrent() else { return }
        page.load(url)
    }

    func route(url: URL, toSpace spaceID: UUID, from page: AnyObject?) -> Bool {
        guard tabs.space(spaceID) != nil else {
            tweaksLog.debug("Route skipped: target space \(spaceID) no longer exists")
            return false
        }
        guard let session = page as? PageSession else {
            let preferred = windowRegistry?.activeWindow
            guard let window = (preferred?.isIncognito == false ? preferred : nil)
                ?? tabs.regularWindows.first(where: { !$0.isIncognito && $0.spaceID != nil }) else { return false }
            tabs.open(url: url, in: window, placement: .newTab, parent: .tabs(spaceID: spaceID))
            return true
        }
        // An agent page stays in the Agent space: routing would show the person a new tab.
        guard !session.isPrivate, !session.isAgentPage else { return false }
        guard let window = tabs.window(for: session) ?? windowRegistry?.activeWindow,
              !window.isIncognito
        else { return false }
        // A page already in the target space loads in place.
        guard window.spaceID != spaceID else { return false }

        // Deferred: callers are WebKit policy callbacks. Selecting the new tab shows its space.
        Task { @MainActor [tabs] in
            tabs.open(url: url, in: window, placement: .newTab, parent: .tabs(spaceID: spaceID))
        }
        return true
    }

    func liveSpaceIDs() -> Set<UUID> {
        Set(tabs.orderedSpaces.map(\.id))
    }
}
