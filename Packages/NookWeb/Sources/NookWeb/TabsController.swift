// Licensed under GPL-3.0. See LICENSE.
//
//  TabsController.swift
//  Nook
//
//  The app side of the tab model. Owns the TabTree, DeviceState, TabStore and the live page
//  sessions, and exposes the intents the sidebar, commands, extensions and AI tools call.
//  Window selection lives on BrowserWindowState and is mirrored into DeviceState.windows.
//  Private windows keep their own in-memory tree and sessions on BrowserWindowState.
//

import Foundation
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
import OSLog

@MainActor
@Observable
public final class TabsController {
    public enum Placement { case newTab, background, replaceCurrent }

    public static let homeURL = URL(string: "https://www.google.com")!
    static let undoLimit = 100

    // MARK: - State

    public private(set) var tree: TabTree {
        didSet {
            mainChildren = nil
            mainRows = [:]
            invalidateNativeLiveRequests()
        }
    }
    public private(set) var device: DeviceState {
        didSet { invalidateNativeLiveRequests() }
    }
    @ObservationIgnored private var mainChildren: [Parent: [Item]]?
    @ObservationIgnored private var mainRows: [UUID: (openFolders: Set<UUID>, rows: [Row])] = [:]
    /// How many times the main tree's items were grouped by parent for sidebar rows; tests read it.
    @ObservationIgnored private(set) var treeWalks = 0
    @ObservationIgnored private(set) var nativeOwnershipVisits = 0
    public let loadOutcome: LoadOutcome
    public let directory: URL
    var isReadOnly: Bool {
        if case .readOnly = loadOutcome { return true }
        return false
    }

    /// Sessions for items in the main tree, by item id. Private sessions live on their window.
    private var liveSessions: [UUID: PageSession] = [:]
    /// The window that last selected or claimed each page. A page has one live view; other
    /// windows showing the same item show a placeholder instead. In memory only.
    private var pageOwners: [UUID: UUID] = [:]
    /// Each window's mini player as last logged, so it is logged only when it changes.
    @ObservationIgnored private var miniPlayerLogged: [UUID: String] = [:]
    /// Open folders of private windows, kept apart so their ids never reach device.json.
    private var privateOpenFolders: Set<UUID> = []
    /// Live folders whose last refresh failed, and why. No entry when it worked.
    public internal(set) var liveStatus: [UUID: LiveFolderStatus] = [:]
    @ObservationIgnored var liveRefreshed: [UUID: Date] = [:]
    @ObservationIgnored var liveRefreshTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var liveNativeRefreshTail: Task<Void, Never>?
    var liveRefreshing: Set<UUID> { Set(liveRefreshTasks.keys) }
    /// App-injected exact regular-profile transport. Nil is explicitly unavailable.
    @ObservationIgnored public var nativeLiveFetch: ProfileLiveFetch?
    @ObservationIgnored var nativeLiveRequestOwners: [UUID: () -> Bool] = [:]
    @ObservationIgnored private var archiveTimer: Timer?
    /// The tab DevMCP page tools act on, in the Agent space (see `TabsController+Agent.swift`).
    public internal(set) var agentItemID: UUID?
    /// DevMCP tool calls running now; the sidebar's agent row pulses while it is above zero.
    public var agentCallsInFlight = 0
    /// The agent's page changed or lost its window; the app keeps it rendering.
    @ObservationIgnored public var onAgentPage: ((PageSession) -> Void)?

    /// One `Profile` (website data store) per space, made on first use and kept for the session.
    @ObservationIgnored private var spaceProfiles: [UUID: Profile] = [:]

    @ObservationIgnored public var onDeleteProfile: ProfileDeletionAction?
    /// Tells the person why a space could not be deleted.
    @ObservationIgnored public var onSpaceDeletionNotice: ((String) -> Void)?
    @ObservationIgnored public var onProfileWindowsNeedReload: (@MainActor (Set<UUID>) -> Void)?
    @ObservationIgnored private var profileDeletionInFlight = false {
        didSet { invalidateNativeLiveRequests() }
    }
    @ObservationIgnored private let store: TabStore
    @ObservationIgnored private(set) var undoStack: [Change] = []
    @ObservationIgnored private(set) var isTerminating = false {
        didSet { invalidateNativeLiveRequests() }
    }
    @ObservationIgnored public let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Tabs")

    // MARK: - Injected

    @ObservationIgnored public let settings: NookSettingsService
    @ObservationIgnored public let windowRegistry: WindowRegistry
    @ObservationIgnored public let blocker: ContentBlockerManager
    @ObservationIgnored public let siteRouting: SiteRoutingManager
    /// Set once the SwiftData context has produced it; nil in a host without history.
    @ObservationIgnored public var history: HistoryManager?
    @ObservationIgnored public weak var nativePageHost: (any NativePageHost)? {
        didSet {
            guard nativePageHost != nil else { return }
            for window in allWindows {
                if let itemID = window.selectedItemID { select(itemID, in: window) }
            }
        }
    }
    @ObservationIgnored public weak var sessionDelegate: PageSessionDelegate?
    @ObservationIgnored public weak var tabEvents: TabEventObserver?
    #if os(macOS)
    /// Pawl Vault passwords and passkeys; set by the app.
    @ObservationIgnored public var vault: VaultService?
    #endif
    /// Called with each tab that a move brought into a pinned section from the tabs section.
    @ObservationIgnored public var onTabsPinned: (([UUID]) -> Void)?
    /// A window is about to show another tab instead of this one, which is still on screen.
    @ObservationIgnored public var onLeavingTab: ((UUID, BrowserWindowState) -> Void)?
    /// A page let go of its web views: unloaded, or closed, in a private window too.
    @ObservationIgnored public var onPageUnloaded: ((UUID) -> Void)?
    /// The engine Settings chose for page translation. Set by the app, which owns the AI
    /// providers; pages translate on device without it.
    @ObservationIgnored public var pageTranslation: (() -> PageTranslationSetting)?
    /// AI page translations, one store per profile, beside the tab state.
    @ObservationIgnored public let translationCaches: TranslationCaches
    @ObservationIgnored let siteFavicons: SiteFaviconCache
    /// A page started loading with no window showing it: a link opened in the background.
    @ObservationIgnored public var onPageLoadedInBackground: ((PageSession) -> Void)?
    /// The main tree changed; space sync reads it to find what to send.
    @ObservationIgnored public var onTreeChanged: (() -> Void)?
    /// A released native owner may allow an inbound sync edit to be retried.
    @ObservationIgnored public var onNativeSyncAdmissionChanged: (() -> Void)?

    /// App-owned profile presentation; absent presenters report unavailability.
    @ObservationIgnored public var onOpenProfilePage: ProfilePageAction?
    @ObservationIgnored public var onProfileSearch: ProfileSearchAction?

    /// Launch argument that redirects tab state, e.g. `-NookStateDir /tmp/bench`.
    /// Read from the argument domain only, never from persisted defaults, so a stray written
    /// key can never silently point a real user's session somewhere else.
    nonisolated public static let stateDirArgument = "NookStateDir"

    nonisolated public static var defaultDirectory: URL {
        // Every build shares one bundle id, so a benchmark or scripted run would otherwise write
        // over a real session's tabs. This gives such a run a throwaway directory to use.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let override = arguments[stateDirArgument] as? String, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("Tabs", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Nook", isDirectory: true)
            .appendingPathComponent("Tabs", isDirectory: true)
    }

    // MARK: - Load

    public init(
        settings: NookSettingsService,
        windowRegistry: WindowRegistry,
        blocker: ContentBlockerManager,
        siteRouting: SiteRoutingManager,
        history: HistoryManager? = nil,
        legacyProfiles: [(id: UUID, name: String)] = [],
        /// A tree built from a pre-1.1 store; asked for only on a first launch.
        legacyTree: () -> TabTree? = { nil },
        directory: URL = TabsController.defaultDirectory
    ) {
        self.settings = settings
        self.windowRegistry = windowRegistry
        self.blocker = blocker
        self.siteRouting = siteRouting
        self.history = history
        self.directory = directory
        siteFavicons = SiteFaviconCache(directory: directory)
        translationCaches = TranslationCaches(directory: directory.deletingLastPathComponent().appendingPathComponent("TranslationCache", isDirectory: true))
        let store = TabStore(directory: directory)
        self.store = store
        let loaded = store.load()
        loadOutcome = loaded.outcome
        switch loaded.outcome {
        case .firstLaunch, .readOnly:
            // Read-only still needs a working sidebar; the store writes nothing this session.
            if case .firstLaunch = loaded.outcome, let imported = legacyTree() {
                tree = imported
                log.info("Imported \(imported.orderedSpaces.count) spaces and \(imported.items.count) items from the legacy store")
            } else {
                tree = Self.seed(from: legacyProfiles)
            }
            device = DeviceState()
            device.firstLaunchCompleted = true
        case .loaded, .restoredFromBackup:
            tree = loaded.tree
            device = loaded.device
            // A quit ends live pages, so bookmarks start at home. Cold searches
            // have not navigated yet and retain only their device-local intent.
            device.openPages = device.openPages.filter { $0.value.pendingSearch != nil }
        }
        log.info("Tabs loaded: \(String(describing: loaded.outcome), privacy: .public), \(self.tree.items.count) items")
        if case .readOnly(let reason) = loaded.outcome {
            log.error("Tabs are read-only: \(reason, privacy: .public)")
        }
        if case .firstLaunch = loaded.outcome { save() }
        if !loaded.migratedSpaceIDs.isEmpty {
            log.info("Merged profiles into \(self.tree.orderedSpaces.count) spaces")
        }
        NotificationCenter.default.addObserver(forName: appDidBecomeActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLiveFolders()
                self?.archiveStaleTabs()
            }
        }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.archiveStaleTabs() }
        }
    }

    /// Seeds one space and tab for each legacy profile, preserving its UUID.
    public static func seed(from legacyProfiles: [(id: UUID, name: String)], now: Date = Date()) -> TabTree {
        guard !legacyProfiles.isEmpty else { return TabTree.firstLaunch(homeURL: homeURL, now: now) }
        var tree = TabTree()
        for profile in legacyProfiles {
            tree.createSpace(id: profile.id, name: profile.name, icon: "house", accentHex: "#7C7C7C",
                             after: tree.orderedSpaces.last?.id, now: now)
            do {
                try tree.createTab(url: homeURL, title: "Google", in: .tabs(spaceID: profile.id), after: nil, now: now)
            } catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Tabs").error("Seeding space failed: \(String(describing: error), privacy: .public)")
            }
        }
        return tree
    }

    // MARK: - Save and Undo

    public func save() {
        store.save(tree, device)
    }

    /// Writes the queued state now and waits for it, so state kept about the tree elsewhere is
    /// never newer on disk than the tree.
    public func saveNow() {
        store.save(tree, device)
        store.flush()
        siteFavicons.flush()
    }


    func nativeSyncAdmissionChanged() {
        Task { @MainActor [weak self] in
            guard let self, !self.isTerminating else { return }
            self.onNativeSyncAdmissionChanged?()
        }
    }

    func persistSyncedTree() -> Bool {
        guard !isReadOnly else { return false }
        saveNow()
        return store.lastError == nil
    }

    /// Writes now, with every regular window's current frame. Called at quit; windows closing
    /// afterwards keep their records so they all reopen.
    public func flushSync() {
        isTerminating = true
        for task in liveRefreshTasks.values { task.cancel() }
        for window in regularWindows { mirror(window) }
        store.save(tree, device)
        store.flush()
        siteFavicons.flush()
    }

    /// A late native beforeunload veto reversed an accepted app-close phase.
    /// Existing records remain authoritative; no saved-window snapshot/replay.
    public func resumeAfterCancelledTermination() { isTerminating = false }

    func pushUndo(_ change: Change) {
        guard !change.isEmpty else { return }
        undoStack.append(change)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
    }

    /// Where an item or space lives.
    enum Owner {
        case main
        case privateWindow(BrowserWindowState)
    }

    public var allWindows: [BrowserWindowState] {
        Array(windowRegistry.windows.values)
    }

    public var privateWindows: [BrowserWindowState] { allWindows.filter { $0.privateTree != nil } }

    public var regularWindows: [BrowserWindowState] { allWindows.filter { $0.privateTree == nil } }

    func owner(ofItem id: UUID) -> Owner? {
        if tree.item(id) != nil { return .main }
        return privateWindows.first { $0.privateTree?.item(id) != nil }.map(Owner.privateWindow)
    }

    func owner(ofSpace id: UUID) -> Owner? {
        if tree.space(id) != nil { return .main }
        return privateWindows.first { $0.privateTree?.space(id) != nil }.map(Owner.privateWindow)
    }

    func owner(of window: BrowserWindowState) -> Owner {
        window.privateTree != nil ? .privateWindow(window) : .main
    }

    func tree(_ owner: Owner) -> TabTree {
        switch owner {
        case .main: return tree
        case .privateWindow(let window): return window.privateTree ?? TabTree()
        }
    }

    /// Runs one tree edit. Main-tree edits push their undo change and save; private edits never save.
    /// Tree errors are logged and leave state unchanged.
    @discardableResult
    func perform(_ owner: Owner, _ label: String, undoable: Bool = true, _ body: (inout TabTree) throws -> Change) -> Change? {
        do {
            switch owner {
            case .main:
                var copy = tree
                let change = try body(&copy)
                guard profileDeletionAllows(copy, changed: change) else { return nil }
                let ownershipChanged = nativeOwnershipChanged(by: change, in: copy)
                guard !ownershipChanged || nativeEditIsAdmissible(copy, owner: owner) else { return nil }
                tree = copy
                if ownershipChanged { cancelInvalidNativeCreations() }
                if undoable { pushUndo(change) }
                device.prune(against: tree)
                save()
                if !change.isEmpty { onTreeChanged?() }
                return change
            case .privateWindow(let window):
                var copy = window.privateTree ?? TabTree()
                let change = try body(&copy)
                let ownershipChanged = nativeOwnershipChanged(by: change, in: copy)
                guard !ownershipChanged || nativeEditIsAdmissible(copy, owner: owner) else { return nil }
                window.privateTree = copy
                if ownershipChanged { cancelInvalidNativeCreations() }
                return change
            }
        } catch {
            log.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Reads

    public func space(_ id: UUID) -> SpaceRecord? {
        owner(ofSpace: id).flatMap { tree($0).space(id) }
    }

    public var orderedSpaces: [SpaceRecord] { tree.orderedSpaces }

    /// The spaces a window can move a tab to: its own temporary one when private, else all of them.
    public func spaces(visibleIn window: BrowserWindowState?) -> [SpaceRecord] {
        guard let window else { return orderedSpaces }
        return tree(owner(of: window)).orderedSpaces
    }

    public func item(_ id: UUID) -> Item? {
        owner(ofItem: id).flatMap { tree($0).item(id) }
    }

    /// Whether `window` shows the tree holding `id`: a private window its own, every regular window the shared one.
    public func holds(_ id: UUID, in window: BrowserWindowState) -> Bool {
        switch (owner(ofItem: id), owner(of: window)) {
        case (.main, .main): return true
        case (.privateWindow(let holder), .privateWindow(let shown)): return holder === shown
        default: return false
        }
    }

    public func children(of parent: Parent) -> [Item] {
        treeHolding(parent).children(of: parent)
    }

    /// The favorites a space shows, shared with every space that uses its data store.
    public func favorites(of spaceID: UUID) -> [Item] {
        owner(ofSpace: spaceID).map { tree($0).favorites(of: spaceID) } ?? []
    }

    public func rows(space spaceID: UUID, in window: BrowserWindowState) -> [Row] {
        let visible = rows(space: spaceID)
        guard window.spaceID == spaceID, let selected = window.selectedItemID,
              let owner = owner(ofSpace: spaceID) else { return visible }
        return tree(owner).revealingSelectedTab(selected, in: visible, openFolders: openFolders(owner))
    }

    public func rows(space spaceID: UUID) -> [Row] {
        guard let owner = owner(ofSpace: spaceID) else { return [] }
        let open = openFolders(owner)
        guard case .main = owner else { return tree(owner).visibleRows(space: spaceID, openFolders: open) }
        if let walked = mainRows[spaceID], walked.openFolders == open { return walked.rows }

        let children = mainChildren ?? {
            treeWalks += 1
            let children = tree.childrenByParent()
            mainChildren = children
            return children
        }()
        let rows = tree.visibleRows(space: spaceID, openFolders: open, children: children)
        mainRows[spaceID] = (open, rows)
        return rows
    }

    public func section(of itemID: UUID) -> Parent? {
        owner(ofItem: itemID).flatMap { tree($0).section(of: itemID) }
    }

    public func spaceID(of itemID: UUID) -> UUID? {
        owner(ofItem: itemID).flatMap { tree($0).spaceID(of: itemID) }
    }

    /// Live tabs in every section of a space: its favorites, pinned tabs and tabs.
    public func items(inSpace spaceID: UUID) -> [Item] {
        guard let owner = owner(ofSpace: spaceID) else { return [] }
        let source = tree(owner)
        return source.items.values.filter { item in
            item.deletedAt == nil && !item.isFolder && source.spaceID(of: item.id) == spaceID
        }
    }

    public func isOpen(folder: UUID) -> Bool {
        device.openFolders.contains(folder) || privateOpenFolders.contains(folder)
    }

    /// A synced tab whose open page's host and path differ from its home URL.
    public func hasLeftHome(_ itemID: UUID) -> Bool {
        guard let owner = owner(ofItem: itemID), let item = tree(owner).item(itemID),
              tree(owner).scope(of: itemID) == .synced, let home = item.url else { return false }
        let current: URL?
        switch owner {
        case .main: current = device.openPages[itemID]?.url ?? liveSessions[itemID]?.url
        case .privateWindow(let window): current = window.privateSessions[itemID]?.url
        }
        guard let current else { return false }
        return current.host?.lowercased() != home.host?.lowercased() || Self.normalizedPath(current) != Self.normalizedPath(home)
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    var canReopenClosed: Bool { device.newestClosed != nil }

    func treeHolding(_ parent: Parent) -> TabTree {
        switch parent {
        case .favorites(let spaceID), .pinned(let spaceID), .tabs(let spaceID):
            return owner(ofSpace: spaceID).map(tree) ?? tree
        case .folder(let itemID):
            return owner(ofItem: itemID).map(tree) ?? tree
        }
    }

    func openFolders(_ owner: Owner) -> Set<UUID> {
        switch owner {
        case .main: return device.openFolders
        case .privateWindow: return privateOpenFolders
        }
    }

    // MARK: - Sessions

    public func session(for itemID: UUID) -> PageSession? {
        if let session = liveSessions[itemID] { return session }
        for window in privateWindows {
            if let session = window.privateSessions[itemID] { return session }
        }
        return nil
    }

    public var sessions: [PageSession] {
        Array(liveSessions.values) + privateWindows.flatMap { $0.privateSessions.values }
    }

    /// Existing sessions in the regular tab tree. Reading diagnostics must never create a profile or page.
    public var regularDiagnosticSessions: [PageSession] {
        liveSessions.values.filter { page in
            guard !page.isPrivate, page.detachedProfile?.isEphemeral != true,
                  let space = tree.spaceID(of: page.itemID),
                  let store = tree.dataStoreID(for: space) else { return false }
            guard isProfileAvailable(store), profileSpaceIsReady(space),
                  page.detachedProfile.map({ $0.id == store }) ?? true else { return false }
            return page.navigation.map { $0.profileID == store } ?? true
        }
    }

    public func selectedItemID(in window: BrowserWindowState) -> UUID? {
        window.selectedItemID
    }

    public func selectedSession(in window: BrowserWindowState) -> PageSession? {
        window.selectedItemID.flatMap { session(for: $0) }
    }

    /// The active window's selected page, when that window holds the live page. Commands never
    /// reach a page another window holds; the user moves it first.
    public var activeWindowSession: PageSession? {
        windowRegistry.activeWindow.flatMap { controllableSession(in: $0) }
    }

    /// The window's selected page for actions (navigation, reload, find, zoom): nil while another
    /// window holds it. Display code uses `selectedSession(in:)`.
    public func controllableSession(in window: BrowserWindowState) -> PageSession? {
        guard !window.nativeSpaceSwitchIsUnresolved,
              let session = selectedSession(in: window), !isPageShownElsewhere(session.itemID, from: window) else { return nil }
        if window.nativeSpaceSwitchIsPending {
            guard let page = session.navigation, nativePageHost?.isNativeSelection(page, in: window) == true else { return nil }
        }
        return session
    }

    /// Favorites of the window's space, then its rows in sidebar order.
    public func displayOrder(in window: BrowserWindowState) -> [UUID] {
        window.spaceID.map(displayOrder(inSpace:)) ?? []
    }

    public func displayOrder(inSpace spaceID: UUID) -> [UUID] {
        guard let owner = owner(ofSpace: spaceID) else { return [] }
        let favorites = tree(owner).favorites(of: spaceID).map(\.id)
        return favorites + rows(space: spaceID).filter { !$0.item.isFolder }.map(\.item.id)
    }

    public func isVisibleInAnyWindow(_ itemID: UUID) -> Bool {
        allWindows.contains { window in
            window.selectedItemID == itemID || window.split?.contains(itemID) == true
        }
    }

    /// Visible somewhere, including a window's picture-in-picture, so not a candidate to unload.
    public func isOnScreen(_ itemID: UUID) -> Bool {
        isVisibleInAnyWindow(itemID) || allWindows.contains {
            ($0.sidebarPiPStorage as? PictureInPictureHolder)?.pictureInPictureItemID == itemID
        }
    }

    /// The session for an item, created when missing. A synced item opens its saved open page,
    /// else its home URL.
    public func ensureSession(for itemID: UUID) -> PageSession? {
        if let existing = session(for: itemID) { return existing }
        guard let owner = owner(ofItem: itemID), let item = tree(owner).item(itemID),
              case .tab(let homeURL, let pageTitle) = item.kind else { return nil }
        switch owner {
        case .main:
            let synced = tree.scope(of: itemID) == .synced
            let page = synced ? device.openPages[itemID] : nil
            let session = PageSession(
                itemID: itemID, url: page?.url ?? homeURL, title: page?.title ?? pageTitle,
                isPrivate: false, controller: self)
            liveSessions[itemID] = session
            session.restorePendingNativeSearch()
            if synced, page == nil {
                setOpenPage(itemID, OpenPage(url: homeURL, title: pageTitle))
            }
            return session
        case .privateWindow(let window):
            let session = PageSession(
                itemID: itemID, url: homeURL, title: pageTitle,
                isPrivate: true, controller: self)
            window.privateSessions[itemID] = session
            return session
        }
    }

    /// Removes and tears down a session without touching the tree.
    func endSession(_ itemID: UUID) {
        let session: PageSession?
        if let main = liveSessions.removeValue(forKey: itemID) {
            session = main
        } else if let window = privateWindows.first(where: { $0.privateSessions[itemID] != nil }) {
            session = window.privateSessions.removeValue(forKey: itemID)
        } else {
            session = nil
        }
        device.openPages[itemID] = nil
        guard let session else { return }
        session.tearDown()
    }

    /// The website data store of a space, made on first use and shared by every space that uses
    /// the same store (the Agent space borrows one). Its name and icon follow the space asked for.
    public func profile(forSpace spaceID: UUID) -> Profile? {
        guard let space = tree.space(spaceID), let storeID = tree.dataStoreID(for: spaceID),
              isProfileAvailable(storeID), profileSpaceIsReady(spaceID) else { return nil }
        if let existing = spaceProfiles[storeID] {
            if !space.isAgent {
                existing.name = space.name
                existing.icon = space.icon
            }
            return existing
        }
        let profile = Profile(id: storeID, name: space.name, icon: space.icon)
        spaceProfiles[storeID] = profile
        return profile
    }

    /// Every space's data store, made if it does not exist yet. For whole-app cleanup only.
    var allSpaceProfiles: [Profile] {
        var seen = Set<UUID>()
        return tree.orderedSpaces.compactMap { profile(forSpace: $0.id) }.filter { seen.insert($0.id).inserted }
    }

    /// A profile's data store by profile id: the one its spaces use, or a kept profile's.
    public func profile(forStore storeID: UUID) -> Profile? {
        guard isProfileAvailable(storeID) else { return nil }
        if let space = tree.orderedSpaces.first(where: { tree.dataStoreID(for: $0.id) == storeID }) {
            return profile(forSpace: space.id)
        }
        guard let kept = device.keptProfiles?.first(where: { $0.id == storeID }) else { return nil }
        if let existing = spaceProfiles[storeID] { return existing }
        let profile = Profile(id: storeID, name: kept.name, icon: "")
        spaceProfiles[storeID] = profile
        return profile
    }

    /// Drops a data store no space uses any more.
    func forgetProfile(_ storeID: UUID) {
        siteFavicons.removeProfile(storeID)
        spaceProfiles[storeID] = nil
        history?.deleteHistory(forProfile: storeID)
        device.dropKeptProfile(storeID)
        save()
    }

    /// Keeps a data store no space uses any more, with its history, for a space to use again.
    func keepProfile(_ profile: ProfileSummary) {
        device.keep(profile)
        save()
    }

    /// Changes a kept profile; false when no kept profile has `storeID`.
    func updateKeptProfile(_ storeID: UUID, _ update: (inout KeptProfile) -> Void) -> Bool {
        guard device.pendingProfileDeletion.map({ $0.target != storeID && $0.survivor != storeID }) ?? true else { return false }
        guard var kept = device.keptProfiles, let index = kept.firstIndex(where: { $0.id == storeID }) else { return false }
        update(&kept[index])
        device.keptProfiles = kept
        save()
        return true
    }

    /// The data store a session's page uses: the private window's ephemeral one, else the store
    /// of the space that owns the item's section.
    public func profile(for session: PageSession) -> Profile? {
        if session.isPrivate {
            return privateWindows.first { $0.privateSessions[session.itemID] === session }?.ephemeralProfile
        }
        return tree.spaceID(of: session.itemID).flatMap { profile(forSpace: $0) }
    }

    /// The window a session's actions belong to: its private window, else the active window
    /// when that window can show the item, else a window selecting it, else the active window.
    public func window(for session: PageSession) -> BrowserWindowState? {
        if let window = session.detachedWindow { return window }
        if session.isPrivate {
            return privateWindows.first { $0.privateSessions[session.itemID] === session }
        }
        let active = windowRegistry.activeWindow
        if let active, active.privateTree == nil, canShow(session.itemID, in: active) { return active }
        if let selecting = regularWindows.first(where: { $0.selectedItemID == session.itemID }) { return selecting }
        return active?.privateTree == nil ? active : regularWindows.first
    }

    /// Change stores the previous touched records; additions and metadata edits cannot
    /// invalidate an existing page's owner. Moving a folder can affect its descendants.
    func nativeOwnershipChanged(by change: Change, in proposed: TabTree) -> Bool {
        for (id, previous) in change.items {
            guard let previous, previous.deletedAt == nil else { continue }
            guard let current = proposed.item(id), current.parent == previous.parent else { return true }
        }
        for (id, previous) in change.spaces {
            guard let previous, previous.deletedAt == nil else { continue }
            guard let current = proposed.spaces[id], current.deletedAt == nil,
                  current.dataStoreID == previous.dataStoreID else { return true }
        }
        return false
    }

    /// A pending deletion locks only its two profile identities, not unrelated
    /// tabs/profiles. Keep the common no-deletion path constant-time.
    func profileDeletionAllows(_ proposed: TabTree, changed: Change) -> Bool {
        guard let intent = device.pendingProfileDeletion else { return true }
        if changed.spaces.isEmpty, intent.change == nil { return true }
        if let change = intent.change {
            if change.phase != .assignmentCommitted {
                for id in changed.items.keys {
                    let before = tree.spaceID(of: id), after = proposed.spaceID(of: id)
                    if before.map(change.spaceIDs.contains) == true || after.map(change.spaceIDs.contains) == true {
                        guard let old = tree.item(id), let new = proposed.item(id), before == after,
                              (old.url == nil) == (new.url == nil) else { return false }
                    }
                }
            }
            guard !changed.spaces.isEmpty else { return true }
            let current = tree.profiles, next = proposed.profiles
            guard change.spaceIDs.allSatisfy({ tree.space($0) == proposed.space($0) }),
                  current.first(where: { $0.id == intent.survivor }) == next.first(where: { $0.id == intent.survivor }) else { return false }
            if change.kind == .reassignSpace {
                let source = current.first(where: { $0.id == intent.target })
                let nextSource = next.first(where: { $0.id == intent.target })
                return source?.name == nextSource?.name && source?.searchEngineId == nextSource?.searchEngineId
            }
        }
        let current = tree.profiles, next = proposed.profiles
        return [intent.target, intent.survivor].allSatisfy { id in
            current.first(where: { $0.id == id }) == next.first(where: { $0.id == id })
        }
    }

    /// Synchronous tree/undo edits cannot bypass actual native close admission.
    /// Explicit close/remove release first; unsupported destructive replacements
    /// leave the current tree intact. Pending creations can still be canceled.
    func nativeEditIsAdmissible(_ proposed: TabTree, owner: Owner) -> Bool {
        for page in sessions {
            nativeOwnershipVisits += 1
            guard page.navigation != nil else { continue }
            guard let currentOwner = self.owner(ofItem: page.itemID) else { continue }
            let sameOwner: Bool
            switch (owner, currentOwner) {
            case (.main, .main): sameOwner = true
            case (.privateWindow(let a), .privateWindow(let b)): sameOwner = a === b
            default: sameOwner = false
            }
            guard sameOwner else { continue }
            guard proposed.item(page.itemID) != nil else { return false }
            let expectedProfile: UUID?
            switch owner {
            case .main:
                expectedProfile = proposed.spaceID(of: page.itemID).flatMap { proposed.dataStoreID(for: $0) }
            case .privateWindow(let window):
                expectedProfile = window.ephemeralProfile?.id
            }
            if page.navigation?.profileID != expectedProfile { return false }
        }
        return true
    }

    private func cancelInvalidNativeCreations() {
        for page in sessions {
            nativeOwnershipVisits += 1
            guard let pending = page.nativeCreation else { continue }
            if owner(ofItem: page.itemID) == nil || page.profile?.id != pending.profileID {
                page.cancelNativeCreation()
            }
        }
    }

    func cancelNativeSelection(for page: PageSession) {
        for window in allWindows where window.nativeSelectionSession === page {
            window.nativeSelectionGeneration = nil
            window.nativeSelectionSession = nil
        }
    }

    func prepareNativeSelection(_ itemID: UUID, in window: BrowserWindowState,
                                admitted: @escaping @MainActor () -> Void) {
        guard cancelNativeSplit(in: window) else { return }
        let previous = window.nativeSelectionSession
        let generation = UUID()
        window.nativeSelectionGeneration = generation
        window.nativeSelectionSession = nil
        if previous?.itemID != itemID { previous?.cancelNativePreparation(in: window) }
        guard window.nativeSelectionGeneration == generation else { return }
        guard let page = ensureSession(for: itemID), let profileID = page.profile?.id else {
            nativeSelectionFailed(in: window)
            return
        }
        window.nativeSelectionSession = page
        page.ensureNativePage(in: window) { [weak self, weak page, weak window] prepared in
            guard let self, let page, let window,
                  window.nativeSelectionGeneration == generation else { return }
            guard prepared, self.windowRegistry.windows[window.id] === window,
                  self.session(for: itemID) === page, page.profile?.id == profileID,
                  let navigation = page.navigation,
                  let host = (page.nativeResourceHost as? any NativePageHost) ?? self.nativePageHost else {
                if window.nativeSelectionGeneration == generation { self.nativeSelectionFailed(in: window) }
                return
            }
            // Capture before the host hides the outgoing native surface. A
            // synchronous completion may reenter selection, so revalidate below.
            if let leaving = self.selectedSession(in: window), leaving !== page {
                leaving.captureSwitcherSnapshot()
            }
            guard window.nativeSelectionGeneration == generation,
                  self.windowRegistry.windows[window.id] === window,
                  self.session(for: itemID) === page, page.profile?.id == profileID,
                  host.selectPage(navigation, in: window),
                  window.nativeSelectionGeneration == generation,
                  self.windowRegistry.windows[window.id] === window,
                  self.session(for: itemID) === page, page.profile?.id == profileID else {
                if window.nativeSelectionGeneration == generation { self.nativeSelectionFailed(in: window) }
                return
            }
            window.nativeSelectionGeneration = nil
            window.nativeSelectionSession = nil
            window.nativeSpaceSwitchIsUnresolved = false
            admitted()
            // Reopen may stage a cold query on an already-bound pinned page.
            // Resume only after this exact page owns the admitted selection.
            if window.nativeSelectionGeneration == nil && !window.nativeSplitIsPreparing,
               self.windowRegistry.windows[window.id] === window,
               window.selectedItemID == itemID, self.session(for: itemID) === page,
               page.navigation === navigation, page.profile?.id == profileID,
               host.isNativeSelection(navigation, in: window) {
                page.resumeStagedNativeSearch()
            }
            if window.nativeSelectionGeneration == nil && !window.nativeSplitIsPreparing {
                window.nativePresentationDidSettle?(true)
            }
        }
    }

    func nativePageWindow(for page: PageSession) -> BrowserWindowState? {
        if let window = page.detachedWindow { return window }
        if let id = pageOwners[page.itemID], let window = windowRegistry.windows[id] { return window }
        return window(for: page)
    }

    /// Delay destructive model mutation until all affected native owners have
    /// actually closed. Cancellation preserves the items; already-closed pages
    /// may be recreated later. No native handles or second item registry live here.
    func releaseNativePagesBeforeMutation(_ ids: [UUID],
                                          preferredSuccessor: ((BrowserWindowState) -> UUID?)? = nil,
                                          then action: @escaping @MainActor () -> Void) -> Bool {
        let pages = ids.compactMap { session(for: $0) }.filter(\.requiresNativeResourceRelease)
        guard !pages.isEmpty else { return false }
        let handoffs = nameCloseSuccessors(leaving: Set(ids), preferred: preferredSuccessor)
        let profiles = pages.map { $0.profile?.id }
        var remaining = pages.count
        var allAdmitted = true
        for page in pages {
            let holder = nativePageWindow(for: page)
            let handoff = handoffs.first { $0.left == page.itemID && $0.window === holder }
                ?? handoffs.first { $0.left == page.itemID }
            let successor = handoff.flatMap { session(for: $0.successor)?.navigation }
            page.requestNativeRelease(showing: successor) { [weak self] outcome in
                allAdmitted = allAdmitted && outcome == .closed
                remaining -= 1
                guard remaining == 0, let self else { return }
                for handoff in handoffs where handoff.window.nativeCloseSuccessor == handoff.successor {
                    handoff.window.nativeCloseSuccessor = nil
                }
                guard allAdmitted else { return }
                guard zip(pages, profiles).allSatisfy({ page, id in
                    self.session(for: page.itemID) === page && page.profile?.id == id
                }) else { return }
                action()
            }
        }
        return true
    }

    /// Chromium shows a tab of its own choosing when a shown page closes. A successor whose
    /// page is live goes with the close, so the engine shows it the moment the page actually
    /// closes. Until then, as while "Leave site?" asks, the closing page stays selected.
    private func nameCloseSuccessors(leaving ids: Set<UUID>,
                                     preferred: ((BrowserWindowState) -> UUID?)?) -> [(window: BrowserWindowState, left: UUID, successor: UUID)] {
        var handoffs: [(window: BrowserWindowState, left: UUID, successor: UUID)] = []
        for window in allWindows {
            guard let selected = window.selectedItemID, ids.contains(selected),
                  window.split?.contains(selected) != true,
                  let next = preferred?(window) ?? successor(in: window, leaving: ids),
                  let page = session(for: next), page.navigation != nil, !page.nativeIsEnding else { continue }
            window.nativeCloseSuccessor = next
            handoffs.append((window, selected, next))
        }
        return handoffs
    }

    /// With nothing selected, Chromium is showing some other client: the shell covers it.
    private func nativeSelectionFailed(in window: BrowserWindowState) {
        window.nativeSelectionGeneration = nil
        window.nativeSelectionSession = nil
        if window.selectedItemID == nil { window.nativeEmptySpaceID = window.spaceID }
        window.nativePresentationDidSettle?(false)
    }

    func canShow(_ itemID: UUID, in window: BrowserWindowState) -> Bool {
        let source = tree(owner(of: window))
        guard source.item(itemID) != nil else { return false }
        return source.spaceID(of: itemID) == window.spaceID
    }

    // MARK: - Page Ownership

    private func shows(_ itemID: UUID, in window: BrowserWindowState) -> Bool {
        window.selectedItemID == itemID || window.split?.contains(itemID) == true
    }

    /// The window that shows the item's live page: the last window to select or claim it while
    /// still showing it, else the active window if it shows it, else any window showing it.
    public func pageOwnerWindow(of itemID: UUID) -> BrowserWindowState? {
        let showing = allWindows.filter { shows(itemID, in: $0) }
        if let id = pageOwners[itemID], let owner = showing.first(where: { $0.id == id }) { return owner }
        let activeID = windowRegistry.activeWindowId
        return showing.first(where: { $0.id == activeID }) ?? showing.first
    }

    /// True when `window` shows the item but another window holds its live page.
    public func isPageShownElsewhere(_ itemID: UUID, from window: BrowserWindowState) -> Bool {
        guard let owner = pageOwnerWindow(of: itemID) else { return false }
        return owner.id != window.id
    }

    func hasOtherNativePageOwner(_ itemID: UUID, than window: BrowserWindowState) -> Bool {
        guard session(for: itemID)?.navigation != nil, let owner = pageOwners[itemID],
              windowRegistry.windows[owner] != nil else { return false }
        return owner != window.id
    }

    /// The window's selected page is live in another window, which shows it.
    public func showsPageElsewhere(in window: BrowserWindowState) -> Bool {
        // The registry observes membership only through its revision, not `windows`.
        _ = windowRegistry.registrationRevision
        return window.selectedItemID.map { isPageShownElsewhere($0, from: window) } ?? false
    }

    /// Once no other window shows this window's selected page, this window shows it.
    public func showSelectedPageHere(in window: BrowserWindowState) {
        guard windowRegistry.windows[window.id] === window,
              window.nativeSelectionGeneration == nil, !window.nativeSplitIsPreparing,
              let selected = window.selectedItemID, window.split?.contains(selected) != true,
              !isPageShownElsewhere(selected, from: window) else { return }
        if let page = session(for: selected)?.navigation, let host = nativePageHost,
           host.isNativeSelection(page, in: window) { return }
        select(selected, in: window)
    }

    /// Moves the item's live page to `window`.
    public func takeControl(_ itemID: UUID, in window: BrowserWindowState) {
        prepareNativeSelection(itemID, in: window) { [weak self, weak window] in
            guard let self, let window else { return }
            self.recordPageOwner(itemID, in: window)
        }
    }

    func recordPageOwner(_ itemID: UUID, in window: BrowserWindowState) {
        pageOwners[itemID] = window.id
        refreshWindows(showing: itemID)
    }

    /// Pure model ownership for catalog reconciliation; unlike presentation
    /// lookup this also identifies a background page without scanning sessions.
    public func isNativePageOwner(_ session: PageSession, in window: BrowserWindowState) -> Bool {
        (session.isPrivate ? window.privateSessions[session.itemID] === session : liveSessions[session.itemID] === session) &&
        pageOwners[session.itemID] == window.id && windowRegistry.windows[window.id] === window
    }

    /// Brings forward the window holding the item's live page.
    public func showOwnerWindow(of itemID: UUID) {
        pageOwnerWindow(of: itemID)?.windowHandle?.bringToFront()
    }

    public func refreshWindows(showing itemID: UUID) {
        for window in allWindows
        where shows(itemID, in: window) {
            window.refreshCompositor()
        }
    }

    /// The pages `window`'s mini player looks at: the window's own tabs in every space, on any
    /// site. A regular window's are those it selected last or opened from a link in the
    /// background, the Agent space's left out; a private window's are its own.
    public func miniPlayerPages(for window: BrowserWindowState) -> [MiniPlayerPage] {
        let pages = window.privateTree != nil
            ? Array(window.privateSessions.values)
            : liveSessions.values.filter { pageOwners[$0.itemID] == window.id && !isInAgentSpace($0.itemID) }
        // The window draws its split only while one of the split's panes is selected.
        let selected = window.selectedItemID
        let shownSplit = window.split.flatMap { split in selected.map(split.contains) == true ? split : nil }
        return pages.map { page in
            MiniPlayerPage(id: page.itemID, hasMedia: page.media.hasMedia, isAudible: page.media.isAudible,
                           isOnScreen: page.itemID == selected || shownSplit?.contains(page.itemID) == true)
        }
    }

    /// Keeps `window.miniPlayer` on the window's pages while the window is registered, whether
    /// or not a sidebar shows it: any change to what `miniPlayerPages` reads updates it again.
    func trackMiniPlayer(of window: BrowserWindowState) {
        guard windowRegistry.windows[window.id] === window else { return }
        let pages = withObservationTracking {
            miniPlayerPages(for: window)
        } onChange: { [weak self, weak window] in
            // Observation calls this before the change is made.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.trackMiniPlayer(of: window)
                }
            }
        }
        window.miniPlayer.update(pages)
        logMiniPlayer(of: window, pages: pages)
    }

    /// Which page the bar shows and why each other page with media does not.
    private func logMiniPlayer(of window: BrowserWindowState, pages: [MiniPlayerPage]) {
        let player = window.miniPlayer
        let candidates = pages.filter { ($0.hasMedia || $0.isAudible) && $0.id != player.itemID }
        let onScreen = candidates.filter(\.isOnScreen).map(\.id.uuidString).sorted().joined(separator: ",")
        let notAudible = candidates.filter { !$0.isOnScreen && !$0.isAudible }.map(\.id.uuidString).sorted().joined(separator: ",")
        let noMedia = pages.filter { !$0.hasMedia && !$0.isAudible }.count
        let started = player.latest?.uuidString ?? "nil"
        let shows = player.itemID?.uuidString ?? "nil"
        let summary = [String(pages.count), started, shows, onScreen, notAudible, String(noMedia)].joined(separator: "|")
        guard miniPlayerLogged[window.id] != summary else { return }
        miniPlayerLogged[window.id] = summary
        log.info("""
            media mini player window=\(window.id, privacy: .public) pages=\(pages.count, privacy: .public) \
            started=\(started, privacy: .public) shows=\(shows, privacy: .public) onScreen=\(onScreen, privacy: .public) \
            notAudible=\(notAudible, privacy: .public) noMedia=\(noMedia, privacy: .public)
            """)
    }

    /// Whether a window's mini player shows the page.
    public func isInMiniPlayer(_ itemID: UUID) -> Bool {
        allWindows.contains { $0.miniPlayer.itemID == itemID }
    }

    // MARK: - Page Reports

    /// A committed navigation or SPA URL change. Device items store it as their URL; synced items
    /// keep their home URL and store the open page instead.
    func pageCommitted(itemID: UUID, url committed: URL, resolvingPrivateSearch: Bool = false) {
        guard let owner = owner(ofItem: itemID) else { return }
        // A Kagi Session Link token stays out of tabs.json and device.json.
        let url = KagiSession.withoutToken(committed)
        if let page = session(for: itemID), page.usesNativePageHost {
            // Neither its factory blank nor a commit preceding newer metadata
            // may consume a cold query. The actual target commit settles it.
            if page.pendingNativeSearchQuery != nil || page.nativeSearchIntent != nil || resolvingPrivateSearch {
                if url.absoluteString == "about:blank" || page.nativeSearchIntent != nil { return }
                let resolvesColdHome = (page.pendingNativeSearchQuery != nil || resolvingPrivateSearch) && tree(owner).scope(of: itemID) == .synced
                storePendingSearch(nil, for: page)
                // A query pinned before first load has no home yet. Resolve that
                // placeholder once; later searches never overwrite a real home.
                if resolvesColdHome, let item = tree(owner).item(itemID),
                   case .tab(let home, _) = item.kind, home.absoluteString == "about:blank" {
                    perform(owner, "setURL", undoable: false) { try $0.setURL(itemID, url) }
                    guard session(for: itemID) === page, page.nativeSearchIntent == nil else { return }
                }
            }
        }
        if case .main = owner { livePageCommitted(url, itemID: itemID) }
        guard tree(owner).scope(of: itemID) == .synced else {
            perform(owner, "setURL", undoable: false) { try $0.setURL(itemID, url) }
            return
        }
        // Private windows keep no open-page state.
        guard case .main = owner, device.openPages[itemID]?.url != url else { return }
        let title = liveSessions[itemID]?.title ?? device.openPages[itemID]?.title ?? ""
        device.openPages[itemID] = OpenPage(url: url, title: title)
        save()
    }

    func pageTitleChanged(itemID: UUID, title: String) {
        guard let owner = owner(ofItem: itemID) else { return }
        if case .main = owner, tree.scope(of: itemID) == .synced {
            guard var page = device.openPages[itemID], page.title != title else { return }
            page.title = title
            device.openPages[itemID] = page
            save()
            return
        }
        perform(owner, "setPageTitle", undoable: false) { try $0.setPageTitle(itemID, title) }
    }

    // MARK: - Device State Edits

    /// Stamps tabs as seen at `now`; the next save writes it.
    func markSeen(_ itemIDs: [UUID], at now: Date = Date()) {
        var records = device.lastSeen ?? [:]
        for id in itemIDs { records[id] = now }
        device.lastSeen = records
    }

    /// Starts the archive clock of every tab that has none yet: tabs from before archiving
    /// existed, and tabs opened in the background and never shown.
    func startSeenClocks(at now: Date) {
        var records = device.lastSeen ?? [:]
        for item in tree.items.values where item.deletedAt == nil && !item.isFolder && records[item.id] == nil {
            records[item.id] = now
        }
        guard records != device.lastSeen else { return }
        device.lastSeen = records
        save()
    }

    func recordOpener(_ opener: UUID, of itemID: UUID) {
        var records = device.openers ?? [:]
        records[itemID] = opener
        device.openers = records
        save()
    }

    func setOpenPage(_ itemID: UUID, _ page: OpenPage?) {
        guard device.openPages[itemID] != page else { return }
        device.openPages[itemID] = page
        save()
    }

    /// Main-tree folders are remembered in device.json; private ones only in memory.
    func setFolder(_ folderID: UUID, open: Bool) {
        guard let owner = owner(ofItem: folderID) else { return }
        switch owner {
        case .main:
            if open { device.openFolders.insert(folderID) } else { device.openFolders.remove(folderID) }
            save()
            if open { refreshLiveFolder(folderID) }
        case .privateWindow:
            if open { privateOpenFolders.insert(folderID) } else { privateOpenFolders.remove(folderID) }
        }
    }

    func setLiveDismissed(_ folderID: UUID, _ urls: Set<URL>) {
        guard (device.liveDismissed?[folderID] ?? []) != urls else { return }
        var all = device.liveDismissed ?? [:]
        all[folderID] = urls.isEmpty ? nil : urls
        device.liveDismissed = all
        save()
    }

    func recordClosed(_ entry: ClosedEntry, archived: Bool = false) {
        // The agent's closed tabs stay out of the person's Reopen Closed Tab.
        if let agent = agentSpaceID, entry.section.spaceID == agent { return }
        if archived { device.pushArchived(entry) } else { device.pushClosed(entry) }
        save()
    }

    /// Removes reopen entries holding any of `ids` (items that are back in the tree).
    func dropClosed(containing ids: Set<UUID>) {
        if device.dropClosed(containing: ids) { save() }
    }

    func dropLastClosed() {
        guard device.newestClosed != nil else { return }
        device.dropNewestClosed()
        save()
    }

    /// Bind an existing native detached page without issuing navigation or creating
    /// a renderer. The presenter owns its lifetime and validates native identity;
    /// this method never adopts it into the saved tree or closes a rejected page.
    public func bindDetachedNativePage(_ navigation: any PageNavigation, profile: Profile,
                                       owner: any NativePageResourceOwner,
                                       in window: BrowserWindowState?) -> PageSession? {
        guard navigation.profileID == profile.id, !isTerminating,
              !sessions.contains(where: { $0.navigation === navigation }) else { return nil }
        let state = navigation.state
        guard !isTerminating, !sessions.contains(where: { $0.navigation === navigation }) else { return nil }
        let url = state.url ?? URL(string: "about:blank")!
        let session = PageSession(itemID: UUID(), url: url,
            title: state.title ?? url.host ?? url.absoluteString,
            isPrivate: profile.isEphemeral, controller: self)
        // Construction needs the actual engine capability before favicon init.
        // Seeding stays unpublished until the navigation has been installed.
        session.controller = nil
        session.detachedProfile = profile
        session.detachedWindow = window
        session.nativeResourceHost = owner
        session.installNavigation(navigation)
        guard !isTerminating, session.navigation === navigation,
              !sessions.contains(where: { $0.navigation === navigation }) else { return nil }
        session.controller = self
        return session
    }

    /// Admit an already-existing regular Chromium page. The host has bound its
    /// native resource before this call; rejection never closes that resource.
    /// No load/create command is issued and the engine's opener/document survives.
    @discardableResult
    public func adoptNativePage(_ page: any PageNavigation, through host: any NativePageHost,
                                in window: BrowserWindowState, spaceID: UUID,
                                from opener: UUID? = nil, select: Bool) -> UUID? {
        admitNativePage(page, detachedSession: nil, through: host, in: window,
                        spaceID: spaceID, from: opener, select: select)
    }

    /// Promote the existing detached session after the native host has admitted
    /// its exact live page. Refusal never closes, reloads, or replaces the source.
    @discardableResult
    public func adoptDetachedNativePage(_ session: PageSession, through host: any NativePageHost,
                                        in window: BrowserWindowState, spaceID: UUID,
                                        from opener: UUID? = nil, select: Bool) -> UUID? {
        guard session.isDetached, !session.nativeIsEnding, session.nativeRelease == nil,
              let page = session.navigation, session.profile?.id == page.profileID,
              session.isPrivate == window.isIncognito else { return nil }
        let admitted = admitNativePage(page, detachedSession: session, through: host,
            in: window, spaceID: spaceID, from: opener, select: select)
        // Promotion/refusal retains this document; catch a settings edit that
        // was deferred during guarded ownership publication.
        session.refreshNativeBoostCSS()
        return admitted
    }

    private func admitNativePage(_ page: any PageNavigation, detachedSession: PageSession?,
                                through host: any NativePageHost, in window: BrowserWindowState,
                                spaceID: UUID, from opener: UUID?, select: Bool) -> UUID? {
        if window.isIncognito {
            return adoptPrivateNativePage(page, detachedSession: detachedSession, through: host, in: window,
                spaceID: spaceID, from: opener, select: select)
        }
        guard !privateWindows.contains(where: { window in
            window.privateSessions.values.contains(where: { $0.navigation === page })
        }) else { return nil }
        func isCurrent() -> Bool {
            (detachedSession == nil || (detachedSession?.navigation === page && detachedSession?.nativeIsEnding == false &&
                detachedSession?.nativeRelease == nil)) && !isTerminating && nativePageHost === host &&
            windowRegistry.windows[window.id] === window && !window.isIncognito && window.privateTree == nil &&
            tree.space(spaceID) != nil && tree.dataStoreID(for: spaceID) == page.profileID &&
            page.profileID != nil && host.canAdoptPage(page, in: window)
        }
        guard isCurrent() else { return nil }
        if let opener {
            guard tree.spaceID(of: opener) == spaceID, tree.item(opener)?.url != nil else { return nil }
        }
        let generation = select ? UUID() : nil
        if let generation {
            let previous = window.nativeSelectionSession
            window.nativeSelectionGeneration = generation
            window.nativeSelectionSession = nil
            previous?.cancelNativePreparation(in: window)
        }
        defer {
            if let generation, window.nativeSelectionGeneration == generation {
                window.nativeSelectionGeneration = nil
                window.nativeSelectionSession = nil
            }
        }
        func selectionIsCurrent() -> Bool {
            generation == nil || window.nativeSelectionGeneration == generation
        }
        guard selectionIsCurrent(), isCurrent(), !select || host.selectPage(page, in: window),
              selectionIsCurrent(), isCurrent() else { return nil }
        guard let profile = profile(forSpace: spaceID) else { return nil }
        let state = page.state
        guard selectionIsCurrent(), isCurrent() else { return nil }
        if let existing = liveSessions.values.first(where: { $0.navigation === page }) {
            guard detachedSession == nil || detachedSession === existing else { return nil }
            guard !existing.nativeIsEnding, existing.nativeRelease == nil,
                  existing.profile?.id == page.profileID, tree.spaceID(of: existing.itemID) == spaceID else { return nil }
            let source = pageOwners[existing.itemID].flatMap { windowRegistry.windows[$0] }
            if !select, pageOwners[existing.itemID] == window.id { return existing.itemID }
            if source !== window {
                guard window.split == nil, source?.split == nil else { return nil }
                cancelNativeSelection(for: existing)
                if let source { existing.cancelNativePreparation(in: source) }
                guard selectionIsCurrent(), isCurrent(), !existing.nativeIsEnding,
                      existing.nativeRelease == nil, existing.navigation === page else { return nil }
                let previousOwner = pageOwners[existing.itemID]
                func transferIsCurrent() -> Bool {
                    selectionIsCurrent() && isCurrent() && liveSessions[existing.itemID] === existing &&
                    existing.navigation === page && !existing.nativeIsEnding && existing.nativeRelease == nil &&
                    pageOwners[existing.itemID] == previousOwner
                }
                // Native transfer chose its replacement tab. Clear only this
                // stale source selection; catalog reflection publishes the real
                // replacement without selecting/focusing/loading a native page.
                if let source {
                    for (space, selected) in source.selectedItemBySpace where selected == existing.itemID {
                        guard windowRegistry.windows[source.id] === source else { break }
                        source.selectedItemBySpace[space] = nil
                        guard transferIsCurrent() else { return nil }
                    }
                    if windowRegistry.windows[source.id] === source {
                        mirror(source)
                        guard transferIsCurrent() else { return nil }
                    }
                }
            }
            guard selectionIsCurrent(), isCurrent(), existing.navigation === page,
                  !existing.nativeIsEnding, existing.nativeRelease == nil else { return nil }
            if generation != nil { window.nativeSelectionSession = existing }
            finishNativeAdoption(existing, in: window, opener: nil, parent: nil, select: select, generation: generation)
            guard selectionIsCurrent(), isCurrent(), liveSessions[existing.itemID] === existing,
                  existing.navigation === page, !existing.nativeIsEnding, existing.nativeRelease == nil,
                  pageOwners[existing.itemID] == window.id else { return nil }
            return existing.itemID
        }
        let position = opener.flatMap {
            tree.linkTabPosition(in: spaceID, opener: $0, nest: settings.nestLinkTabsUnderOpener,
                                 openers: device.openers ?? [:])
        } ?? tree.newTabPosition(in: spaceID, after: window.selectedItemID, climbingFolders: settings.newTabsAtTopLevel)
        let url = state.url ?? URL(string: "about:blank")!
        let title = state.title ?? url.host ?? url.absoluteString
        let id = detachedSession?.itemID ?? UUID()
        let originalTree = tree
        var proposed = originalTree
        let change: Change
        do {
            change = try proposed.createTab(id: id, url: url, title: title, in: position.0, after: position.1)
        } catch { return nil }
        let session = detachedSession ?? PageSession(itemID: id, url: url, title: title, isPrivate: false, controller: self)
        if detachedSession == nil {
            // Seed without publishing title/history reports before the item exists.
            session.controller = nil
            session.detachedProfile = profile
            session.installNavigation(page)
        }
        guard selectionIsCurrent(), isCurrent(), tree == originalTree, session.navigation === page,
              !liveSessions.values.contains(where: { $0.navigation === page }) else {
            // A nested admission may now own this adapter's callbacks. Leave it
            // intact; the caller releases only its unadmitted host binding.
            if detachedSession == nil, !liveSessions.values.contains(where: { $0.navigation === page }) {
                page.onEvent = nil
                page.onStateChanged = nil
            }
            return nil
        }
        session.detachedProfile = nil
        session.detachedWindow = nil
        session.onClose = nil
        session.nativeResourceHost = host
        session.controller = self
        // Bind before the existing publication boundary: a reentrant observer
        // sees one real page and cannot bootstrap a second renderer.
        liveSessions[id] = session
        tree = proposed
        pushUndo(change)
        if generation != nil { window.nativeSelectionSession = session }
        finishNativeAdoption(session, in: window, opener: opener, parent: position.0, select: select, generation: generation)
        save()
        onTreeChanged?()
        return id
    }

    func nativeProfile(_ profileID: UUID?, matches spaceID: UUID, in window: BrowserWindowState) -> Bool {
        guard let profileID else { return false }
        if window.isIncognito {
            return window.privateTree?.space(spaceID) != nil && window.ephemeralProfile?.isEphemeral == true &&
                window.ephemeralProfile?.id == profileID
        }
        return window.privateTree == nil && tree.dataStoreID(for: spaceID) == profileID
    }

    /// Private contents stay in their existing window-owned tree/session map.
    /// Same-session transfers retain the live item/page; other sessions reject.
    private func adoptPrivateNativePage(_ page: any PageNavigation, detachedSession: PageSession?, through host: any NativePageHost,
                                       in window: BrowserWindowState, spaceID: UUID,
                                       from opener: UUID?, select shouldSelect: Bool) -> UUID? {
        func current() -> Bool {
            (detachedSession == nil || (detachedSession?.navigation === page &&
                detachedSession?.nativeIsEnding == false && detachedSession?.nativeRelease == nil)) && !isTerminating && nativePageHost === host &&
            windowRegistry.windows[window.id] === window && window.isIncognito &&
            nativeProfile(page.profileID, matches: spaceID, in: window) && host.canAdoptPage(page, in: window)
        }
        let generation = shouldSelect ? UUID() : nil
        if let generation { window.nativeSelectionGeneration = generation }
        defer {
            if let generation, window.nativeSelectionGeneration == generation {
                window.nativeSelectionGeneration = nil
                window.nativeSelectionSession = nil
            }
        }
        func intentIsCurrent() -> Bool { generation == nil || window.nativeSelectionGeneration == generation }
        guard intentIsCurrent(), current(), let original = window.privateTree, let profile = window.ephemeralProfile else { return nil }
        if let opener { guard original.spaceID(of: opener) == spaceID, original.item(opener)?.url != nil else { return nil } }
        guard !shouldSelect || host.selectPage(page, in: window), intentIsCurrent(), current(),
              window.privateTree == original else { return nil }
        if let existing = sessions.first(where: { $0.navigation === page }) {
            guard detachedSession == nil || detachedSession === existing else { return nil }
            guard existing.isPrivate, !existing.nativeIsEnding, existing.nativeRelease == nil,
                  let source = privateWindows.first(where: { $0.privateSessions[existing.itemID] === existing }),
                  source.ephemeralProfile === profile,
                  let sourceTree = source.privateTree, sourceTree.item(existing.itemID) != nil else { return nil }
            if source === window {
                guard shouldSelect else { return existing.itemID }
                window.nativeSelectionSession = existing
                finishNativeAdoption(existing, in: window, opener: nil, parent: nil,
                                     select: true, generation: generation)
                return intentIsCurrent() && current() && window.selectedItemID == existing.itemID ? existing.itemID : nil
            }
            guard source.split == nil, window.split == nil else { return nil }
            cancelNativeSelection(for: existing)
            existing.cancelNativePreparation(in: source)
            func transferCurrent() -> Bool {
                intentIsCurrent() && current() && source.privateSessions[existing.itemID] === existing &&
                source.privateTree == sourceTree && window.privateTree == original &&
                windowRegistry.windows[source.id] === source && existing.navigation === page &&
                !existing.nativeIsEnding && existing.nativeRelease == nil
            }
            guard transferCurrent() else { return nil }
            var sourceAfter = sourceTree, destinationAfter = original
            do {
                let closed = try sourceAfter.close(existing.itemID, promotingChildren: true).closed
                let parent = original.newTabPosition(in: spaceID, after: window.selectedItemID,
                                                    climbingFolders: settings.newTabsAtTopLevel).0
                _ = try destinationAfter.reopen(closed, fallback: parent)
            } catch { return nil }
            // Clear the stale source selection before tree publication; native
            // selection is mirrored separately, without focus or reload.
            for (space, selected) in source.selectedItemBySpace where selected == existing.itemID {
                source.selectedItemBySpace[space] = nil
                guard transferCurrent() else { return nil }
            }
            let transferToken = UUID()
            existing.nativeTransfer = (transferToken, window.id)
            defer {
                if existing.nativeTransfer?.token == transferToken { existing.nativeTransfer = nil }
            }
            // Runtime maps precede observable tree publication. An observer
            // retiring the source now cannot tear down the transferred page.
            window.privateSessions[existing.itemID] = existing
            source.privateSessions.removeValue(forKey: existing.itemID)
            source.privateTree = sourceAfter
            guard existing.nativeTransfer?.token == transferToken, intentIsCurrent(), current(), window.privateTree == original,
                  window.privateSessions[existing.itemID] === existing,
                  existing.navigation === page, !existing.nativeIsEnding, existing.nativeRelease == nil else {
                // Restore only our still-unpublished move, never a newer owner.
                if existing.nativeTransfer?.token == transferToken,
                   (window.privateSessions[existing.itemID] === existing ||
                    (windowRegistry.windows[window.id] == nil && !sessions.contains(where: { $0.navigation === page }))),
                   source.privateSessions[existing.itemID] == nil,
                   (window.privateTree == original || (windowRegistry.windows[window.id] == nil && window.privateTree == nil)),
                   windowRegistry.windows[source.id] === source,
                   source.privateTree == sourceAfter {
                    window.privateSessions.removeValue(forKey: existing.itemID)
                    source.privateSessions[existing.itemID] = existing
                    source.privateTree = sourceTree
                }
                return nil
            }
            window.privateTree = destinationAfter
            guard existing.nativeTransfer?.token == transferToken, intentIsCurrent(), current(), window.privateSessions[existing.itemID] === existing,
                  existing.navigation === page, !existing.nativeIsEnding, existing.nativeRelease == nil else { return nil }
            // Native opener survives. Remove only model-local relationships
            // that refer to the source's tree; no private records reach device.
            source.privateOpeners = source.privateOpeners.filter { $0.key != existing.itemID && $0.value != existing.itemID }
            guard existing.nativeTransfer?.token == transferToken, intentIsCurrent(), current(),
                  window.privateSessions[existing.itemID] === existing, existing.navigation === page else { return nil }
            recordPageOwner(existing.itemID, in: window)
            guard existing.nativeTransfer?.token == transferToken, intentIsCurrent(), current(),
                  window.privateSessions[existing.itemID] === existing, existing.navigation === page else { return nil }
            if generation != nil { window.nativeSelectionSession = existing }
            finishNativeAdoption(existing, in: window, opener: nil, parent: nil,
                                 select: shouldSelect, generation: generation)
            return intentIsCurrent() && current() && window.privateSessions[existing.itemID] === existing &&
                existing.navigation === page && (!shouldSelect || window.selectedItemID == existing.itemID) ? existing.itemID : nil
        }
        // Private selection is reflected after native admission; never focus a
        // background popup just because it has an active tab.
        let state = page.state
        guard intentIsCurrent(), current(), window.privateTree == original else { return nil }
        let position = opener.flatMap {
            original.linkTabPosition(in: spaceID, opener: $0, nest: settings.nestLinkTabsUnderOpener,
                                     openers: window.privateOpeners)
        } ?? original.newTabPosition(in: spaceID, after: window.selectedItemID, climbingFolders: settings.newTabsAtTopLevel)
        let id = detachedSession?.itemID ?? UUID(), url = state.url ?? URL(string: "about:blank")!
        let title = state.title ?? url.host ?? url.absoluteString
        var proposed = original
        guard (try? proposed.createTab(id: id, url: url, title: title, in: position.0, after: position.1)) != nil else { return nil }
        let session = detachedSession ?? PageSession(itemID: id, url: url, title: title, isPrivate: true, controller: nil)
        if detachedSession == nil {
            session.detachedProfile = profile
            session.installNavigation(page)
        }
        guard intentIsCurrent(), current(), window.privateTree == original,
              !sessions.contains(where: { $0.navigation === page }) else {
            if detachedSession == nil, !sessions.contains(where: { $0.navigation === page }) { page.onEvent = nil; page.onStateChanged = nil }
            return nil
        }
        let detachedProfile = session.detachedProfile
        let detachedWindow = session.detachedWindow
        let detachedOwner = session.nativeResourceHost
        let detachedClose = session.onClose
        session.controller = self
        session.detachedProfile = nil
        session.detachedWindow = nil
        session.onClose = nil
        session.nativeResourceHost = host
        window.privateSessions[id] = session
        func discardUnadmittedItem() {
            // Remove only this rejected publication. Preserve newer tree edits,
            // another owner of this live page, and all native contents.
            guard window.privateSessions[id] === session, session.navigation === page else { return }
            window.privateSessions.removeValue(forKey: id)
            pageOwners.removeValue(forKey: id)
            window.privateOpeners = window.privateOpeners.filter { $0.key != id && $0.value != id }
            if var latest = window.privateTree, latest.item(id) != nil,
               (try? latest.close(id, promotingChildren: true)) != nil { window.privateTree = latest }
            if !sessions.contains(where: { $0.navigation === page }) {
                if detachedSession != nil {
                    session.detachedProfile = detachedProfile
                    session.detachedWindow = detachedWindow
                    session.nativeResourceHost = detachedOwner
                    session.onClose = detachedClose
                } else { page.onEvent = nil; page.onStateChanged = nil }
            }
        }
        window.privateTree = proposed
        guard intentIsCurrent(), current(), window.privateSessions[id] === session,
              session.navigation === page, !session.nativeIsEnding, session.nativeRelease == nil else {
            discardUnadmittedItem(); return nil
        }
        if generation != nil { window.nativeSelectionSession = session }
        finishNativeAdoption(session, in: window, opener: opener, parent: position.0,
                             select: shouldSelect, generation: generation)
        guard intentIsCurrent(), current(), window.privateSessions[id] === session,
              session.navigation === page, !session.nativeIsEnding, session.nativeRelease == nil,
              !shouldSelect || window.selectedItemID == id else { discardUnadmittedItem(); return nil }
        return id
    }

    /// Reflect an already selected engine page without activating its native
    /// window or bootstrapping another page. Adoption must have bound it first.
    @discardableResult
    public func reflectNativeSelection(_ itemID: UUID, in window: BrowserWindowState) -> Bool {
        guard !window.nativeSpaceSwitchIsPending, cancelNativeSplit(in: window) else { return false }
        guard !isTerminating,
              windowRegistry.windows[window.id] === window,
              let session = session(for: itemID), let page = session.navigation,
              let host = nativePageHost, session.nativeResourceHost === host,
              let spaceID = tree(owner(of: window)).spaceID(of: itemID),
              tree(owner(of: window)).item(itemID)?.url != nil,
              nativeProfile(page.profileID, matches: spaceID, in: window),
              !session.nativeIsEnding, session.nativeRelease == nil,
              host.canAdoptPage(page, in: window) else { return false }
        let generation = UUID()
        let previous = window.nativeSelectionSession
        window.nativeSelectionGeneration = generation
        window.nativeSelectionSession = session
        if previous !== session { previous?.cancelNativePreparation(in: window) }
        defer {
            if window.nativeSelectionGeneration == generation {
                window.nativeSelectionGeneration = nil
                window.nativeSelectionSession = nil
            }
        }
        func modelIsCurrent() -> Bool {
            !isTerminating && nativePageHost === host && windowRegistry.windows[window.id] === window &&
            window.nativeSelectionGeneration == generation &&
            self.session(for: itemID) === session && session.nativeResourceHost === host && session.navigation === page && !session.nativeIsEnding && session.nativeRelease == nil &&
            tree(owner(of: window)).item(itemID)?.url != nil &&
            tree(owner(of: window)).spaceID(of: itemID) == spaceID &&
            nativeProfile(page.profileID, matches: spaceID, in: window)
        }
        guard modelIsCurrent(), host.acceptNativeSelection(page, in: window), modelIsCurrent() else { return false }
        let validate = { modelIsCurrent() && host.isNativeSelection(page, in: window) }
        guard validate() else { return false }
        finishNativeAdoption(session, in: window, opener: nil, parent: nil,
                             select: true, generation: generation, validateNative: validate)
        guard validate(), window.selectedItemID == itemID else { return false }
        window.nativeSpaceSwitchIsUnresolved = false
        return validate()
    }

    /// The engine shows this page in `window` when the window's closing page goes.
    public func isCloseSuccessor(_ itemID: UUID, in window: BrowserWindowState) -> Bool {
        window.nativeCloseSuccessor == itemID && selectedSession(in: window)?.nativeIsEnding == true &&
            canUseCloseSuccessor(itemID, in: window)
    }

    /// While a close is pending, Chromium can temporarily activate a neighbouring tab.
    public func canPresentProvisionalSelection(_ itemID: UUID, in window: BrowserWindowState,
                                               selectedPageClosed: Bool = false) -> Bool {
        if window.nativeCloseSuccessor == itemID { return !isStaleCloseSuccessor(itemID, in: window) }
        guard selectedPageClosed || selectedSession(in: window)?.nativeIsEnding == true else { return true }
        return canUseCloseSuccessor(itemID, in: window, previouslyShownIn: window.split)
    }

    /// A named tab can move while Chromium waits for beforeunload. The engine
    /// may activate its old client slot before reporting the terminal close.
    public func isStaleCloseSuccessor(_ itemID: UUID, in window: BrowserWindowState) -> Bool {
        window.nativeCloseSuccessor == itemID && !canUseCloseSuccessor(itemID, in: window)
    }

    /// Nook is deciding this window's selection: its page is closing, a successor is being
    /// prepared, or it shows an empty space or a page another window holds. A tab Chromium
    /// activates meanwhile is no one's choice.
    public func nativeSelectionIsSettling(in window: BrowserWindowState) -> Bool {
        window.nativeSelectionGeneration != nil || window.nativeSplitPreparation != nil
            || selectedSession(in: window)?.nativeIsEnding == true || window.showsNativeEmptySpace
            || showsPageElsewhere(in: window)
    }

    func addSession(_ session: PageSession) {
        liveSessions[session.itemID] = session
    }

    // MARK: - Windows

    /// Sets up a newly registered window: a private window gets its own tree; a regular window
    /// takes an unclaimed saved window record, else the first space. Loads no pages.
    public func attach(window: BrowserWindowState, restoringSavedState: Bool = true) {
        if window.isIncognito, window.ephemeralProfile != nil {
            if window.privateTree == nil {
                // One temporary space, never written to disk. Its pages use the window's
                // ephemeral data store, not one keyed by this id.
                var privateTree = TabTree()
                let spaceID = UUID()
                privateTree.createSpace(id: spaceID, name: "Private", icon: "eyeglasses", accentHex: "#3A3A3C", after: nil)
                window.privateTree = privateTree
                window.spaceID = spaceID
            }
            trackMiniPlayer(of: window)
            return
        }
        if restoringSavedState {
            let claimed = Set(regularWindows.map(\.id)).subtracting([window.id])
            if let index = device.windows.firstIndex(where: { $0.id == window.id })
                ?? device.windows.firstIndex(where: { !claimed.contains($0.id) }) {
                let record = device.windows[index]
                window.spaceID = record.spaceID.flatMap { tree.space($0)?.id }
                window.selectedItemBySpace = record.selectedItemBySpace.filter { tree.item($0.value) != nil }
                window.split = record.split
                window.pendingFrame = record.frame
                window.applyPendingFrame()
                device.windows[index].id = window.id
            }
            if window.spaceID == nil {
                window.spaceID = tree.orderedSpaces.first?.id
            }
        } else {
            // An engine-created window supplies its exact-profile space. Its
            // real native selection will be reflected only after page adoption.
            window.selectedItemBySpace.removeAll()
            window.split = nil
        }
        refreshLiveFolders()
        if restoringSavedState, let spaceID = window.spaceID, window.selectedItemBySpace[spaceID] == nil,
           let first = displayOrder(in: window).first {
            window.selectedItemBySpace[spaceID] = first
        }
        if restoringSavedState { mirror(window) }
        trackMiniPlayer(of: window)
    }

    /// A window closed. Private windows end their pages; a regular window's record is dropped
    /// unless it is the last one, so the last window reopens as it was.
    public func detach(window: BrowserWindowState) {
        if window.privateTree != nil {
            for itemID in Array(window.privateSessions.keys) {
                // During a native move the session map is handed off before
                // observable tree publication. A window retired in that gap
                // must not close contents its tree does not own.
                if window.privateSessions[itemID]?.nativeTransfer?.destination == window.id,
                   window.privateTree?.item(itemID) == nil, window.privateSessions[itemID]?.navigation != nil {
                    window.privateSessions.removeValue(forKey: itemID)
                    continue
                }
                endSession(itemID)
            }
            window.privateTree = nil
            return
        }
        let others = regularWindows.filter { $0.id != window.id }
        guard !isTerminating else { return }
        if device.pendingProfileDeletion?.change?.windowIDs.contains(window.id) == true {
            mirror(window)
            return
        }
        // The last window's record stays to reopen it, at the size it had when it closed.
        guard !others.isEmpty else { return mirror(window) }
        device.windows.removeAll { $0.id == window.id }
        save()
    }

    /// Saved window records no open regular window has claimed; the app opens a window for each.
    public func unclaimedWindowRecords() -> [WindowRecord] {
        let open = Set(regularWindows.map(\.id))
        return device.windows.filter { !open.contains($0.id) }
    }

    /// Copies a regular window's selection into DeviceState.windows.
    public func mirror(_ window: BrowserWindowState) {
        guard window.privateTree == nil else { return }
        // No window yet (attach runs first) or one in full screen keeps the frame it had.
        let frame = window.windowHandle?.frameString ?? device.windows.first { $0.id == window.id }?.frame
        let record = WindowRecord(
            id: window.id, spaceID: window.spaceID, selectedItemBySpace: window.selectedItemBySpace,
            split: window.split, frame: frame)
        if let index = device.windows.firstIndex(where: { $0.id == window.id }) {
            guard device.windows[index] != record else { return }
            device.windows[index] = record
        } else {
            device.windows.append(record)
        }
        save()
    }
}

extension TabsController {
    /// Target remains visible but unavailable until cleanup is confirmed. The survivor
    /// must be an existing model identity, never a default profile selected by native code.
    public func deleteKeptProfile(_ target: UUID, surviving survivor: UUID,
                                  completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard !profileDeletionInFlight, device.pendingProfileDeletion?.change == nil,
              device.pendingProfileDeletion.map({ $0.target == target && $0.survivor == survivor }) ?? true,
              target != survivor, let action = onDeleteProfile,
              device.keptProfiles?.contains(where: { $0.id == target }) == true,
              tree.profiles.contains(where: { $0.id == target }) == false,
              profiles.contains(where: { $0.id == survivor }), !isReadOnly else {
            completion(.failure(.unavailable)); return
        }
        let intent = PendingProfileDeletion(target: target, survivor: survivor)
        let wasPending = device.pendingProfileDeletion != nil
        device.pendingProfileDeletion = intent
        guard persistDeletionState() else {
            if !wasPending { device.pendingProfileDeletion = nil }
            completion(.failure(.persistenceFailed)); return
        }
        dispatchProfileDeletion(intent, action: action, reconcileOnly: false, wasPending: wasPending, completion: completion)
    }

    /// Called before regular native factories can borrow a persisted target at startup.
    public func resumePendingProfileDeletion(completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard let intent = device.pendingProfileDeletion else { completion(.success(())); return }
        if intent.change != nil {
            resumeProfileChange(intent, automatic: true, completion: completion)
            return
        }
        guard let action = onDeleteProfile, !isReadOnly else {
            completion(.failure(.pending)); return
        }
        dispatchProfileDeletion(intent, action: action, reconcileOnly: true, wasPending: true, completion: completion)
    }

    public func isProfileAvailable(_ id: UUID) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        guard let intent = device.pendingProfileDeletion, intent.target == id else { return true }
        return intent.change?.kind == .reassignSpace
    }

    private func dispatchProfileDeletion(_ intent: PendingProfileDeletion, action: ProfileDeletionAction, reconcileOnly: Bool, wasPending: Bool,
                                         completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard !profileDeletionInFlight else { completion(.failure(.pending)); return }
        let canDelete: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.device.pendingProfileDeletion == intent &&
                self.device.keptProfiles?.contains(where: { $0.id == intent.target }) == true &&
                !self.tree.profiles.contains(where: { $0.id == intent.target }) &&
                self.profiles.contains(where: { $0.id == intent.survivor })
        }
        guard canDelete() else { completion(.failure(.pending)); return }
        profileDeletionInFlight = true
        var finished = false
        action(intent, reconcileOnly, canDelete) { [weak self] result in
            guard !finished else { return }
            finished = true
            guard let self else { completion(.failure(.pending)); return }
            self.profileDeletionInFlight = false
            guard self.device.pendingProfileDeletion == intent else { completion(.failure(.pending)); return }
            switch result {
            case .pending, .closeAdmitted:
                completion(.failure(.pending))
            case .cancelled(let acknowledge):
                // A previous process may have marked deletion and then lost its
                // restart cleanup marker. A fresh refusal cannot undo that history.
                guard !wasPending else { completion(.failure(.pending)); return }
                self.device.pendingProfileDeletion = nil
                guard self.persistDeletionState() else {
                    self.device.pendingProfileDeletion = intent
                    completion(.failure(.persistenceFailed)); return
                }
                guard acknowledge() else {
                    self.device.pendingProfileDeletion = intent
                    _ = self.persistDeletionState()
                    completion(.failure(.pending)); return
                }
                completion(.failure(.cancelled))
            case .deleted:
                // Cleanup is terminal; keep the tombstone if persisting metadata fails.
                let previous = self.device
                self.device.dropKeptProfile(intent.target)
                self.device.pendingProfileDeletion = nil
                guard self.persistDeletionState() else {
                    self.device = previous
                    completion(.failure(.persistenceFailed)); return
                }
                self.forgetProfile(intent.target)
                completion(.success(()))
            }
        }
    }

    private func persistDeletionState() -> Bool {
        guard !store.isReadOnly else { return false }
        store.save(tree, device)
        store.flush()
        return store.lastError == nil
    }
}

extension TabsController {
    func profileChangeLocksItem(_ itemID: UUID) -> Bool {
        guard let change = device.pendingProfileDeletion?.change,
              change.phase != .assignmentCommitted else { return false }
        return tree.spaceID(of: itemID).map(change.spaceIDs.contains) == true
    }

    func profileSpaceIsReady(_ spaceID: UUID) -> Bool {
        guard let change = device.pendingProfileDeletion?.change,
              change.spaceIDs.contains(spaceID) else { return true }
        return change.phase == .assignmentCommitted ||
            (change.phase == .prepared && !profileDeletionInFlight)
    }

    public func deleteProfile(_ target: UUID, surviving survivor: UUID,
                              completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        if let pending = device.pendingProfileDeletion, pending.change != nil {
            guard pending.target == target, pending.survivor == survivor else { completion(.failure(.pending)); return }
            resumeProfileChange(pending, automatic: false, completion: completion)
            return
        }
        guard let summary = tree.profiles.first(where: { $0.id == target }) else {
            deleteKeptProfile(target, surviving: survivor, completion: completion)
            return
        }
        beginProfileChange(summary.spaceIDs, target: summary,
            destination: survivor, name: nil, kind: .deleteProfile, completion: completion)
    }

    public func retryPendingProfileChange(completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard let intent = device.pendingProfileDeletion, intent.change != nil else {
            completion(.failure(.unavailable)); return
        }
        resumeProfileChange(intent, automatic: false, completion: completion)
    }

    func reassignNativeSpace(_ spaceID: UUID, destination: UUID?, name: String?, keepSource: Bool,
                             completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard let source = tree.profile(ofSpace: spaceID) else { completion(.failure(.unavailable)); return }
        let kind: PendingProfileChange.Kind = source.spaceIDs == [spaceID] && !keepSource
            ? .deleteProfile : .reassignSpace
        beginProfileChange([spaceID], target: source, destination: destination,
                           name: name, kind: kind, completion: completion)
    }

    private func beginProfileChange(_ spaces: [UUID], target: ProfileSummary, destination: UUID?, name: String?,
                                    kind: PendingProfileChange.Kind,
                                    completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard !isReadOnly, !profileDeletionInFlight, device.pendingProfileDeletion == nil,
              (kind == .deleteProfile ? onDeleteProfile != nil : nativePageHost != nil),
              !spaces.isEmpty, spaces.allSatisfy({ tree.space($0)?.isAgent == false && tree.dataStoreID(for: $0) == target.id }),
              destination != target.id, destination == nil || profiles.contains(where: { $0.id == destination }) else {
            completion(.failure(.unavailable)); return
        }
        let survivor = destination ?? UUID()
        let created = destination == nil ? KeptProfile(id: survivor,
            name: name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? tree.space(spaces[0])!.name) : nil
        let moved = Set(spaces)
        let windows = Set(regularWindows.filter { window in
            window.spaceID.map(moved.contains) == true ||
            window.selectedItemID.flatMap { tree.spaceID(of: $0) }.map(moved.contains) == true ||
            window.split?.itemIDs.contains(where: { tree.spaceID(of: $0).map(moved.contains) == true }) == true
        }.map(\.id)).union(device.windows.filter { $0.spaceID.map(moved.contains) == true }.map(\.id))
        let change = PendingProfileChange(kind: kind, spaceIDs: spaces, source: KeptProfile(target),
                                         newDestination: created, windowIDs: windows)
        let intent = PendingProfileDeletion(target: target.id, survivor: survivor, change: change)
        let previous = device
        if let created { device.keptProfiles = (device.keptProfiles ?? []) + [created] }
        device.pendingProfileDeletion = intent
        guard persistDeletionState() else {
            device = previous; completion(.failure(.persistenceFailed)); return
        }
        resumeProfileChange(intent, automatic: false, completion: completion)
    }

    private func changeIsCurrent(_ intent: PendingProfileDeletion) -> Bool {
        guard let id = intent.change?.id, device.pendingProfileDeletion?.change?.id == id,
              intent.target == device.pendingProfileDeletion?.target,
              intent.survivor == device.pendingProfileDeletion?.survivor,
              profiles.contains(where: { $0.id == intent.survivor }) else { return false }
        return intent.change!.spaceIDs.allSatisfy {
            tree.space($0)?.isAgent == false && [intent.target, intent.survivor].contains(tree.dataStoreID(for: $0) ?? UUID())
        }
    }

    private func resumeProfileChange(_ intent: PendingProfileDeletion, automatic: Bool,
                                     completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard !profileDeletionInFlight, changeIsCurrent(intent), let change = intent.change else {
            completion(.failure(.pending)); return
        }
        if change.kind == .reassignSpace {
            profileDeletionInFlight = true
            if automatic && change.phase == .prepared &&
                change.spaceIDs.allSatisfy({ tree.dataStoreID(for: $0) == intent.target }) {
                // No data deletion/reservation exists for space-only moves. A
                // new process cannot infer a fresh close/assignment from intent.
                finishProfileChangeCancellation(intent, acknowledge: { true }, completion: completion)
                return
            }
            if change.phase != .prepared || change.spaceIDs.allSatisfy({ tree.dataStoreID(for: $0) == intent.survivor }) {
                guard commitProfileAssignment(intent) else {
                    profileDeletionInFlight = false; completion(.failure(.persistenceFailed)); return
                }
                finishRetainedProfileChange(intent, completion: completion)
                return
            }
            let ids = Set(change.spaceIDs.flatMap { items(inSpace: $0).map(\.id) })
            let pages = ids.compactMap { session(for: $0) }.filter(\.requiresNativeResourceRelease)
            var remaining = pages.count, accepted = true
            func released(_ outcome: PageCloseOutcome) {
                guard changeIsCurrent(intent) else { return }
                accepted = accepted && outcome == .closed
                remaining -= 1
                guard remaining == 0 else { return }
                guard accepted else {
                    finishProfileChangeCancellation(intent, acknowledge: { true }, completion: completion)
                    return
                }
                guard commitProfileAssignment(intent) else {
                    profileDeletionInFlight = false; completion(.failure(.persistenceFailed)); return
                }
                finishRetainedProfileChange(intent, completion: completion)
            }
            if pages.isEmpty {
                guard commitProfileAssignment(intent) else {
                    profileDeletionInFlight = false; completion(.failure(.persistenceFailed)); return
                }
                finishRetainedProfileChange(intent, completion: completion)
            } else {
                for page in pages { page.requestNativeRelease(completion: released) }
            }
            return
        }
        guard let action = onDeleteProfile else { completion(.failure(.unavailable)); return }
        profileDeletionInFlight = true
        let canDelete: @MainActor () -> Bool = { [weak self] in self?.changeIsCurrent(intent) == true }
        var preparationReplied = false
        action(intent, automatic, canDelete) { [weak self] result in
            guard !preparationReplied else { return }
            preparationReplied = true
            guard let self, self.changeIsCurrent(intent) else { return }
            self.receiveProfileChangeResult(result, intent: intent, automatic: automatic, completion: completion)
        }
    }

    private func receiveProfileChangeResult(_ result: ProfileDeletionOutcome, intent: PendingProfileDeletion,
                                            automatic: Bool,
                                            completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        switch result {
        case .pending:
            profileDeletionInFlight = false; completion(.failure(.pending))
        case .cancelled(let acknowledge):
            profileDeletionInFlight = false
            // Deferred mode proves no mark/wipe occurred. Recovery may cancel
            // an uncommitted assignment; a structure-only write is finalized
            // with the source kept, never rolled back or followed by a wipe.
            guard let current = device.pendingProfileDeletion?.change else { completion(.failure(.pending)); return }
            guard current.phase == .prepared || (automatic && current.phase != .assignmentCommitted) else {
                completion(.failure(.pending)); return
            }
            if current.spaceIDs.allSatisfy({ tree.dataStoreID(for: $0) == intent.survivor }) {
                guard commitProfileAssignment(intent) else {
                    profileDeletionInFlight = false; completion(.failure(.persistenceFailed)); return
                }
            }
            finishProfileChangeCancellation(intent, acknowledge: acknowledge, completion: completion)
        case .closeAdmitted(let continueCleanup):
            // Native owner closure is authoritative even if its terminal
            // observation delivery has not reached the model callback yet.
            for id in intent.change!.spaceIDs.flatMap({ items(inSpace: $0).map(\.id) }) {
                if let page = session(for: id), page.navigation?.profileID == intent.target {
                    page.switcherSnapshot = nil
                    page.nativeOwnerEnded()
                }
            }
            guard commitProfileAssignment(intent) else {
                profileDeletionInFlight = false; completion(.failure(.persistenceFailed)); return
            }
            var cleanupReplied = false
            continueCleanup { [weak self] result in
                guard !cleanupReplied else { return }
                cleanupReplied = true
                guard let self, self.changeIsCurrent(intent) else { return }
                self.receiveProfileChangeResult(result, intent: intent, automatic: automatic, completion: completion)
            }
        case .deleted:
            // Missing-directory reconciliation can finish without an admitted
            // live Profile. Assignment still has to be committed durably first.
            guard commitProfileAssignment(intent) else {
                profileDeletionInFlight = false; completion(.failure(.persistenceFailed)); return
            }
            profileDeletionInFlight = false
            let previous = device
            device.dropKeptProfile(intent.target)
            device.pendingProfileDeletion = nil
            guard persistDeletionState() else {
                device = previous; completion(.failure(.persistenceFailed)); return
            }
            forgetProfile(intent.target)
            completion(.success(()))
        }
    }

    private func commitProfileAssignment(_ original: PendingProfileDeletion) -> Bool {
        guard changeIsCurrent(original), var intent = device.pendingProfileDeletion,
              var change = intent.change else { return false }
        if change.phase == .assignmentCommitted { return true }
        change.phase = .closeAdmitted; intent.change = change
        device.pendingProfileDeletion = intent
        guard persistDeletionState() else { return false }
        for id in change.spaceIDs.flatMap({ items(inSpace: $0).map(\.id) }) {
            session(for: id)?.switcherSnapshot = nil
        }
        var proposed = tree
        do {
            for id in change.spaceIDs {
                try proposed.setProfile(id, to: intent.survivor, kept: device.keptProfiles ?? [])
            }
        } catch { return false }
        var next = device
        if !proposed.profiles.contains(where: { $0.id == intent.target }) {
            var kept = next.keptProfiles ?? []
            kept.removeAll { $0.id == intent.target }; kept.append(change.source)
            next.keptProfiles = kept
        }
        change.phase = .assignmentCommitted; intent.change = change
        next.pendingProfileDeletion = intent
        next.prune(against: proposed)
        // TabStore writes structure first, device second. Publish neither in
        // memory until both succeed; the durable close-admitted intent repairs
        // a structure-only write without recreating IDs or erasing source data.
        store.save(proposed, next); store.flush()
        guard store.lastError == nil else { return false }
        tree = proposed; device = next
        let affected = Set(change.spaceIDs)
        undoStack.removeAll { !$0.spaces.keys.filter(affected.contains).isEmpty }
        for window in regularWindows {
            if let selected = window.selectedItemID, !displayOrder(in: window).contains(selected), let space = window.spaceID {
                window.selectedItemBySpace[space] = displayOrder(in: window).first
                mirror(window)
            }
        }
        for window in regularWindows where window.spaceID.map(change.spaceIDs.contains) == true {
            sessionDelegate?.windowSpaceChanged(window)
        }
        onTreeChanged?()
        onProfileWindowsNeedReload?(change.windowIDs)
        return true
    }

    private func finishRetainedProfileChange(_ intent: PendingProfileDeletion,
                                             completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard changeIsCurrent(intent) else { profileDeletionInFlight = false; completion(.failure(.pending)); return }
        let previous = device
        device.pendingProfileDeletion = nil
        guard persistDeletionState() else {
            device = previous; profileDeletionInFlight = false; completion(.failure(.persistenceFailed)); return
        }
        profileDeletionInFlight = false
        completion(.success(()))
    }

    private func finishProfileChangeCancellation(_ intent: PendingProfileDeletion, acknowledge: @MainActor () -> Bool,
                                                 completion: @escaping @MainActor (Result<Void, ProfileDeletionError>) -> Void) {
        guard changeIsCurrent(intent) else { profileDeletionInFlight = false; completion(.failure(.pending)); return }
        let previous = device
        device.pendingProfileDeletion = nil
        guard persistDeletionState() else {
            device = previous; profileDeletionInFlight = false; completion(.failure(.persistenceFailed)); return
        }
        guard acknowledge() else {
            device = previous; _ = persistDeletionState(); profileDeletionInFlight = false; completion(.failure(.pending)); return
        }
        profileDeletionInFlight = false
        onProfileWindowsNeedReload?(intent.change!.windowIDs)
        completion(.failure(.cancelled))
    }
}
