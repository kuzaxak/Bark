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
import WebKit

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
        }
    }
    public private(set) var device: DeviceState
    @ObservationIgnored private var mainChildren: [Parent: [Item]]?
    @ObservationIgnored private var mainRows: [UUID: (openFolders: Set<UUID>, rows: [Row])] = [:]
    /// How many times the main tree's items were grouped by parent for sidebar rows; tests read it.
    @ObservationIgnored private(set) var treeWalks = 0
    @ObservationIgnored private(set) var nativeOwnershipVisits = 0
    /// Fixtures with recording views opt out of the separate favicon cache/network path.
    @ObservationIgnored var loadsWebKitFavicons = true
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
    @ObservationIgnored var liveRefreshing: Set<UUID> = []
    @ObservationIgnored private var archiveTimer: Timer?
    /// The tab DevMCP page tools act on, in the Agent space (see `TabsController+Agent.swift`).
    public internal(set) var agentItemID: UUID?
    /// DevMCP tool calls running now; the sidebar's agent row pulses while it is above zero.
    public var agentCallsInFlight = 0
    /// The agent's page changed or lost its window; the app keeps it rendering.
    @ObservationIgnored public var onAgentPage: ((PageSession) -> Void)?

    /// One `Profile` (website data store) per space, made on first use and kept for the session.
    @ObservationIgnored private var spaceProfiles: [UUID: Profile] = [:]

    @ObservationIgnored private let store: TabStore
    @ObservationIgnored private(set) var undoStack: [Change] = []
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored public let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Tabs")

    // MARK: - Injected

    @ObservationIgnored public let profileEngine: Profile.Engine
    @ObservationIgnored public let settings: NookSettingsService
    @ObservationIgnored public let windowRegistry: WindowRegistry
    @ObservationIgnored public let blocker: ContentBlockerManager
    @ObservationIgnored public let sponsorBlock: SponsorBlockManager
    @ObservationIgnored public let siteRouting: SiteRoutingManager
    /// Set once the SwiftData context has produced it; nil in a host without history.
    @ObservationIgnored public var history: HistoryManager?
    @ObservationIgnored public weak var webViews: WebViewProvider?
    @ObservationIgnored public weak var nativePageHost: (any NativePageHost)? {
        didSet {
            guard nativePageHost != nil else { return }
            for window in allWindows {
                if let itemID = window.selectedItemID { select(itemID, in: window) }
            }
        }
    }
    /// The app takes the screenshot, writes the clipboard and shows the toast.
    @ObservationIgnored public var onDevPick: ((PageSession, DevPickedElement) -> Void)?
    @ObservationIgnored public weak var sessionDelegate: PageSessionDelegate?
    @ObservationIgnored public weak var tabEvents: TabEventObserver?
    @ObservationIgnored public weak var alerts: AlertPresenter?
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
    /// A page started loading with no window showing it: a link opened in the background.
    @ObservationIgnored public var onPageLoadedInBackground: ((PageSession) -> Void)?
    /// The main tree changed; space sync reads it to find what to send.
    @ObservationIgnored public var onTreeChanged: (() -> Void)?
    /// App-owned profile presentation; absent presenters report unavailability.
    @ObservationIgnored public var onOpenProfilePage: ProfilePageAction?

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
        sponsorBlock: SponsorBlockManager,
        siteRouting: SiteRoutingManager,
        history: HistoryManager? = nil,
        legacyProfiles: [(id: UUID, name: String)] = [],
        /// A tree built from a pre-1.1 store; asked for only on a first launch.
        legacyTree: () -> TabTree? = { nil },
        profileEngine: Profile.Engine = .webKit,
        directory: URL = TabsController.defaultDirectory
    ) {
        self.profileEngine = profileEngine
        self.settings = settings
        self.windowRegistry = windowRegistry
        self.blocker = blocker
        self.sponsorBlock = sponsorBlock
        self.siteRouting = siteRouting
        self.history = history
        self.directory = directory
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
            // A quit ends every page, so pinned tabs and favorites start at their home URL again.
            device.openPages = [:]
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

    /// One space per profile left over from before spaces owned their data (same UUID, so each
    /// WKWebsiteDataStore keeps its cookies and logins), each with one tab.
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
    }

    /// Writes now, with every regular window's current frame. Called at quit; windows closing
    /// afterwards keep their records so they all reopen.
    public func flushSync() {
        isTerminating = true
        for window in regularWindows { mirror(window) }
        store.save(tree, device)
        store.flush()
    }

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

    public func session(for webView: WKWebView) -> PageSession? {
        let coordinator = webViews
        return sessions.first { session in
            session.webView === webView
                || coordinator?.allWebViews(for: session.itemID).contains(where: { $0 === webView }) == true
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
        guard let session = selectedSession(in: window), !isPageShownElsewhere(session.itemID, from: window) else { return nil }
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
        if !session.isPrivate {
            tabEvents?.tabClosed(itemID: itemID)
        }
    }

    /// The website data store of a space, made on first use and shared by every space that uses
    /// the same store (the Agent space borrows one). Its name and icon follow the space asked for.
    public func profile(forSpace spaceID: UUID) -> Profile? {
        guard let space = tree.space(spaceID), let storeID = tree.dataStoreID(for: spaceID) else { return nil }
        if let existing = spaceProfiles[storeID] {
            if !space.isAgent {
                existing.name = space.name
                existing.icon = space.icon
            }
            return existing
        }
        let profile = Profile(id: storeID, name: space.name, icon: space.icon, engine: profileEngine)
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
        if let space = tree.orderedSpaces.first(where: { tree.dataStoreID(for: $0.id) == storeID }) {
            return profile(forSpace: space.id)
        }
        guard let kept = device.keptProfiles?.first(where: { $0.id == storeID }) else { return nil }
        if let existing = spaceProfiles[storeID] { return existing }
        let profile = Profile(id: storeID, name: kept.name, icon: "", engine: profileEngine)
        spaceProfiles[storeID] = profile
        return profile
    }

    /// Drops a data store no space uses any more.
    func forgetProfile(_ storeID: UUID) {
        spaceProfiles[storeID] = nil
        history?.deleteHistory(forProfile: storeID)
        device.dropKeptProfile(storeID)
        save()
    }

    /// Clears a profile's website data, and with it the translations made on its pages.
    @discardableResult
    public func clearData(of profile: Profile) async -> Bool {
        // Native data management must use that profile's Chromium settings.
        // False is explicit unavailability, not a successful empty clear.
        guard profile.webKitDataStore != nil else { return false }
        await profile.clearAllData()
        await translationCaches.erase(profile: profile.id)
        return true
    }

    /// Keeps a data store no space uses any more, with its history, for a space to use again.
    func keepProfile(_ profile: ProfileSummary) {
        device.keep(profile)
        save()
    }

    /// Changes a kept profile; false when no kept profile has `storeID`.
    func updateKeptProfile(_ storeID: UUID, _ update: (inout KeptProfile) -> Void) -> Bool {
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
        if let id = tree.spaceID(of: session.itemID), let profile = profile(forSpace: id) {
            return profile
        }
        return sessionDelegate?.currentProfile ?? tree.orderedSpaces.first.flatMap { profile(forSpace: $0.id) }
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
        guard profileEngine == .chromium else { return false }
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

    /// Synchronous tree/undo edits cannot bypass actual native close admission.
    /// Explicit close/remove release first; unsupported destructive replacements
    /// leave the current tree intact. Pending creations can still be canceled.
    func nativeEditIsAdmissible(_ proposed: TabTree, owner: Owner) -> Bool {
        guard profileEngine == .chromium else { return true }
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
        guard profileEngine == .chromium else { return }
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
        let previous = window.nativeSelectionSession
        let generation = UUID()
        window.nativeSelectionGeneration = generation
        window.nativeSelectionSession = nil
        if previous?.itemID != itemID { previous?.cancelNativePreparation(in: window) }
        guard window.nativeSelectionGeneration == generation else { return }
        guard let page = ensureSession(for: itemID), let profileID = page.profile?.id else {
            window.nativeSelectionGeneration = nil
            return
        }
        window.nativeSelectionSession = page
        page.ensureNativePage(in: window) { [weak self, weak page, weak window] prepared in
            guard let self, let page, let window,
                  window.nativeSelectionGeneration == generation else { return }
            guard prepared, self.windowRegistry.windows[window.id] === window,
                  self.session(for: itemID) === page, page.profile?.id == profileID,
                  let navigation = page.navigation,
                  let host = page.nativeResourceHost ?? self.nativePageHost,
                  host.selectPage(navigation, in: window),
                  window.nativeSelectionGeneration == generation,
                  self.windowRegistry.windows[window.id] === window,
                  self.session(for: itemID) === page, page.profile?.id == profileID else {
                if window.nativeSelectionGeneration == generation {
                    window.nativeSelectionGeneration = nil
                    window.nativeSelectionSession = nil
                }
                return
            }
            window.nativeSelectionGeneration = nil
            window.nativeSelectionSession = nil
            admitted()
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
    func releaseNativePagesBeforeMutation(_ ids: [UUID], then action: @escaping @MainActor () -> Void) -> Bool {
        let pages = ids.compactMap { session(for: $0) }.filter(\.requiresNativeResourceRelease)
        guard !pages.isEmpty else { return false }
        let profiles = pages.map { $0.profile?.id }
        var remaining = pages.count
        var allAdmitted = true
        for page in pages {
            page.requestNativeRelease { [weak self] outcome in
                allAdmitted = allAdmitted && outcome == .closed
                remaining -= 1
                guard remaining == 0, allAdmitted, let self else { return }
                guard zip(pages, profiles).allSatisfy({ page, id in
                    self.session(for: page.itemID) === page && page.profile?.id == id
                }) else { return }
                action()
            }
        }
        return true
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

    /// Moves the item's live page to `window`.
    public func takeControl(_ itemID: UUID, in window: BrowserWindowState) {
        if profileEngine == .chromium {
            prepareNativeSelection(itemID, in: window) { [weak self, weak window] in
                guard let self, let window else { return }
                self.recordPageOwner(itemID, in: window)
            }
        } else {
            recordPageOwner(itemID, in: window)
        }
    }

    func recordPageOwner(_ itemID: UUID, in window: BrowserWindowState) {
        pageOwners[itemID] = window.id
        refreshWindows(showing: itemID)
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
        mediaLog.info("""
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
    func pageCommitted(itemID: UUID, url committed: URL) {
        guard let owner = owner(ofItem: itemID) else { return }
        // A Kagi Session Link token stays out of tabs.json and device.json.
        let url = KagiSession.withoutToken(committed)
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

    /// Admit an already-existing regular Chromium page. The host has bound its
    /// native resource before this call; rejection never closes that resource.
    /// No load/create command is issued and the engine's opener/document survives.
    @discardableResult
    public func adoptNativePage(_ page: any PageNavigation, through host: any NativePageHost,
                                in window: BrowserWindowState, spaceID: UUID,
                                from opener: UUID? = nil, select: Bool) -> UUID? {
        func isCurrent() -> Bool {
            profileEngine == .chromium && !isTerminating && nativePageHost === host &&
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
            guard !existing.nativeIsEnding, existing.nativeRelease == nil,
                  existing.profile?.id == page.profileID, tree.spaceID(of: existing.itemID) == spaceID else { return nil }
            if generation != nil { window.nativeSelectionSession = existing }
            finishNativeAdoption(existing, in: window, opener: nil, parent: nil, select: select, generation: generation)
            return existing.itemID
        }
        let position = opener.flatMap {
            tree.linkTabPosition(in: spaceID, opener: $0, nest: settings.nestLinkTabsUnderOpener,
                                 openers: device.openers ?? [:])
        } ?? tree.newTabPosition(in: spaceID, after: window.selectedItemID, climbingFolders: settings.newTabsAtTopLevel)
        let url = state.url ?? URL(string: "about:blank")!
        let title = state.title ?? url.host ?? url.absoluteString
        let id = UUID()
        let originalTree = tree
        var proposed = originalTree
        let change: Change
        do {
            change = try proposed.createTab(id: id, url: url, title: title, in: position.0, after: position.1)
        } catch { return nil }
        let session = PageSession(itemID: id, url: url, title: title, isPrivate: false, controller: self)
        // Seed without publishing title/history reports before the item exists.
        session.controller = nil
        session.detachedProfile = profile
        session.installNavigation(page)
        session.nativeResourceHost = host
        guard selectionIsCurrent(), isCurrent(), tree == originalTree, session.navigation === page,
              !liveSessions.values.contains(where: { $0.navigation === page }) else {
            // A nested admission may now own this adapter's callbacks. Leave it
            // intact; the caller releases only its unadmitted host binding.
            if !liveSessions.values.contains(where: { $0.navigation === page }) {
                page.onEvent = nil
                page.onStateChanged = nil
            }
            return nil
        }
        session.detachedProfile = nil
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

    /// Reflect an already selected engine page without activating its native
    /// window or bootstrapping another page. Adoption must have bound it first.
    @discardableResult
    public func reflectNativeSelection(_ itemID: UUID, in window: BrowserWindowState) -> Bool {
        guard profileEngine == .chromium, !isTerminating,
              windowRegistry.windows[window.id] === window, !window.isIncognito, window.privateTree == nil,
              let session = session(for: itemID), let page = session.navigation,
              let host = nativePageHost, session.nativeResourceHost === host,
              let spaceID = tree.spaceID(of: itemID), tree.item(itemID)?.url != nil,
              page.profileID != nil, tree.dataStoreID(for: spaceID) == page.profileID,
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
            window.nativeSelectionGeneration == generation && !window.isIncognito && window.privateTree == nil &&
            self.session(for: itemID) === session && session.nativeResourceHost === host && session.navigation === page && !session.nativeIsEnding && session.nativeRelease == nil &&
            tree.item(itemID)?.url != nil && tree.spaceID(of: itemID) == spaceID &&
            tree.dataStoreID(for: spaceID) == page.profileID
        }
        guard modelIsCurrent(), host.acceptNativeSelection(page, in: window), modelIsCurrent() else { return false }
        let validate = { modelIsCurrent() && host.isNativeSelection(page, in: window) }
        guard validate() else { return false }
        finishNativeAdoption(session, in: window, opener: nil, parent: nil,
                             select: true, generation: generation, validateNative: validate)
        return validate() && window.selectedItemID == itemID
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
            for itemID in Array(window.privateSessions.keys) { endSession(itemID) }
            window.privateTree = nil
            return
        }
        let others = regularWindows.filter { $0.id != window.id }
        guard !isTerminating else { return }
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
