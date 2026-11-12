// Licensed under GPL-3.0. See LICENSE.

/// The parts of Settings that act only where their consumer exists. Bark hides the rest and keeps
/// their stored values.
public enum SettingsControl: CaseIterable {
    case quit, updates, sidebarVideo, tabs, peekOnShiftClick, peekFromLinkTargets, performance, search, siteSearch, urlShortcuts, wordStops
    case sidebarPosition, linkStatusPreview, hideBorder
    case renamePinnedTabs, linkPreviews, tidyDownloads
    case websiteShortcutDetection, iCloudSync

    public func isShown(chromium: Bool) -> Bool {
        guard chromium else { return true }
        switch self {
        // No Sparkle updater runs in the Chromium app.
        case .updates: return false
        // Moving a video to the sidebar goes through WebKit's picture in picture.
        case .sidebarVideo: return false
        // New-tab and cross-site links reach Peek only through WebKit's UI delegate.
        case .peekFromLinkTargets: return false
        // The engine always lays the sidebar out on the left.
        case .sidebarPosition: return false
        // Chromium draws its own link status bubble and the page's inset.
        case .linkStatusPreview, .hideBorder: return false
        // Pinning, Shift-hover and download naming reach these only through WebKit.
        case .renamePinnedTabs, .linkPreviews, .tidyDownloads: return false
        // Website shortcuts are detected in WebKit pages only.
        case .websiteShortcutDetection: return false
        // The Chromium app is not signed for iCloud.
        case .iCloudSync: return false
        case .quit, .tabs, .peekOnShiftClick, .performance, .search, .siteSearch, .urlShortcuts, .wordStops: return true
        }
    }
}
