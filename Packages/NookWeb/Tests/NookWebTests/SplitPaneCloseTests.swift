// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookTabsCore
@testable import NookWeb

/// Closing a pane's tab, as Cmd+W or the pane's close button do, takes that pane out of the split:
/// the pane beside it takes the selection, and with one pane left the split ends.
@MainActor
struct SplitPaneCloseTests {
    @Test func closingAPaneKeepsTheOtherPanes() throws {
        let host = try Host(); defer { host.cleanup() }
        let spaceID = try #require(host.window.spaceID)
        let panes = try (0..<3).map { index in
            try #require(host.tabs.open(url: URL(string: "https://pane\(index).invalid")!, in: host.window,
                                        placement: .background, parent: .tabs(spaceID: spaceID)))
        }
        let split = try #require(SplitRecord(panes))
        try #require(host.tabs.presentNativeSplit(split, activeItemID: panes[1], in: host.window))
        try #require(host.window.split == split)

        host.tabs.close(panes[1])
        try #require(host.native.closes.count == 1)
        host.native.finishClose(0, admitted: true)
        #expect(host.window.split?.itemIDs == [panes[0], panes[2]])
        #expect(host.window.selectedItemID == panes[2], "the next pane takes the selection")

        host.tabs.close(panes[0])
        try #require(host.native.closes.count == 2)
        host.native.finishClose(1, admitted: true)
        #expect(host.window.split == nil, "one tab left is no split")
        #expect(host.window.selectedItemID == panes[2], "a pane that is not selected leaves the selection alone")
    }

    @Test func closingTheLastPaneSelectsThePaneBeforeIt() throws {
        let host = try Host(); defer { host.cleanup() }
        let spaceID = try #require(host.window.spaceID)
        let panes = try (0..<2).map { index in
            try #require(host.tabs.open(url: URL(string: "https://pane\(index).invalid")!, in: host.window,
                                        placement: .background, parent: .tabs(spaceID: spaceID)))
        }
        let split = try #require(SplitRecord(panes))
        try #require(host.tabs.presentNativeSplit(split, activeItemID: panes[1], in: host.window))
        try #require(host.window.split == split)

        host.tabs.close(panes[1])
        try #require(host.native.closes.count == 1)
        host.native.finishClose(0, admitted: true)
        #expect(host.window.split == nil)
        #expect(host.window.selectedItemID == panes[0])
    }
}
