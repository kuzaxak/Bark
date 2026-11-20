// Licensed under GPL-3.0. See LICENSE.
//
//  ItemFavicon.swift
//  NookUI
//
//  The favicon every row and tile draws, and the inline-rename state the rows and the
//  context menu share.
//

import SwiftUI
import NookTabsCore
import NookWeb

// MARK: - Rename State

/// The row being renamed inline. Shared so a context menu can start a rename on its row.
@MainActor
@Observable
public final class SidebarRenameState {
    public static let shared = SidebarRenameState()
    public var itemID: UUID?
}

/// Selects the whole name once a rename field has focus, so typing replaces it, as in Arc.
@MainActor
func selectAllInRenameField() {
    #if os(macOS)
    DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
    #endif
}

extension TabsController {
    /// Creates a "New Folder" under `parent` after `after` and starts renaming it inline.
    public func createFolderForRename(in parent: Parent, after: UUID?) {
        guard let folderID = createFolder(title: "New Folder", in: parent, after: after) else { return }
        if case .folder(let outer) = parent { openFolder(outer) }
        SidebarRenameState.shared.itemID = folderID
    }
}

// MARK: - Favicon

/// A row or tile favicon, available for a saved page before it loads.
public struct ItemFavicon: View {
    let item: Item
    @Environment(TabsController.self) private var tabs

    public init(item: Item) {
        self.item = item
    }

    public var body: some View {
        tabs.favicon(for: item)
            .resizable()
            .scaledToFit()
    }
}
