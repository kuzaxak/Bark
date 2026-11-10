// Licensed under GPL-3.0. See LICENSE.

/// The parts of Settings > General. A part shows only where its settings take effect.
enum GeneralSettingsSection: CaseIterable {
    case quit, updates, sidebarVideo, tabs, peekOnShiftClick, peekFromLinkTargets, performance, search, siteSearch, urlShortcuts, wordStops

    func isShown(chromium: Bool) -> Bool {
        guard chromium else { return true }
        switch self {
        // No Sparkle updater runs in the Chromium app.
        case .updates: return false
        // Moving a video to the sidebar goes through WebKit's picture in picture.
        case .sidebarVideo: return false
        // New-tab and cross-site links reach Peek only through WebKit's UI delegate.
        case .peekFromLinkTargets: return false
        case .quit, .tabs, .peekOnShiftClick, .performance, .search, .siteSearch, .urlShortcuts, .wordStops: return true
        }
    }
}
