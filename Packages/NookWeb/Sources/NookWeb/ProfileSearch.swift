// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookSettings
import NookTabsCore

public struct ProfileSearchState: Codable, Equatable, Sendable {
    public struct Provider: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public let kagiSession: Bool
    public let version: String
    public let selected: String
    public let name: String
    public let controlled: Bool
    public let managed: Bool
    public let providers: [Provider]
    public let suggestions: String
    public init(version: String, selected: String, name: String, controlled: Bool, managed: Bool,
                providers: [Provider], suggestions: String, kagiSession: Bool = false) {
        self.kagiSession = kagiSession; self.version = version; self.selected = selected; self.name = name; self.controlled = controlled
        self.managed = managed; self.providers = providers; self.suggestions = suggestions
    }
}
public enum ProfileSearchError: Error { case unavailable, refused }
/// Exact identity + optional already-bound private page. Seed contains only
/// non-secret app provider metadata, never a credential-expanded query template.
public typealias ProfileSearchAction = @MainActor (UUID, PageSession?, @escaping @MainActor () -> String?, String?, Bool,
    @escaping @MainActor (Result<ProfileSearchState, Error>) -> Void) -> Void

extension TabsController {
    public func profileSearchState(profileID: UUID, page: PageSession? = nil,
                                   selecting: String? = nil, includeChoices: Bool = true,
                                   completion: @escaping @MainActor (Result<ProfileSearchState, Error>) -> Void) {
        func valid() -> Bool {
            if let page, page.isPrivate {
                return page.profile?.id == profileID && page.navigation != nil && !page.isUnloaded
            }
            return isProfileAvailable(profileID) && (page == nil || page?.profile?.id == profileID)
        }
        guard profileEngine == .chromium, valid(), let action = onProfileSearch else {
            completion(.failure(ProfileSearchError.unavailable)); return
        }
        struct Seed: Encodable {
            struct Engine: Encodable { let id: String; let name: String; let url: String }
            let selected: String
            let engines: [Engine]
        }
        let seed: @MainActor () -> String? = { [weak self] in
        guard let self else { return nil }
        let selected: String
        if let page, page.isPrivate {
            selected = self.searchEngineId(forSpace: self.spaceID(of: page.itemID))
        } else {
            selected = self.profiles.first(where: { $0.id == profileID })?.searchEngineId ?? self.settings.searchEngineId
        }
        let engines = SearchProvider.allCases.map {
            Seed.Engine(id: $0.rawValue, name: $0.displayName,
                        url: $0.queryTemplate.replacingOccurrences(of: "%@", with: "{searchTerms}"))
        } + self.settings.customSearchEngines.map {
            Seed.Engine(id: $0.id.uuidString, name: $0.name,
                        url: $0.urlTemplate.replacingOccurrences(of: "%@", with: "{searchTerms}"))
        }
        // Match the existing app resolver for deleted/unknown custom IDs.
        // A present but invalid selected template still fails native validation.
        let effective = engines.contains(where: { $0.id == selected }) ? selected : SearchProvider.google.rawValue
        guard let data = try? JSONEncoder().encode(Seed(selected: effective, engines: engines)) else { return nil }
        return String(data: data, encoding: .utf8)
        }
        var finished = false
        action(profileID, page, seed, selecting, includeChoices) { result in
            guard !finished else { return }; finished = true
            completion(valid() ? result : .failure(ProfileSearchError.unavailable))
        }
    }

    /// Keep new searches cold in the existing device-local page record until
    /// selected; native metadata owns URL/POST dispatch when its blank is ready.
    @discardableResult
    public func openSearch(_ query: String, in window: BrowserWindowState, placement: Placement) -> UUID? {
        guard profileEngine == .chromium, isSearchInput(query),
              placement == .newTab || placement == .background,
              windowRegistry.windows[window.id] === window,
              let id = open(url: URL(string: "about:blank")!, in: window, placement: .background, title: query),
              let page = ensureSession(for: id) else { return nil }
        recordPageOwner(id, in: window)
        page.typedVisitPending = true
        page.stageNativeSearch(query)
        if placement == .newTab { select(id, in: window) }
        return id
    }

    /// Pending searches are device-local, even when the tab's home is synced.
    /// Private pages keep the existing PageSession intent only in memory.
    func storePendingSearch(_ query: String?, for page: PageSession) {
        if page.isPrivate { page.nativePrivatePendingSearch = query; return }
        guard session(for: page.itemID) === page else { return }
        var saved = device.openPages[page.itemID] ?? OpenPage(url: page.storableURL, title: page.title)
        guard saved.pendingSearch != query else { return }
        saved.pendingSearch = query
        setOpenPage(page.itemID, query == nil && tree.scope(of: page.itemID) != .synced ? nil : saved)
    }

    func pendingSearchPage(for itemID: UUID) -> OpenPage? {
        if let page = session(for: itemID), let query = page.pendingNativeSearchQuery ?? page.nativeSearchIntent?.query {
            return OpenPage(url: page.storableURL, title: page.title, pendingSearch: query)
        }
        guard case .main? = owner(ofItem: itemID),
              let page = device.openPages[itemID], page.pendingSearch != nil else { return nil }
        return page
    }

    /// Reuses the normal model item/factory/blocker path; a POST search must not
    /// first issue a GET of its eventual search URL.
    public func search(_ query: String, in window: BrowserWindowState, splitItemID: UUID? = nil) {
        if let id = splitItemID {
            guard window.split?.contains(id) == true, !isPageShownElsewhere(id, from: window),
                  let page = ensureSession(for: id) else { return }
            page.navigate(to: query)
            select(id, in: window)
        } else if let page = controllableSession(in: window) {
            page.navigate(to: query)
        } else if let id = open(url: URL(string: "about:blank")!, in: window, placement: .newTab),
                  let page = session(for: id) {
            page.navigate(to: query)
        }
    }
}
