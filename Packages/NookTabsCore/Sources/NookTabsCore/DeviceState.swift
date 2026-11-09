// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// State that belongs to this Mac only and never syncs.
public struct DeviceState: Codable, Equatable, Sendable {
    public static let closedLimit = 50
    /// Tabs the archive sweep closed, kept apart so a big sweep never pushes out what the person
    /// closed themselves.
    public static let archivedLimit = 200

    public var openFolders: Set<UUID> = []
    /// Live pages of synced tabs, plus unresolved device-local searches for cold tabs.
    public var openPages: [UUID: OpenPage] = [:]
    public var windows: [WindowRecord] = []
    /// Newest last.
    public var closed: [ClosedEntry] = []
    public var firstLaunchCompleted = false
    /// Pages the person removed from a live folder, by folder id, so a refresh leaves them out.
    /// Optional because files written before live folders have no such key.
    public var liveDismissed: [UUID: Set<URL>]?
    /// The tab whose page opened each link tab that is not its child, so Back can return to it.
    /// Optional because files written before opener records have no such key.
    public var openers: [UUID: UUID]?
    /// When each normal tab was last selected or left, for archiving tabs left unseen.
    public var lastSeen: [UUID: Date]?
    /// Newest last. Optional because files written before archiving have no such key.
    public var archived: [ClosedEntry]?
    /// Profiles no space uses, kept with their website data, oldest first. Optional because files
    /// written before kept profiles have no such key.
    public var keptProfiles: [KeptProfile]?
    /// A single regular-profile deletion, durable before native cleanup starts.
    /// Retained after interruption or post-mark failure so the identity cannot be reused.
    public var pendingProfileDeletion: PendingProfileDeletion?

    public init() {}

    public mutating func keep(_ profile: ProfileSummary) {
        var list = keptProfiles ?? []
        list.removeAll { $0.id == profile.id }
        list.append(KeptProfile(profile))
        keptProfiles = list
    }

    public mutating func dropKeptProfile(_ id: UUID) {
        keptProfiles?.removeAll { $0.id == id }
    }

    public mutating func pushClosed(_ entry: ClosedEntry) {
        closed.append(entry)
        if closed.count > Self.closedLimit { closed.removeFirst(closed.count - Self.closedLimit) }
    }

    public mutating func pushArchived(_ entry: ClosedEntry) {
        var list = archived ?? []
        list.append(entry)
        if list.count > Self.archivedLimit { list.removeFirst(list.count - Self.archivedLimit) }
        archived = list
    }

    /// What Reopen Closed Tab brings back: the newer of the last closed and last archived entry.
    public var newestClosed: ClosedEntry? {
        guard let archivedLast = archived?.last else { return closed.last }
        guard let closedLast = closed.last else { return archivedLast }
        return archivedLast.closedAt > closedLast.closedAt ? archivedLast : closedLast
    }

    public mutating func dropNewestClosed() {
        guard let newest = newestClosed else { return }
        if newest == closed.last { closed.removeLast() } else { archived?.removeLast() }
    }

    /// Drops entries holding any of `ids` from both lists. True when something was dropped.
    @discardableResult
    public mutating func dropClosed(containing ids: Set<UUID>) -> Bool {
        let before = closed.count + (archived?.count ?? 0)
        closed.removeAll { entry in entry.items.contains { ids.contains($0.id) } }
        archived?.removeAll { entry in entry.items.contains { ids.contains($0.id) } }
        return closed.count + (archived?.count ?? 0) != before
    }

    /// Drops references to items and spaces that no longer exist.
    public mutating func prune(against tree: TabTree) {
        openFolders = openFolders.filter { tree.item($0)?.isFolder == true || tree.hasChildren($0) }
        openPages = openPages.filter { tree.item($0.key) != nil && (tree.scope(of: $0.key) == .synced || $0.value.pendingSearch != nil) }
        liveDismissed = liveDismissed?.filter { tree.item($0.key)?.live != nil }
        openers = openers?.filter { tree.item($0.key) != nil && tree.item($0.value) != nil }
        lastSeen = lastSeen?.filter { tree.item($0.key) != nil }
        let usedStores = Set(tree.profiles.map(\.id))
        keptProfiles = keptProfiles?.filter { !usedStores.contains($0.id) }
        for i in windows.indices {
            if let spaceID = windows[i].spaceID, tree.space(spaceID) == nil { windows[i].spaceID = nil }
            windows[i].selectedItemBySpace = windows[i].selectedItemBySpace.filter { tree.space($0.key) != nil && tree.item($0.value) != nil }
            if let split = windows[i].split {
                windows[i].split = split.itemIDs.filter { tree.item($0) == nil }.reduce(split) { $0?.removing($1) }
            }
        }
    }
}

public struct PendingProfileDeletion: Codable, Equatable, Sendable {
    public let target: UUID
    public let survivor: UUID
    /// Nil is the original kept-profile deletion protocol.
    public var change: PendingProfileChange?

    public init(target: UUID, survivor: UUID, change: PendingProfileChange? = nil) {
        self.target = target
        self.survivor = survivor
        self.change = change
    }
}

/// The existing single profile intent also carries a bounded assignment change.
/// No tab contents are serialized or cloned; item and saved-window IDs survive.
public struct PendingProfileChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case deleteProfile, reassignSpace }
    public enum Phase: String, Codable, Sendable {
        case prepared, closeAdmitted, assignmentCommitted
    }

    public let id: UUID
    public let kind: Kind
    public let spaceIDs: [UUID]
    public let source: KeptProfile
    public let newDestination: KeptProfile?
    public let windowIDs: Set<UUID>
    public var phase: Phase

    public init(kind: Kind, spaceIDs: [UUID], source: KeptProfile,
                newDestination: KeptProfile? = nil, windowIDs: Set<UUID>,
                phase: Phase = .prepared) {
        id = UUID()
        self.kind = kind
        self.spaceIDs = spaceIDs
        self.source = source
        self.newDestination = newDestination
        self.windowIDs = windowIDs
        self.phase = phase
    }
}

public struct OpenPage: Codable, Hashable, Sendable {
    public var url: URL
    public var title: String
    /// Unresolved native query, device-local and credential-free. Nil on older records.
    public var pendingSearch: String?

    public init(url: URL, title: String, pendingSearch: String? = nil) {
        self.url = url
        self.title = title
        self.pendingSearch = pendingSearch
    }
}

public struct WindowRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var spaceID: UUID?
    public var selectedItemBySpace: [UUID: UUID]
    public var split: SplitRecord?
    /// `NSStringFromRect` of the window frame, restored by the app.
    public var frame: String?

    public init(id: UUID = UUID(), spaceID: UUID? = nil, selectedItemBySpace: [UUID: UUID] = [:], split: SplitRecord? = nil, frame: String? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.selectedItemBySpace = selectedItemBySpace
        self.split = split
        self.frame = frame
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        spaceID = try container.decodeIfPresent(UUID.self, forKey: .spaceID)
        selectedItemBySpace = try container.decode([UUID: UUID].self, forKey: .selectedItemBySpace)
        split = try? container.decodeIfPresent(SplitRecord.self, forKey: .split)
        frame = try container.decodeIfPresent(String.self, forKey: .frame)
    }
}
