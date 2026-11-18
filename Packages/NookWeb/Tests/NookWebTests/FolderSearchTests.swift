// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore
import Testing
@testable import NookWeb

@MainActor
struct FolderSearchTests {
    @Test func duplicateFolderNamesExposeTheirPathsAlongsideMatchingTabs() throws {
        let host = try Host()
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
}
