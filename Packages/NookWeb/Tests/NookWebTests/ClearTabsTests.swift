// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookTabsCore
@testable import NookWeb

@MainActor
struct ClearTabsTests {
    @Test func clearKeepsEveryOpenWindowsSelectionAndVisibleSplit() throws {
        let host = try Host()
        defer { host.cleanup() }
        let spaceID = try #require(host.window.spaceID)
        let section = Parent.tabs(spaceID: spaceID)
        let other = BrowserWindowState()
        host.registry.register(other)
        host.tabs.attach(window: other)
        other.spaceID = spaceID

        func open(_ name: String, in parent: Parent) throws -> UUID {
            try #require(host.tabs.open(url: URL(string: "https://\(name).invalid")!, in: host.window,
                                        placement: .background, parent: parent))
        }

        let root = try open("root", in: section)
        let child = try open("child", in: .folder(itemID: root))
        let selected = try open("grandchild", in: .folder(itemID: child))
        let sibling = try open("sibling", in: .folder(itemID: root))
        let panes = try (0..<SplitRecord.maxPanes).map { try open("pane\($0)", in: section) }
        let loose = try open("loose", in: section)
        let looseChild = try open("loose-child", in: .folder(itemID: loose))
        let hidden = try open("hidden", in: section)
        let pinned = try open("pinned", in: .pinned(spaceID: spaceID))
        let folder = try #require(host.tabs.createFolder(title: "Folder", in: section, after: nil))
        let folderTab = try open("folder-tab", in: .folder(itemID: folder))
        host.tabs.select(selected, in: host.window)
        host.window.split = try #require(SplitRecord([loose, hidden]))
        let split = try #require(SplitRecord(panes))
        try #require(host.tabs.presentNativeSplit(split, activeItemID: panes[1], in: other))

        let targets = host.tabs.tabsToClear(in: spaceID)
        #expect(Set(targets).isSuperset(of: [loose, hidden]))
        let protected = [root, child, selected, sibling, pinned, folder, folderTab] + panes
        #expect(Set(targets).isDisjoint(with: protected))

        host.tabs.clearTabs(in: spaceID)

        #expect(host.tabs.tree.item(loose) == nil)
        #expect(host.tabs.tree.item(looseChild) == nil)
        #expect(host.tabs.tree.item(hidden) == nil)
        #expect(protected.allSatisfy { host.tabs.tree.item($0) != nil })
        #expect(host.window.selectedItemID == selected)
        #expect(other.selectedItemID == panes[1])
        #expect(other.split == split)
        #expect(host.tabs.tabsToClear(in: spaceID).isEmpty)
    }

    @Test func clearKeepsThePrivateWindowsOwnSelection() throws {
        let host = try Host(isPrivate: true)
        defer { host.cleanup() }
        let spaceID = try #require(host.window.spaceID)
        let section = Parent.tabs(spaceID: spaceID)
        let selected = try #require(host.tabs.open(url: URL(string: "https://selected.invalid")!, in: host.window,
                                                   placement: .newTab, parent: section))
        let loose = try #require(host.tabs.open(url: URL(string: "https://loose.invalid")!, in: host.window,
                                                placement: .background, parent: section))

        #expect(host.tabs.tabsToClear(in: spaceID) == [loose])
        host.tabs.clearTabs(in: spaceID)

        #expect(host.window.selectedItemID == selected)
        #expect(host.window.privateTree?.item(selected) != nil)
        #expect(host.window.privateTree?.item(loose) == nil)
    }
}
