// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+NookWeb.swift
//  Nook
//
//  AppKit host callbacks for the tab model and its live pages.
//

import AppKit
import NookWeb

// MARK: - PageSessionDelegate

extension BrowserManager: PageSessionDelegate {
    func presentPeek(url: URL, from session: PageSession) {
        peekManager.presentExternalURL(url, from: session)
    }

    func cleanupZoom(for itemID: UUID) { cleanupZoomForTab(itemID) }

    func setMuteState(_ muted: Bool, for itemID: UUID) {}
}

// MARK: - TabEventObserver

extension BrowserManager: TabEventObserver {
    func tabActivated(new session: PageSession, previous: PageSession?) {
        zoomManager.showZoomLevel(for: session.itemID)
        session.sampleNativeTopBarColor()
    }
}
