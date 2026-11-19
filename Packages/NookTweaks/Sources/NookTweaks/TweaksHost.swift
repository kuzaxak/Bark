// Licensed under GPL-3.0. See LICENSE.
//
//  TweaksHost.swift
//  NookTweaks
//
//  Created by Bain Gurley on 17/09/2026.
//
import Foundation

/// Air Traffic Control hands the app a matched rule and lets it do the window and space work.
/// `page` is a `PageSession` on the app side; this package never looks inside it.
@MainActor public protocol SiteRoutingHost: AnyObject {
    /// Open `url` as a new tab in `spaceID`, in the window showing `page`, or the active window
    /// when `page` is nil (external URLs). False when nothing was opened: a private or incognito
    /// window, no window at all, a space that is gone, or a window already showing that space.
    /// The open itself may be deferred: callers are WebKit policy callbacks.
    func route(url: URL, toSpace spaceID: UUID, from page: AnyObject?) -> Bool

    /// The spaces that exist now, used to drop rules whose target was merged away.
    func liveSpaceIDs() -> Set<UUID>
}
