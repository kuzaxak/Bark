// Licensed under GPL-3.0. See LICENSE.

import Foundation

@MainActor
public protocol PageSessionDelegate: AnyObject {
    /// Fallback profile for a legacy session without a per-page profile.
    var currentProfile: Profile? { get }
    func windowSpaceChanged(_ window: BrowserWindowState)
    func presentPeek(url: URL, from session: PageSession)
    func cleanupZoom(for itemID: UUID)
    func setMuteState(_ muted: Bool, for itemID: UUID)
}

/// What a window's picture-in-picture (`BrowserWindowState.sidebarPiPStorage`) shows, so the tab
/// model counts that page as on screen.
@MainActor
public protocol PictureInPictureHolder: AnyObject {
    var pictureInPictureItemID: UUID? { get }
}
