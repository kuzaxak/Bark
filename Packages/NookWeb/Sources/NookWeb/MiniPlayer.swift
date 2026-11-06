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
    private var audible: Set<UUID> = []
    private var onScreen: Set<UUID> = []
    private var dismissed: UUID?

    public init() {}

    /// The page the bar shows; nil while it is hidden.
    public var itemID: UUID? {
        let ranked = started.sorted { $0.value > $1.value }.map(\.key)
        guard let latest = ranked.first, latest != dismissed else { return nil }
        return ranked.first { id in
            id != dismissed && !onScreen.contains(id) && (id == latest || audible.contains(id))
        }
    }

    /// The window's pages now; a page missing from them has closed or left the window.
    public mutating func update(_ pages: Set<MiniPlayerPage>) {
        let present = pages.filter { $0.hasMedia || $0.isAudible }
        let ids = Set(present.map(\.id))
        started = started.filter { ids.contains($0.key) }
        for page in present where page.isAudible && !audible.contains(page.id) {
            clock += 1
            started[page.id] = clock
        }
        audible = Set(present.filter(\.isAudible).map(\.id))
        onScreen = Set(present.filter(\.isOnScreen).map(\.id))
        if let dismissed, started[dismissed] == nil || onScreen.contains(dismissed) {
            self.dismissed = nil
        }
    }

    /// The page the sidebar's video was minimised from takes the bar.
    public mutating func takeOver(_ id: UUID) {
        clock += 1
        started[id] = clock
        if dismissed == id { dismissed = nil }
    }

    public mutating func dismiss() {
        dismissed = itemID
    }
}
