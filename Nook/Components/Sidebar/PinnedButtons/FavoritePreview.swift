// Licensed under GPL-3.0. See LICENSE.
//
//  FavoritePreview.swift
//  Nook
//
//  The card under a favorite the pointer rests on: on github.com, the person's open pull
//  requests. Nothing is fetched until the pointer rests. Gmail and Google Calendar favorites
//  get their card beside the tile instead (LiveFavorites).
//

import AppKit
import SwiftUI
import NookDesign
import NookTabsCore
import NookUI
import NookWeb

@MainActor
@Observable
final class FavoritePreview {
    static let shared = FavoritePreview()

    struct Row: Identifiable, Hashable {
        let url: URL
        let title: String
        var id: URL { url }
    }

    /// The favorite whose card is up and the window showing it.
    private(set) var itemID: UUID?
    private(set) var windowID: UUID?
    private(set) var rows: [Row] = []
    /// A Gmail or Calendar favorite's card, which shows live data instead of rows.
    private(set) var live: GoogleFavorite?

    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var tileUnderPointer: UUID?
    @ObservationIgnored private var pointerOverCard = false
    fileprivate struct Source: Equatable {
        let itemID: UUID
        let spaceID: UUID
        let profileID: UUID
        let url: URL
    }
    fileprivate var source: Source?
    @ObservationIgnored private var cache: [UUID: (at: Date, rows: [Row], source: Source)] = [:]

    fileprivate static func source(for item: Item, tabs: TabsController) -> Source? {
        guard let url = item.url, tabs.item(item.id)?.url == url,
              let space = tabs.spaceID(of: item.id), let profile = tabs.tree.dataStoreID(for: space),
              tabs.isProfileAvailable(profile) else { return nil }
        return Source(itemID: item.id, spaceID: space, profileID: profile, url: url)
    }
    func isCurrent(in window: BrowserWindowState, tabs: TabsController) -> Bool {
        guard tabs.windowRegistry.windows[window.id] === window, windowID == window.id,
              let itemID, let item = tabs.item(itemID),
              let source, window.spaceID == source.spaceID,
              !(tabs.profileEngine == .chromium && window.isIncognito) else { return false }
        return Self.source(for: item, tabs: tabs) == source
    }

    private static let restDelay: Duration = .milliseconds(600)
    /// Gmail and Calendar cards come sooner, as in Arc.
    private static let liveRestDelay: Duration = .milliseconds(400)
    /// Moving from one favorite to the next while a card is up.
    private static let switchDelay: Duration = .milliseconds(150)
    /// Time to travel from the tile into the card.
    private static let closeDelay: Duration = .milliseconds(200)
    private static let cacheAge: TimeInterval = 60
    private static let rowLimit = 8

    func tileHover(_ item: Item, hovering: Bool, in window: BrowserWindowState, tabs: TabsController) {
        if tabs.profileEngine == .chromium && window.isIncognito { if hovering { dismiss() }; return }
        if itemID != nil && !isCurrent(in: window, tabs: tabs) { dismiss() }
        // The card lies over other tiles, whose tracking areas still report the pointer.
        guard !pointerOverCard || item.id == itemID else { return }
        guard hovering else {
            if tileUnderPointer == item.id {
                tileUnderPointer = nil
                closeSoon()
            }
            return
        }
        tileUnderPointer = item.id
        let live = LiveFavorites.kind(of: item, in: window, tabs: tabs)
        if let live { LiveFavorites.shared.refresh(item, kind: live) }
        guard itemID != item.id, tabs.settings.favoritePreviews, !NookDragSessionManager.shared.isDragging else { return }
        pending?.cancel()
        let delay = itemID != nil ? Self.switchDelay : live == nil ? Self.restDelay : Self.liveRestDelay
        let expected = Self.source(for: item, tabs: tabs)
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, tileUnderPointer == item.id, let expected,
                  Self.source(for: item, tabs: tabs) == expected else { return }
            let rows = live == nil ? await load(item, tabs: tabs) : []
            guard !Task.isCancelled, tileUnderPointer == item.id,
                  Self.source(for: item, tabs: tabs) == expected else { return }
            guard live != nil || !rows.isEmpty else { return dismiss() }
            self.rows = rows
            self.source = expected
            self.live = live
            itemID = item.id
            windowID = window.id
        }
    }

    func cardHover(_ hovering: Bool) {
        pointerOverCard = hovering
        guard hovering else { return closeSoon() }
        pending?.cancel()
        tileUnderPointer = nil
    }

    /// A card is up in the window, or the pointer is on one; the hover-reveal sidebar it hangs
    /// from stays out meanwhile.
    func isShowing(in windowID: UUID) -> Bool {
        pointerOverCard || (itemID != nil && self.windowID == windowID)
    }

    func dismiss() {
        pending?.cancel()
        pointerOverCard = false
        itemID = nil
        windowID = nil
        rows = []
        live = nil
        source = nil
    }

    private func closeSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled, tileUnderPointer == nil, !pointerOverCard else { return }
            dismiss()
        }
    }

    private func load(_ item: Item, tabs: TabsController) async -> [Row] {
        guard let expected = Self.source(for: item, tabs: tabs) else { return [] }
        if let cached = cache[item.id], cached.source == expected,
           Date().timeIntervalSince(cached.at) < Self.cacheAge { return cached.rows }
        // Only sites with something of their own to show get a card. github.com is the one so far.
        guard item.url?.host == "github.com" else { return [] }
        let pulls = await tabs.pullRequests(inSpace: expected.spaceID)
        guard !Task.isCancelled, Self.source(for: item, tabs: tabs) == expected else { return [] }
        let rows = pulls.prefix(Self.rowLimit).map { Row(url: $0.url, title: $0.title) }
        cache[item.id] = (Date(), rows, expected)
        return rows
    }
}

/// The hovered favorite's frame, reported so the card can hang under it.
struct FavoritePreviewAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Drawn inside the browser window.
struct FavoritePreviewOverlay: View {
    let anchor: Anchor<CGRect>?

    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState

    private let preview = FavoritePreview.shared
    @State private var liveCardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            if let anchor, let itemID = preview.itemID, preview.isCurrent(in: windowState, tabs: tabs) {
                let tile = proxy[anchor]
                let origin = preview.live == nil
                    ? FavoritePreviewPlacement.underTile(tile, in: proxy.size)
                    : FavoritePreviewPlacement.besideTile(tile, cardHeight: liveCardHeight, in: proxy.size)
                FavoritePreviewCard(itemID: itemID)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { liveCardHeight = $0 }
                    .offset(x: origin.x, y: origin.y)
                    .transition(.opacity)
            }
        }
        .animation(NookDesign.Motion.quick, value: preview.itemID)
        .dismissesFavoritePreview(when: windowState)
    }
}

extension View {
    /// No hover exit arrives while the window is not key, so a card would stay up.
    func dismissesFavoritePreview(when window: BrowserWindowState) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard FavoritePreview.shared.windowID == window.id, (note.object as? NSWindow) === window.window else { return }
            FavoritePreview.shared.dismiss()
        }
    }
}

/// Where the hovered favorite's card goes, with a top-left origin, in a space of `size`.
enum FavoritePreviewPlacement {
    static let pullRequestsWidth: CGFloat = 280

    static func underTile(_ tile: CGRect, in size: CGSize) -> CGPoint {
        let edge = NookDesign.Spacing.md
        return CGPoint(x: min(max(edge, tile.minX), max(edge, size.width - pullRequestsWidth - edge)),
                       y: tile.maxY + NookDesign.Spacing.xs)
    }

    /// Hanging from the tile's lower corner, as in Arc: to its right, or its left when the
    /// sidebar is on the right.
    static func besideTile(_ tile: CGRect, cardHeight: CGFloat, in size: CGSize) -> CGPoint {
        let edge = NookDesign.Spacing.md
        let width = NookDesign.Size.favoriteCard
        let right = tile.maxX + NookDesign.Spacing.xs
        let x = right + width + edge <= size.width ? right : tile.minX - NookDesign.Spacing.xs - width
        let y = min(tile.maxY - NookDesign.Spacing.md, size.height - cardHeight - edge)
        return CGPoint(x: max(edge, x), y: max(edge, y))
    }
}

/// The hovered favorite's card: a Gmail or Calendar favorite's live card, or the rows its site shows.
struct FavoritePreviewCard: View {
    let itemID: UUID

    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState

    private let preview = FavoritePreview.shared

    var body: some View {
        if let live = preview.live {
            liveCard(live)
        } else {
            pullRequests
        }
    }

    private var pullRequests: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
            ForEach(preview.rows) { row in
                Button {
                    open(row.url)
                } label: {
                    HStack(spacing: NookDesign.Spacing.md) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: NookDesign.Size.rowGlyph, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(row.title)
                            .font(NookDesign.Font.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(RectNavButtonStyle())
            }
        }
        .padding(NookDesign.Spacing.xs)
        .frame(width: FavoritePreviewPlacement.pullRequestsWidth)
        .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.lg))
        .onHoverTracking { preview.cardHover($0) }
    }

    /// In the favorite's space look: its light or dark theme and its accent.
    private func liveCard(_ live: GoogleFavorite) -> some View {
        let space = tabs.spaceID(of: itemID).flatMap { tabs.space($0) }
        let accent = space?.accentColor ?? .accentColor
        return Group {
            switch live {
            case .calendar(let account):
                MeetingCard(account: account, accent: accent) { open($0) }
            case .mail(let account):
                MailCard(itemID: itemID, account: account) { open($0) }
            }
        }
        .frame(width: NookDesign.Size.favoriteCard)
        .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.lg))
        .onHoverTracking { preview.cardHover($0) }
        .spaceThemeAppearance(space?.theme)
    }

    private func open(_ url: URL) {
        guard preview.isCurrent(in: windowState, tabs: tabs), let expected = preview.source else { return }
        preview.dismiss()
        tabs.select(itemID, in: windowState)
        guard let item = tabs.item(itemID), FavoritePreview.source(for: item, tabs: tabs) == expected,
              windowState.spaceID == expected.spaceID else { return }
        tabs.session(for: itemID)?.load(url)
    }
}
