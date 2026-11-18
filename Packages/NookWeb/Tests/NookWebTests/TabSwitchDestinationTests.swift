// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookWeb

@MainActor
struct TabSwitchDestinationTests {
    @Test func duplicateTitlesUseTheirExactDestinationsInTheInvokingWindow() throws {
        let host = try Host()
        let current = try #require(host.window.spaceID)
        let sibling = try #require(host.tabs.createSpace(name: "Inbox", icon: "tray",
            accentHex: "#123456", after: current, sharingLoginsWith: current))
        let remote = try #require(host.tabs.createSpace(name: "Inbox", icon: "house",
            accentHex: "#123456", after: sibling, profileName: "Personal"))
        let url = URL(string: "https://example.invalid/inbox")!

        let localTab = try #require(host.tabs.open(url: url, in: host.window,
            placement: .background, parent: .tabs(spaceID: current), title: "Inbox"))
        let siblingTab = try #require(host.tabs.open(url: url, in: host.window,
            placement: .background, parent: .tabs(spaceID: sibling), title: "Inbox"))
        let sharedFavorite = try #require(host.tabs.open(url: url, in: host.window,
            placement: .background, parent: .favorites(spaceID: sibling), title: "Inbox"))

        let otherWindow = BrowserWindowState()
        otherWindow.spaceID = remote
        host.registry.register(otherWindow)
        let remoteTab = try #require(host.tabs.open(url: url, in: otherWindow,
            placement: .newTab, parent: .tabs(spaceID: remote), title: "Inbox"))
        #expect(otherWindow.selectedItemID == remoteTab)

        let search = SearchManager()
        search.setTabs(host.tabs, window: host.window)
        search.searchSuggestions(for: "Inbox", scope: .tabs)
        let matches = search.suggestions.compactMap { row -> SearchManager.TabMatch? in
            guard case .tab(let match) = row.type else { return nil }
            return match
        }
        #expect(Set(matches.map(\.itemID)) == [localTab, siblingTab, sharedFavorite, remoteTab])
        #expect(matches.allSatisfy { $0.title == "Inbox" })

        #expect(host.tabs.tabSwitchDestination(for: localTab, in: host.window) == nil)
        #expect(host.tabs.tabSwitchDestination(for: sharedFavorite, in: host.window) == nil)
        let sameProfile = try #require(host.tabs.tabSwitchDestination(for: siblingTab, in: host.window))
        #expect(sameProfile.name == "Inbox")
        #expect(sameProfile.icon == "tray")
        #expect(sameProfile.profileName == host.tabs.profile(forSpace: current)?.name)

        let otherProfile = try #require(host.tabs.tabSwitchDestination(for: remoteTab, in: host.window))
        #expect(otherProfile.name == "Inbox")
        #expect(otherProfile.icon == "house")
        #expect(otherProfile.profileName == "Personal")
        #expect(host.tabs.tabSwitchDestination(for: remoteTab, in: otherWindow) == nil)

        let namedSpace = try #require(host.tabs.createSpace(name: "Archive", icon: "archivebox",
            accentHex: "#123456", after: remote, profileName: "Archive"))
        let namedTab = try #require(host.tabs.open(url: url, in: host.window, placement: .background,
            parent: .tabs(spaceID: namedSpace), title: "Archive"))
        let named = try #require(host.tabs.tabSwitchDestination(for: namedTab, in: host.window))
        #expect(named.name == "Archive" && named.profileName == nil)

        host.tabs.select(sharedFavorite, in: host.window)
        #expect(host.window.spaceID == current)
        #expect(host.window.selectedItemID == sharedFavorite)
        host.tabs.select(remoteTab, in: host.window)
        #expect(host.window.spaceID == remote)
        #expect(host.window.selectedItemID == remoteTab)
    }
}
