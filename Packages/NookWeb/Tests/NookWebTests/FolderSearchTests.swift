// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore
import Testing
@testable import NookWeb

@MainActor
struct FolderSearchTests {
    @Test func duplicateFolderNamesExposeTheirPathsAlongsideMatchingTabs() throws {
        let host = try Host(); defer { host.cleanup() }
        let first = try #require(host.window.spaceID)
        let space = try #require(host.tabs.createSpace(name: "QDO", icon: "folder", accentHex: "#445566",
                                                       after: first, profileName: "Work"))
        let parent = Parent.pinned(spaceID: space)
        let github = try #require(host.tabs.createFolder(title: "Github", in: parent, after: nil))
        let nested = try #require(host.tabs.createFolder(title: "Insly", in: .folder(itemID: github), after: nil))
        let root = try #require(host.tabs.createFolder(title: "Insly", in: parent, after: github))
        for site in ["inbox", "docs"] {
            let url = try #require(URL(string: "https://example.invalid/" + site))
            _ = try #require(host.tabs.open(url: url, in: host.window, placement: .background,
                                           parent: .folder(itemID: nested), title: "Insly"))
        }

        let search = SearchManager()
        search.setTabs(host.tabs, window: host.window)
        search.searchSuggestions(for: "insly", includeWebSuggestions: false)
        let matches = search.suggestions.compactMap { row -> SearchManager.FolderMatch? in
            guard case .folder(let match) = row.type else { return nil }
            return match
        }
        #expect(Set(matches.map(\.itemID)) == [nested, root])
        let nestedMatch = try #require(matches.first { $0.itemID == nested })
        #expect(nestedMatch.path == "Work › QDO › Pinned › Github › Insly")
        #expect(nestedMatch.detail == "2 links")
        let rootMatch = try #require(matches.first { $0.itemID == root })
        #expect(rootMatch.path == "Work › QDO › Pinned › Insly")
        #expect(rootMatch.detail == "0 links")

        host.tabs.rename(github, "Repositories")
        search.searchSuggestions(for: "", scope: .folder(github), includeWebSuggestions: false)
        guard case .folder(let renamed) = try #require(search.suggestions.first).type else {
            Issue.record("Expected the child folder in the scoped palette")
            return
        }
        #expect(renamed.itemID == nested)
        #expect(renamed.path == "Work › QDO › Pinned › Repositories › Insly")
    }
    @Test func movedFolderWithTheSameDisplayedPathRequiresARefreshedMatch() throws {
        let host = try Host(); defer { host.cleanup() }
        let first = try #require(host.tabs.createSpace(name: "Projects", icon: "folder", accentHex: "#445566",
                                                       after: host.window.spaceID, profileName: "Work"))
        let second = try #require(host.tabs.createSpace(name: "Projects", icon: "folder", accentHex: "#446655",
                                                        after: first, profileName: "Work"))
        #expect(host.tabs.tree.dataStoreID(for: first) != host.tabs.tree.dataStoreID(for: second))
        let folder = try #require(host.tabs.createFolder(title: "Inbox", in: .pinned(spaceID: first), after: nil))
        let search = SearchManager()
        search.setTabs(host.tabs, window: host.window)
        func row() throws -> (SearchManager.SearchSuggestion, SearchManager.FolderMatch) {
            search.searchSuggestions(for: "Inbox", includeWebSuggestions: false)
            let matches = search.suggestions.compactMap { suggestion -> (SearchManager.SearchSuggestion, SearchManager.FolderMatch)? in
                guard case .folder(let match) = suggestion.type else { return nil }
                return (suggestion, match)
            }
            return try #require(matches.first)
        }
        let (listed, match) = try row()
        _ = try #require(host.tabs.open(url: URL(string: "https://example.invalid/item")!, in: host.window,
            placement: .background, parent: .folder(itemID: folder)))
        let (updated, updatedMatch) = try row()
        #expect(updatedMatch.detail == "1 link" && updated == listed)
        #expect(search.isCurrentFolderMatch(match))

        host.tabs.move(folder, to: .pinned(spaceID: second), after: nil)
        #expect(!search.isCurrentFolderMatch(match))
        let (refreshed, moved) = try row()
        #expect(moved.path == match.path && refreshed != listed)
        #expect(search.isCurrentFolderMatch(moved))

        let firstProfile = try #require(host.tabs.tree.dataStoreID(for: first))
        host.tabs.setProfile(second, to: firstProfile, name: "Work", keepingLeftProfile: true)
        try #require(host.tabs.tree.dataStoreID(for: second) == firstProfile)
        #expect(!search.isCurrentFolderMatch(moved))
        let (reassignedRow, reassigned) = try row()
        #expect(reassigned.path == moved.path && reassignedRow != refreshed)
        #expect(search.isCurrentFolderMatch(reassigned))
    }

}
