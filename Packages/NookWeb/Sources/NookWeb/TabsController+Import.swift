// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore

extension TabsController {
    /// A tab or folder another browser had.
    public indirect enum ImportedItem: Equatable, Sendable {
        case tab(url: URL, title: String?, customTitle: String?)
        case folder(title: String, children: [ImportedItem])

        /// This item and everything inside it.
        public var count: Int {
            switch self {
            case .tab: 1
            case .folder(_, let children): 1 + children.reduce(0) { $0 + $1.count }
            }
        }
    }

    /// Adds `items` in their order at the top of `parent`, without loading a page and without an
    /// undo step. Folders come in closed. A folder the tree cannot hold where it goes (in
    /// favorites, or past the depth limit) gives its items to its own parent. The work runs in
    /// slices of about `slice`, and the main actor runs between them; `progress` hears how many
    /// tabs and folders are done. Cancelling stops between slices. Returns how many tabs came in.
    @discardableResult
    public func importTree(_ items: [ImportedItem], into parent: Parent, slice: Duration = .milliseconds(50),
                           progress: (Int) -> Void = { _ in }) async throws -> Int {
        let owner: Owner?
        switch parent {
        case .favorites(let spaceID), .pinned(let spaceID), .tabs(let spaceID): owner = self.owner(ofSpace: spaceID)
        case .folder(let folderID): owner = self.owner(ofItem: folderID)
        }
        guard let owner else { return 0 }
        var frames: [(items: [ImportedItem], index: Int, parent: Parent, after: UUID?)] = [(items, 0, parent, nil)]
        var tabs = 0, done = 0

        func step(_ tree: inout TabTree, _ change: inout Change) {
            let top = frames.count - 1
            guard frames[top].index < frames[top].items.count else {
                frames.removeLast()
                return
            }
            let id = UUID()
            switch frames[top].items[frames[top].index] {
            case let .tab(url, title, customTitle):
                frames[top].index += 1
                done += 1
                guard let created = try? tree.createTab(id: id, url: url, title: title ?? url.host ?? url.absoluteString,
                                                        in: frames[top].parent, after: frames[top].after) else { return }
                change.merge(created)
                if let customTitle, let renamed = try? tree.rename(id, customTitle: customTitle) { change.merge(renamed) }
                frames[top].after = id
                tabs += 1
            case let .folder(title, children):
                done += 1
                if let created = try? tree.createFolder(id: id, title: title, in: frames[top].parent, after: frames[top].after) {
                    change.merge(created)
                    frames[top].index += 1
                    frames[top].after = id
                    frames.append((children, 0, .folder(itemID: id), nil))
                } else {
                    frames[top].items.replaceSubrange(frames[top].index...frames[top].index, with: children)
                }
            }
        }

        let clock = ContinuousClock()
        while !frames.isEmpty {
            if done > 0 { try await Task.sleep(for: .milliseconds(1)) }
            let deadline = clock.now + slice
            guard perform(owner, "importTree", undoable: false, { tree in
                var change = Change()
                repeat { step(&tree, &change) } while !frames.isEmpty && clock.now < deadline
                return change
            }) != nil else { break }
            progress(done)
        }
        return tabs
    }
}
