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
import NookTabsCore
import NookTweaks
import NookWeb

extension BrowserManager {
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
}
