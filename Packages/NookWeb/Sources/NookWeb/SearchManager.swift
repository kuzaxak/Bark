// Licensed under GPL-3.0. See LICENSE.
//
//  SearchManager.swift
//  Alto
//
//  Created by Maciek Bagiński on 31/07/2025.
//

import Foundation
import NookSettings
import NookTabsCore
import Observation
import SwiftUI

@MainActor
@Observable
public class SearchManager {
    public var suggestions: [SearchSuggestion] = []
    public var isLoading: Bool = false
    /// Bare host the omnibox completes to inline, e.g. `facebook.com`. Only set when history has one
    /// worth offering; the palette re-checks that it still prefixes the typed text before showing it.
    public var autofillHost: String?
    
    public init() {}
    // Focused URLProtocol tests exercise actual provider/transport admission.
    // App consumers keep the public initializer and the credential-free session.
    init(suggestionSession: URLSession) { suggestionSessionOverride = suggestionSession }
    @ObservationIgnored private var suggestionSessionOverride: URLSession?

    @MainActor private final class WebSuggestionTarget {
        weak var page: PageSession?
        let profileID: UUID?
        let isCurrent: @MainActor () -> Bool
        init(page: PageSession, isCurrent: @escaping @MainActor () -> Bool) {
            self.page = page; profileID = page.profile?.id; self.isCurrent = isCurrent
        }
    }
    private var webSuggestionTarget: WebSuggestionTarget?

    /// Explicit native address intent. A stale/private/unknown target fails
    /// closed; it never falls back to the window's unrelated space profile.
    public func setWebSuggestionTarget(for page: PageSession, whileCurrent: @escaping @MainActor () -> Bool) {
        webSuggestionTarget = WebSuggestionTarget(page: page, isCurrent: whileCurrent)
        clearSuggestions()
    }
    public func clearWebSuggestionTarget() {
        webSuggestionTarget = nil
        clearSuggestions()
    }

    // Native suggestions need no credentials, cookies or persistent cache.
    // Select from the real model engine, keeping WebKit's session unchanged.
    private static let nativeSuggestionSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private var session: URLSession {
        tabs?.profileEngine == .chromium ? suggestionSessionOverride ?? Self.nativeSuggestionSession : .shared
    }
    private var searchTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var autofillTask: Task<Void, Never>?
    /// The last results each leg produced. Held rather than re-derived from `suggestions`, and
    /// kept across a keystroke so a leg that is still running does not blank its own rows.
    private var historyRows: [SearchSuggestion] = []
    private var webRows: [SearchSuggestion] = []
    private var textRows: [SearchSuggestion] = []
    /// Local servers (`localhost:3000`) when the query asks for them, one row per origin.
    private var localRows: [SearchSuggestion] = []
    private var searchGeneration = UUID()
    private weak var tabs: TabsController?
    private weak var window: BrowserWindowState?
    private weak var historyManager: HistoryManager?
    private var currentSpaceId: UUID?
    private var resultProfileID: UUID?

    /// A regular editor can belong to a different profile from its window's space.
    /// A closed, private or superseded editor has no persistent suggestion source.
    private var suggestionProfileID: UUID? {
        guard let tabs, let window, !window.isIncognito,
              tabs.windowRegistry.windows[window.id] === window else { return nil }
        let profile: UUID?
        if tabs.profileEngine == .chromium, let target = webSuggestionTarget {
            guard let page = target.page, target.isCurrent(),
                  webSuggestionTarget === target, !page.isPrivate,
                  page.profile?.id == target.profileID else { return nil }
            profile = target.profileID
        } else {
            profile = window.spaceID.flatMap { tabs.tree.dataStoreID(for: $0) }
        }
        guard let profile, tabs.isProfileAvailable(profile) else { return nil }
        return profile
    }

    @discardableResult
    public func recordPick(prefix: String, url: URL) -> Bool {
        guard let profile = suggestionProfileID, profile == resultProfileID, let historyManager else { return false }
        historyManager.recordPick(prefix: prefix, url: url, fromPrivateWindow: false, profile: profile)
        return true
    }

    public func forgetHistory(_ url: URL) -> Bool {
        guard let profile = suggestionProfileID, profile == resultProfileID, let historyManager else { return false }
        historyManager.forget(url, profile: profile)
        return true
    }
    
    /// What a query searches: everything, or one kind of row (`t `, `h ` or Ctrl+R, a folder chip).
    public enum Scope: Equatable {
        case all
        case tabs
        case history
        case folder(UUID)
    }

    /// Rows a scope lists at most.
    public static let scopedLimit = 30

    /// An open tab the palette can switch to, captured when the query ran.
    public struct TabMatch {
        public let itemID: UUID
        public let title: String
        public let url: URL
        /// The icon of the tab's space when that is not the window's space.
        public let spaceIcon: String?
        /// Replaces the short address on line 2, e.g. the sub-folder a link sits in.
        public let detail: String?

        public init(itemID: UUID, title: String, url: URL, spaceIcon: String? = nil, detail: String? = nil) {
            self.itemID = itemID
            self.title = title
            self.url = url
            self.spaceIcon = spaceIcon
            self.detail = detail
        }

        /// Read on each row render so the exact tab's icon can change without a new query.
        @MainActor public func favicon(in tabs: TabsController) -> SwiftUI.Image {
            tabs.session(for: itemID)?.favicon ?? SwiftUI.Image(systemName: "globe")
        }
    }

    /// A sidebar folder: Return reveals it, Tab searches inside it.
    public struct FolderMatch {
        public let itemID: UUID
        public let title: String
        public let spaceIcon: String?
        /// The location shown in the palette, including the owning profile when its name differs from the space.
        public let path: String
        /// What it holds, e.g. "2 folders, 5 links".
        public let detail: String
    }

    /// A command the bar runs on the tab that was selected when it opened.
    public struct ActionMatch {
        /// What the bar runs: an action's name, then a colon and the choice's id for a choice.
        public let id: String
        public let title: String
        /// Its shortcut, e.g. "⇧⌘C".
        public let detail: String?
        public let icon: String
        /// Tab or Return lists its choices (a folder, a space) instead of running it.
        public let takesChoice: Bool

        public init(id: String, title: String, detail: String?, icon: String, takesChoice: Bool) {
            self.id = id
            self.title = title
            self.detail = detail
            self.icon = icon
            self.takesChoice = takesChoice
        }
    }

    public struct SearchSuggestion: Identifiable, Equatable {
        public let id = UUID()
        public let text: String
        public let type: SuggestionType
        /// The header shown above the first row of each section.
        public let section: String?

        public init(text: String, type: SuggestionType, section: String? = nil) {
            self.text = text
            self.type = type
            self.section = section
        }

        public enum SuggestionType {
            case search
            case url
            case tab(TabMatch)
            case folder(FolderMatch)
            case action(ActionMatch)
            case history(HistoryEntry)
        }

        public static func == (lhs: SearchSuggestion, rhs: SearchSuggestion) -> Bool {
            guard lhs.section == rhs.section else { return false }
            switch (lhs.type, rhs.type) {
            case (.search, .search), (.url, .url):
                return lhs.text == rhs.text
            case (.tab(let lhsTab), .tab(let rhsTab)):
                return lhs.text == rhs.text && lhsTab.itemID == rhsTab.itemID
            case (.folder(let lhsFolder), .folder(let rhsFolder)):
                return lhsFolder.itemID == rhsFolder.itemID
            case (.action(let lhsAction), .action(let rhsAction)):
                return lhsAction.id == rhsAction.id
            case (.history(let lhsHistory), .history(let rhsHistory)):
                return lhs.text == rhs.text && lhsHistory.id == rhsHistory.id
            default:
                return false
            }
        }
    }
    
    /// The controller and window whose space's tabs the palette searches.
    public func setTabs(_ tabs: TabsController?, window: BrowserWindowState?) {
        if self.tabs !== tabs || self.window !== window { clearWebSuggestionTarget() }
        self.tabs = tabs
        self.window = window
        updateSpaceContext()
    }
    
    public func setHistoryManager(_ historyManager: HistoryManager?) {
        self.historyManager = historyManager
    }

    @MainActor public func updateSpaceContext() {
        let profile = suggestionProfileID
        if currentSpaceId != window?.spaceID || resultProfileID != profile { clearSuggestions() }
        currentSpaceId = window?.spaceID
        resultProfileID = profile
    }
    
    @MainActor public func searchSuggestions(for query: String, scope: Scope = .all, includeWebSuggestions: Bool = true) {
        updateSpaceContext()
        let profile = resultProfileID
        searchTask?.cancel()
        historyTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        isLoading = false
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Internal management addresses can include the user's password search.
        // Keep them local from the first scheme delimiter, including while typing.
        let lowercaseInput = input.lowercased()
        let internalAddress = tabs?.profileEngine == .chromium &&
            (lowercaseInput.hasPrefix("chrome:") || lowercaseInput.hasPrefix("about:"))
        let requestWebSuggestions = includeWebSuggestions && !internalAddress
        if !requestWebSuggestions { webRows = [] }
        let space = currentSpaceId
        if scope != .all {
            searchScope(scope, query: query, generation: generation, profile: profile)
            return
        }
        guard !input.isEmpty else {
            autofillTask?.cancel()
            autofillHost = nil
            historyRows = []
            textRows = []
            webRows = []
            localRows = []
            updateSuggestionsIfNeeded([])
            return
        }

        // Runs outside searchTask's debounce: the inline completion has to keep pace with typing.
        autofillTask?.cancel()
        autofillTask = Task { [weak self] in
            guard let self, let profile, let historyManager = self.historyManager else { return }
            let host = await historyManager.autofillHost(prefix: query.trimmingCharacters(in: .whitespacesAndNewlines), profile: profile)
            guard !Task.isCancelled, self.searchGeneration == generation,
                  self.window?.spaceID == space, self.suggestionProfileID == profile else { return }
            self.autofillHost = host
        }

        let matches = searchTabsAndFolders(for: query)
        // Keep exact folder destinations reachable when tab titles fill the first three rows.
        let exactTitle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let namedFolders = matches.dropFirst(3).filter { row in
            guard case .folder(let folder) = row.type else { return false }
            return folder.title.localizedCaseInsensitiveCompare(exactTitle) == .orderedSame
        }
        let tabs = Array(matches.prefix(3)) + namedFolders
        // Paint what is already known for this keystroke, carrying each leg's last rows. The
        // palette puts its own row for the typed text above these.
        compose(tabs: tabs)

        // History is a local lookup, so it runs on this keystroke rather than waiting for a pause
        // in typing. Only the network request is debounced.
        historyTask = Task { [weak self] in
            guard let self, let profile else { return }
            // Spare rows, for when the first three turn out to be open tabs.
            let history = Array(await self.searchHistory(for: query, profile: profile).prefix(6))
            guard !Task.isCancelled, self.searchGeneration == generation,
                  self.window?.spaceID == space, self.suggestionProfileID == profile else { return }
            let local = await self.searchLocalServers(for: query, profile: profile)
            guard !Task.isCancelled, self.searchGeneration == generation, self.suggestionProfileID == profile else { return }
            self.historyRows = history
            self.localRows = local
            self.compose(tabs: tabs)
            // Page text second, so title and URL matches paint without waiting on it.
            let text = await self.searchPageText(for: query, profile: profile)
            guard !Task.isCancelled, self.searchGeneration == generation,
                  self.window?.spaceID == space, self.suggestionProfileID == profile else { return }
            self.textRows = text
            self.compose(tabs: tabs)
        }

        // Inline address editing may request local history only. In particular, a
        // complete URL must not be sent to the remote suggestion provider.
        guard requestWebSuggestions, let profile else { return }
        isLoading = true
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let webSuggestions = await self.fetchWebSuggestions(for: query, profileID: profile)
            guard !Task.isCancelled, self.searchGeneration == generation else { return }
            self.isLoading = false
            guard self.window?.spaceID == space, self.suggestionProfileID == profile else { return }
            self.webRows = webSuggestions
            self.compose(tabs: tabs)
        }
    }

    /// One kind of row, up to `scopedLimit`: tabs grouped by space, history by rank, or a
    /// folder's contents (its sub-folders, then links) and, once typing, every link under it.
    @MainActor private func searchScope(_ scope: Scope, query: String, generation: UUID, profile: UUID?) {
        autofillTask?.cancel()
        autofillHost = nil
        historyRows = []
        textRows = []
        webRows = []
        localRows = []
        switch scope {
        case .all:
            return
        case .tabs:
            updateSuggestionsIfNeeded(scopedTabs(for: query))
        case .folder(let folderID):
            updateSuggestionsIfNeeded(folderRows(folderID, query: query))
        case .history:
            guard profile != nil else { updateSuggestionsIfNeeded([]); return }
            historyTask = Task { [weak self] in
                guard let self, let profile, let historyManager = self.historyManager else { return }
                let rows: [SearchSuggestion]
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rows = await historyManager.getHistory(days: 7, limit: Self.scopedLimit, profile: profile).entries.map {
                        SearchSuggestion(text: $0.displayTitle, type: .history($0), section: "History")
                    }
                } else {
                    rows = await self.searchHistory(for: query, profile: profile)
                }
                guard !Task.isCancelled, self.searchGeneration == generation, self.suggestionProfileID == profile else { return }
                self.updateSuggestionsIfNeeded(Array(rows.prefix(Self.scopedLimit)))
            }
        }
    }

    /// Rebuilds the visible list from the query's local rows plus whatever each leg last returned.
    @MainActor private func compose(tabs: [SearchSuggestion]) {
        // A page that is already an open tab shows once, as the tab.
        let open = Set(tabs.compactMap { row -> String? in
            if case .tab(let match) = row.type { return Self.pageKey(match.url) }
            return nil
        })
        let history = Array(historyRows.filter { row in
            if case .history(let entry) = row.type { return !open.contains(Self.pageKey(entry.url)) }
            return true
        }.prefix(3))
        // Page text matches come after, minus any page already shown above.
        let shown = open.union(history.compactMap { row -> String? in
            if case .history(let entry) = row.type { return Self.pageKey(entry.url) }
            return nil
        })
        let text = textRows.filter { row in
            if case .history(let entry) = row.type { return !shown.contains(Self.pageKey(entry.url)) }
            return false
        }
        updateSuggestionsIfNeeded(Array((tabs + localRows + history + Array(text.prefix(2)) + webRows).prefix(8)))
    }

    /// One row per local server origin the query asks for, ranked by how often and how
    /// recently each port was used.
    @MainActor private func searchLocalServers(for query: String, profile: UUID) async -> [SearchSuggestion] {
        guard let historyManager, PaletteText.isLocalServerQuery(query) else { return [] }
        let family = query.trimmingCharacters(in: .whitespaces).hasPrefix("1") ? "127.0.0.1" : "localhost"
        let rows = await historyManager.indexRows(matching: family, profile: profile) ?? []
        return PaletteText.localOrigins(rows.map { ($0.url, $0.key) }, typed: query).prefix(3).map {
            SearchSuggestion(text: $0, type: .url, section: "Local Servers")
        }
    }

    /// History rows found by words in the page's text, when that setting is on.
    @MainActor private func searchPageText(for query: String, profile: UUID) async -> [SearchSuggestion] {
        guard let historyManager, tabs?.settings.searchPageTextInHistory == true,
              query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return [] }
        // Spare rows for the ones the dedupe in compose drops.
        return await historyManager.searchPageText(query: query, limit: 8, profile: profile).map {
            SearchSuggestion(text: $0.displayTitle, type: .history($0), section: "Page Text")
        }
    }

    /// One key for a page however its URL was written: no scheme, `www.` or trailing slash.
    private static func pageKey(_ url: URL) -> String {
        var key = (url.host ?? "") + url.path + (url.query.map { "?" + $0 } ?? "")
        if key.hasPrefix("www.") { key.removeFirst(4) }
        if key.hasSuffix("/") { key.removeLast() }
        return key.lowercased()
    }

    /// The words of a query. A row matches when every word is in its title or URL, in any order.
    static func words(of query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A tab row for `item`; nil while it has no address.
    @MainActor private func tabMatch(_ item: Item, detail: String? = nil) -> TabMatch? {
        guard let tabs else { return nil }
        let session = tabs.session(for: item.id)
        guard let url = session?.url ?? tabs.device.openPages[item.id]?.url ?? item.url else { return nil }
        let title = item.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? session?.title ?? item.displayTitle
        return TabMatch(itemID: item.id, title: title, url: url, spaceIcon: spaceIcon(of: item.id), detail: detail)
    }

    @MainActor private func folderMatch(_ item: Item) -> FolderMatch? {
        guard let tabs, let window else { return nil }
        let tree = tabs.tree(tabs.owner(of: window))
        guard let chain = tree.folderChain(of: item.id), let id = chain.section.spaceID,
              let space = tree.space(id) else { return nil }
        let section: String
        switch chain.section {
        case .pinned: section = "Pinned"
        case .tabs: section = "Tabs"
        case .favorites: section = "Favorites"
        case .folder: return nil
        }
        var path = [space.name, section]
        if let profile = tree.profile(ofSpace: id)?.name, !profile.isEmpty, profile != space.name {
            path.insert(profile, at: 0)
        }
        path += chain.folders.reversed().compactMap { tree.item($0)?.displayTitle }
        path.append(item.displayTitle)
        let children = tree.children(of: .folder(itemID: item.id))
        let folders = children.filter(\.isFolder).count, links = children.count - folders
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if links > 0 || folders == 0 { parts.append(links == 1 ? "1 link" : "\(links) links") }
        return FolderMatch(itemID: item.id, title: item.displayTitle, spaceIcon: spaceIcon(of: item.id),
                           path: path.joined(separator: " › "), detail: parts.joined(separator: ", "))
    }

    /// The icon of the space holding `itemID`, when that is not the window's space.
    @MainActor private func spaceIcon(of itemID: UUID) -> String? {
        guard let tabs, let spaceID = tabs.spaceID(of: itemID), spaceID != window?.spaceID else { return nil }
        return tabs.space(spaceID)?.icon
    }

    /// The spaces a query searches, the window's first. The agent's tabs are not the person's.
    @MainActor private func searchedSpaces() -> [UUID] {
        guard let tabs, let window, let spaceID = window.spaceID else { return [] }
        return ([spaceID] + tabs.spaces(visibleIn: window).map(\.id).filter { $0 != spaceID }).filter { $0 != tabs.agentSpaceID }
    }

    /// Tabs (open, pinned, favorites, in folders) and folders matching every word: word-prefix
    /// title matches first, then this space's, then shorter titles. Folders match on their name
    /// only. The page being looked at is not a tab to switch to.
    @MainActor private func searchTabsAndFolders(for query: String) -> [SearchSuggestion] {
        guard let tabs, let window else { return [] }
        var scored: [(row: SearchSuggestion, score: Int, here: Bool, length: Int)] = []
        for (index, spaceID) in searchedSpaces().enumerated() {
            for item in tabs.items(inSpace: spaceID) where item.id != window.selectedItemID {
                guard let match = tabMatch(item),
                      let score = PaletteText.matchScore(query: query, title: match.title, detail: match.url.absoluteString) else { continue }
                scored.append((SearchSuggestion(text: match.title, type: .tab(match), section: "Tabs"), score, index == 0, match.title.count))
            }
            for folder in tabs.folders(inSpace: spaceID).map(\.item) {
                guard let score = PaletteText.matchScore(query: query, title: folder.displayTitle, detail: nil),
                      let match = folderMatch(folder) else { continue }
                scored.append((SearchSuggestion(text: folder.displayTitle, type: .folder(match), section: "Tabs"), score, index == 0, folder.displayTitle.count))
            }
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.here != rhs.here { return lhs.here }
            return lhs.length < rhs.length
        }.map(\.row)
    }

    /// The tabs-only scope: matching tabs grouped by space, the window's first.
    @MainActor private func scopedTabs(for query: String) -> [SearchSuggestion] {
        guard let tabs, let window else { return [] }
        var rows: [SearchSuggestion] = []
        for spaceID in searchedSpaces() where rows.count < Self.scopedLimit {
            let name = tabs.space(spaceID)?.name ?? "Space"
            let matches = tabs.items(inSpace: spaceID).compactMap { item -> (match: TabMatch, score: Int)? in
                guard item.id != window.selectedItemID, let match = tabMatch(item),
                      let score = PaletteText.matchScore(query: query, title: match.title, detail: match.url.absoluteString) else { return nil }
                return (match, score)
            }
            rows += matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.match.title < $1.match.title }
                .map { SearchSuggestion(text: $0.match.title, type: .tab($0.match), section: name) }
        }
        return Array(rows.prefix(Self.scopedLimit))
    }

    /// A folder scope. Empty query: its sub-folders, then its links, as the sidebar orders them.
    /// Otherwise every link at any depth under it, matched by title or address, with the
    /// sub-folder it sits in on line 2.
    @MainActor private func folderRows(_ folderID: UUID, query: String) -> [SearchSuggestion] {
        guard let tabs else { return [] }
        let parent = Parent.folder(itemID: folderID)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let children = tabs.children(of: parent)
            let folders = children.filter(\.isFolder).compactMap(folderMatch).map {
                SearchSuggestion(text: $0.title, type: .folder($0))
            }
            let links = children.filter { !$0.isFolder }.compactMap { tabMatch($0) }.map { SearchSuggestion(text: $0.title, type: .tab($0)) }
            return Array((folders + links).prefix(Self.scopedLimit))
        }
        var found: [(row: SearchSuggestion, score: Int)] = []
        func walk(_ parent: Parent, path: [String]) {
            for child in tabs.children(of: parent) {
                if child.isFolder {
                    walk(.folder(itemID: child.id), path: path + [child.displayTitle])
                    continue
                }
                if let match = tabMatch(child, detail: path.isEmpty ? nil : path.joined(separator: " › ")),
                   let score = PaletteText.matchScore(query: query, title: match.title, detail: match.url.absoluteString) {
                    found.append((SearchSuggestion(text: match.title, type: .tab(match)), score))
                }
                walk(.folder(itemID: child.id), path: path)
            }
        }
        walk(parent, path: [])
        let ranked = found.enumerated().sorted { lhs, rhs in
            lhs.element.score != rhs.element.score ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
        }
        return ranked.prefix(Self.scopedLimit).map(\.element.row)
    }

    @MainActor private func searchHistory(for query: String, profile: UUID) async -> [SearchSuggestion] {
        guard let historyManager = historyManager else { return [] }
        let open = Set(tabs?.sessions.map { Self.pageKey($0.url) } ?? [])
        if let ranked = await historyManager.searchIndex(query: query, limit: 30, profile: profile, isOpen: { url in
            URL(string: url).map { open.contains(Self.pageKey($0)) } ?? false
        }) {
            return ranked.map { SearchSuggestion(text: $0.displayTitle, type: .history($0), section: "History") }
        }

        let words = Self.words(of: query)
        // Enough matches that the sort below, not recency alone, picks the rows shown.
        let historyEntries = await historyManager.searchHistory(query: query, offset: 0, limit: 100, profile: profile)
        
        let matchingHistory = historyEntries.entries.map {
            SearchSuggestion(text: $0.displayTitle, type: .history($0), section: "History")
        }

        // Sort by relevance (title matches first, then URL matches, then by visit count and recency)
        let sortedHistory = matchingHistory.sorted { (lhs: SearchSuggestion, rhs: SearchSuggestion) -> Bool in
            if case .history(let lhsHistory) = lhs.type, case .history(let rhsHistory) = rhs.type {
                let lhsTitleMatch = words.allSatisfy(lhsHistory.title.lowercased().contains)
                let rhsTitleMatch = words.allSatisfy(rhsHistory.title.lowercased().contains)
                
                // First prioritize title matches
                if lhsTitleMatch && !rhsTitleMatch {
                    return true
                } else if !lhsTitleMatch && rhsTitleMatch {
                    return false
                } else {
                    // Then prioritize by visit count and recency
                    if lhsHistory.visitCount != rhsHistory.visitCount {
                        return lhsHistory.visitCount > rhsHistory.visitCount
                    } else {
                        return lhsHistory.lastVisited > rhsHistory.lastVisited
                    }
                }
            }
            return false
        }
        
        return sortedHistory
    }
    
    private func fetchWebSuggestions(for query: String, profileID: UUID) async -> [SearchSuggestion] {
        guard let window, let tabs else { return [] }
        func current() -> Bool { !Task.isCancelled && suggestionProfileID == profileID }
        guard current() else { return [] }
        func effective() async -> ProfileSearchState? {
            await withCheckedContinuation { continuation in
                tabs.profileSearchState(profileID: profileID, includeChoices: false) { continuation.resume(returning: try? $0.get()) }
            }
        }
        let nativeState = tabs.profileEngine == .chromium ? await effective() : nil
        let engine: String
        if tabs.profileEngine == .chromium {
            guard current() else { return [] }
            guard let nativeState else { return [] }; engine = nativeState.suggestions
        } else { engine = tabs.searchEngineId(forSpace: window.spaceID) }
        var components: URLComponents
        switch engine {
        case SearchProvider.google.rawValue:
            components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            components.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: query)]
        case SearchProvider.kagi.rawValue:
            // From https://kagi.com/opensearch.xml.
            components = URLComponents(string: "https://kagisuggest.com/api/autosuggest")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        default:
            return []
        }
        guard let url = components.url,
              tabs.profileEngine != .chromium || current() else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any],
                  jsonArray.count >= 2, let strings = jsonArray[1] as? [String] else { return [] }
            if let nativeState {
                guard current(), let state = await effective(), state == nativeState,
                      current() else { return [] }
            }
            return strings.prefix(5).map {
                SearchSuggestion(text: $0, type: isLikelyURL($0) ? .url : .search, section: "Suggestions")
            }
        } catch { return [] }
    }

    private func updateSuggestionsIfNeeded(_ newSuggestions: [SearchSuggestion]) {
        let shouldAnimate = shouldAnimateChange(from: suggestions, to: newSuggestions)
        
        if shouldAnimate {
            withAnimation(.easeInOut(duration: 0.25)) {
                suggestions = newSuggestions
            }
        } else {
            suggestions = newSuggestions
        }
    }
    
    private func shouldAnimateChange(from oldSuggestions: [SearchSuggestion], to newSuggestions: [SearchSuggestion]) -> Bool {
        if oldSuggestions.isEmpty != newSuggestions.isEmpty {
            return true
        }
        
        // Always animate if count changes significantly
        if abs(oldSuggestions.count - newSuggestions.count) > 2 {
            return true
        }
        
        // Compare suggestion texts to see if there are significant changes
        let oldTexts = Set(oldSuggestions.map { $0.text })
        let newTexts = Set(newSuggestions.map { $0.text })
        
        // Calculate how many suggestions are different
        let intersection = oldTexts.intersection(newTexts)
        let totalUnique = oldTexts.union(newTexts).count
        let similarityRatio = Double(intersection.count) / Double(max(totalUnique, 1))
        
        // Only animate if less than 60% of suggestions are the same
        return similarityRatio < 0.6
    }
    
    
    public func clearSuggestions() {
        searchTask?.cancel()
        historyTask?.cancel()
        autofillTask?.cancel()
        autofillHost = nil
        historyRows = []
        textRows = []
        webRows = []
        localRows = []
        searchGeneration = UUID()
        if !suggestions.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) {
                suggestions = []
            }
        }
        isLoading = false
    }
}
