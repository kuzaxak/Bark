// Licensed under GPL-3.0. See LICENSE.
//
//  MiniPlayer.swift
//  NookWeb
//
//  The sidebar's mini player, as Arc's: which of a window's pages it controls. Foundation only.
//

import Foundation

/// A page as the mini player sees it.
public struct MiniPlayerPage: Hashable, Sendable {
    public let id: UUID
    /// The page holds audio or video, playing or paused.
    public let hasMedia: Bool
    /// The page plays sound. A muted clip looping on a news page does not.
    public let isAudible: Bool
    /// The window shows the page, in any of its panes.
    public let isOnScreen: Bool

    public init(id: UUID, hasMedia: Bool, isAudible: Bool, isOnScreen: Bool) {
        self.id = id
        self.hasMedia = hasMedia
        self.isAudible = isAudible
        self.isOnScreen = isOnScreen
    }
}

/// One window's mini player. The page that last started playing sound holds it, playing or
/// paused, until the page closes or loses its media, and it shows while that page is off screen;
/// while it is on screen, the newest page still playing off screen shows instead. Dismissing
/// hides it until another page starts playing, or the dismissed page has been on screen.
public struct MiniPlayer: Equatable, Sendable {
    /// When each page last started playing; the newest has the highest.
    private var started: [UUID: Int] = [:]
    private var clock = 0
    private var present: Set<UUID> = []
    private var audible: Set<UUID> = []
    private var onScreen: Set<UUID> = []
    private var dismissed: UUID?

    public init() {}

    /// The page that last started playing, shown or not.
    public var latest: UUID? {
        started.max { $0.value < $1.value }?.key
    }

    /// The page the bar shows; nil while it is hidden.
    public var itemID: UUID? {
        let ranked = started.sorted { $0.value > $1.value }.map(\.key)
        guard let latest = ranked.first, latest != dismissed else { return nil }
        return ranked.first { id in
            id != dismissed && !onScreen.contains(id) && (id == latest || audible.contains(id))
        }
    }

    /// The window's pages now, in any order; a page missing from them has closed or left the
    /// window. Pages that start playing together take the bar in the order of their ids.
    public mutating func update(_ pages: [MiniPlayerPage]) {
        let pages = pages.filter { $0.hasMedia || $0.isAudible }.sorted { $0.id.uuidString < $1.id.uuidString }
        present = Set(pages.map(\.id))
        started = started.filter { present.contains($0.key) }
        for page in pages where page.isAudible && !audible.contains(page.id) {
            clock += 1
            started[page.id] = clock
        }
        audible = Set(pages.filter(\.isAudible).map(\.id))
        onScreen = Set(pages.filter(\.isOnScreen).map(\.id))
        if let dismissed, started[dismissed] == nil || onScreen.contains(dismissed) {
            self.dismissed = nil
        }
    }

    /// The page the sidebar's video was minimised from takes the bar, when it is one of the
    /// window's pages with media.
    public mutating func takeOver(_ id: UUID) {
        guard present.contains(id) else { return }
        clock += 1
        started[id] = clock
        if dismissed == id { dismissed = nil }
    }

    public mutating func dismiss() {
        dismissed = itemID
    }
}
