// Licensed under GPL-3.0. See LICENSE.
//
//  YouTubeTweaks.swift
//  Nook
//
//  Created by Bain Gurley on 15/09/2026.
//

import Foundation
import NookSettings

/// The selectors each hideable home shelf is matched by. The enum itself lives in NookSettings.
extension YouTubeHomeSection {
    fileprivate static let shorts = "ytm-shorts-lockup-view-model, ytm-shorts-lockup-view-model-v2"
    fileprivate static let postItems = "ytd-post-renderer, ytd-backstage-post-thread-renderer"
    fileprivate static let gameItems = "ytd-mini-game-card-view-model, ytd-game-card-renderer"

    fileprivate var selector: String {
        switch self {
        case .posts:
            return "ytd-rich-section-renderer:has(\(Self.postItems))"
        case .playables:
            return "ytd-rich-section-renderer:has(\(Self.gameItems))"
        case .otherShelves:
            // Shorts, posts, and playables keep their own toggles.
            return "ytd-rich-section-renderer:has(ytd-rich-shelf-renderer):not(:has(\(Self.shorts), \(Self.postItems), \(Self.gameItems)))"
        case .surveys:
            return "ytd-rich-section-renderer:has(ytd-inline-survey-renderer, ytd-statement-banner-renderer, ytd-brand-video-shelf-renderer)"
        case .filterChips:
            return "ytd-feed-filter-chip-bar-renderer"
        }
    }
}

@MainActor
public enum YouTubeTweaks {
    public static let videosPerRowRange = 3...8

    private static let shortsSelectors = [
        "ytd-rich-section-renderer:has(\(YouTubeHomeSection.shorts))",  // home shelf
        "grid-shelf-view-model:has(\(YouTubeHomeSection.shorts))",  // search shelf
        "ytd-reel-shelf-renderer",
        "ytd-rich-item-renderer:has(a[href^=\"/shorts/\"])",  // subscriptions feed
        "ytd-video-renderer:has(a[href^=\"/shorts/\"])",  // search results
        "yt-lockup-view-model:has(a[href^=\"/shorts/\"])",  // watch page sidebar
        "ytd-guide-entry-renderer:has(a[href^=\"/shorts\"])",
        "ytd-mini-guide-entry-renderer:has(a[href^=\"/shorts\"])",
        "yt-tab-shape[tab-title=\"Shorts\"]",  // channel tab; English UI only
    ]

    /// One rule per selector: an unknown selector in a list would drop the whole rule.
    static func css(for settings: NookSettingsService) -> String {
        var hidden: [String] = []
        if settings.youTubeHideShorts { hidden += shortsSelectors }
        hidden += settings.youTubeHiddenHomeSections
            .compactMap(YouTubeHomeSection.init(rawValue:))
            .map { "ytd-browse[page-subtype=\"home\"] \($0.selector)" }

        var rules = hidden.map { "\($0) { display: none !important; }" }
        if settings.youTubeHiddenHomeSections.contains(YouTubeHomeSection.filterChips.rawValue) {
            // The masthead backdrop stays sized for the chip bar and would cover the first row.
            rules.append("ytd-app:has(ytd-browse[page-subtype=\"home\"]:not([hidden])) #frosted-glass.with-chipbar { height: var(--ytd-masthead-height, 56px) !important; }")
        }

        let perRow = settings.youTubeVideosPerRow
        if videosPerRowRange.contains(perRow) {
            // Grids on home, subscriptions, and channel pages. YouTube sets these inline from window width.
            rules.append("ytd-rich-grid-renderer { --ytd-rich-grid-items-per-row: \(perRow) !important; --ytd-rich-grid-posts-per-row: \(perRow) !important; }")
        }
        if settings.youTubeNoHoverPreview {
            // Backstop if a preview starts anyway.
            rules.append("ytd-video-preview { display: none !important; }")
        }
        if settings.youTubeFrameThumbnails {
            // Frames are 4:3 with letterboxing; cover crops them back to the 16:9 picture.
            rules.append("img[data-nook-frame] { width: 100% !important; height: 100% !important; object-fit: cover !important; }")
        }
        return rules.joined(separator: "\n")
    }
}
