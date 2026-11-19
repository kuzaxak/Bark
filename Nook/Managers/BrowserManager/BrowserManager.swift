// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager.swift
//  Nook
//
//  Created by Maciek Bagiński on 28/07/2025.
//

import AppKit
import Combine
import CoreServices
import OSLog
import SwiftData
import SwiftUI
import WebKit
import NookBlocker
import NookDesign
import NookSettings
import NookTweaks
import NookUI
import NookWeb

@MainActor
final class Persistence {
    static let shared = Persistence()
    let container: ModelContainer

    // MARK: - Constants
    nonisolated private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Persistence")
    nonisolated private static let storeFileName = "default.store"
    nonisolated private static let backupPrefix = "default_backup_"
    // Backups now use a directory per snapshot: default_backup_<timestamp>/

    static let schema = Schema([
        SpaceEntity.self,
        ProfileEntity.self,
        TabEntity.self,
        FolderEntity.self,
        TabsStateEntity.self,
        HistoryEntity.self,
        ExtensionEntity.self,
    ])

    // MARK: - URLs
    nonisolated private static var appSupportURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "Nook"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error(
                "Failed to create Application Support directory: \(String(describing: error), privacy: .public)"
            )
        }
        return dir
    }

    nonisolated private static var storeURL: URL {
        appSupportURL.appendingPathComponent(storeFileName, isDirectory: false)
    }
    nonisolated private static var backupsDirectoryURL: URL {
        let dir = appSupportURL.appendingPathComponent("Backups", isDirectory: true)
        let fm = FileManager.default
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            log.error(
                "Failed to create Backups directory: \(String(describing: error), privacy: .public)"
            )
        }
        return dir
    }

    // MARK: - Init
    /// Explicit isolated store; failure never resets the installed store.
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent(Self.storeFileName), cloudKitDatabase: .none)
        container = try ModelContainer(for: Self.schema, configurations: [configuration])
    }

    private init() {
        do {
            let config = ModelConfiguration(url: Self.storeURL, cloudKitDatabase: .none)
            container = try ModelContainer(for: Self.schema, configurations: [config])
            Self.log.info("SwiftData container initialized successfully")
        } catch {
            let classification = Self.classifyStoreError(error)
            Self.log.error(
                "SwiftData container initialization failed. Classification=\(String(describing: classification)) error=\(String(describing: error), privacy: .public)"
            )

            switch classification {
            case .schemaMismatch:
                // Attempt a safe reset with optional backup
                var didCreateBackup = false
                do {
                    _ = try Self.createBackup()
                    didCreateBackup = true
                } catch let backupError as PersistenceBackupError {
                    switch backupError {
                    case .storeNotFound:
                        // Treat as recoverable: proceed without a backup
                        Self.log.notice("No existing store to back up. Proceeding with reset.")
                    case .noBackupsFound:
                        // Not expected here but log just in case
                        Self.log.notice("No backups found when attempting to create backup.")
                    }
                } catch {
                    // Never delete a store that could not be copied: the user's tabs live only there.
                    Self.log.fault(
                        "Backup attempt failed: \(String(describing: error), privacy: .public). Not deleting store."
                    )
                    fatalError("SwiftData store could not be opened or backed up; store left untouched: \(error)")
                }

                do {
                    try Self.deleteStore()
                    Self.log.notice(
                        "Deleted existing store (and sidecars) for schema-mismatch recovery")

                    let config = ModelConfiguration(url: Self.storeURL, cloudKitDatabase: .none)
                    container = try ModelContainer(for: Self.schema, configurations: [config])
                    Self.log.notice(
                        "Recreated SwiftData container after schema mismatch using configured URL")
                } catch {
                    // On any failure, attempt to restore backup (if one was made) and abort
                    if didCreateBackup {
                        do {
                            try Self.restoreFromBackup()
                            Self.log.fault(
                                "Restored store from latest backup after failed recovery attempt")
                        } catch {
                            Self.log.fault(
                                "Failed to restore store from backup: \(String(describing: error), privacy: .public)"
                            )
                        }
                    }
                    fatalError(
                        "Failed to recover from schema mismatch. Aborting to protect data integrity: \(error)"
                    )
                }

            case .diskSpace:
                Self.log.fault(
                    "Store initialization failed due to insufficient disk space. Not deleting store."
                )
                fatalError(
                    "SwiftData initialization failed due to insufficient disk space: \(error)")

            case .corruption:
                Self.log.fault(
                    "Store appears corrupted. Not deleting store. Please investigate backups manually."
                )
                fatalError("SwiftData initialization failed due to suspected corruption: \(error)")

            case .other:
                Self.log.error(
                    "Store initialization failed with unclassified error. Not deleting store.")
                fatalError("SwiftData initialization failed: \(error)")
            }
        }
    }

    // MARK: - Error Classification
    private enum StoreErrorType { case schemaMismatch, diskSpace, corruption, other }
    private static func classifyStoreError(_ error: Error) -> StoreErrorType {
        let ns = error as NSError
        let domain = ns.domain
        let code = ns.code
        let desc = (ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? ns.localizedDescription
        let lower = (desc + " " + domain).lowercased()

        // Disk space: POSIX ENOSPC or clear full-disk wording
        if domain == NSPOSIXErrorDomain && code == 28 { return .diskSpace }
        if lower.contains("no space left") || lower.contains("disk full") { return .diskSpace }

        // Schema mismatch / migration issues
        if lower.contains("migration") || lower.contains("incompatible") || lower.contains("model")
            || lower.contains("version hash") || lower.contains("mapping model")
            || lower.contains("schema")
        {
            return .schemaMismatch
        }

        // Corruption indicators (SQLite/CoreData wording)
        if lower.contains("corrupt") || lower.contains("malformed")
            || lower.contains("database disk image is malformed")
            || lower.contains("file is encrypted or is not a database")
        {
            return .corruption
        }

        return .other
    }

    // MARK: - Backup / Restore
    private enum PersistenceBackupError: Error { case storeNotFound, noBackupsFound }

    // Include SQLite sidecars (-wal/-shm) and back up into a directory
    nonisolated private static func createBackup() throws -> URL {
        try Self.runBlockingOnUtilityQueue {
            let fm = FileManager.default
            let source = Self.storeURL
            guard fm.fileExists(atPath: source.path) else {
                Self.log.info(
                    "No existing store found to back up at \(source.path, privacy: .public)")
                throw PersistenceBackupError.storeNotFound
            }

            // Ensure backups root exists
            let backupsRoot = Self.backupsDirectoryURL

            // Create a timestamped backup directory
            let stamp = Self.makeBackupTimestamp()
            let dirName = "\(Self.backupPrefix)\(stamp)"
            let backupDir = backupsRoot.appendingPathComponent(dirName, isDirectory: true)
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

            // Gather store + sidecars
            let candidates = [source] + Self.sidecarURLs(for: source)
            for file in candidates {
                if fm.fileExists(atPath: file.path) {
                    let dest = backupDir.appendingPathComponent(
                        file.lastPathComponent, isDirectory: false)
                    do {
                        try fm.copyItem(at: file, to: dest)
                    } catch {
                        Self.log.error(
                            "Failed to copy \(file.lastPathComponent, privacy: .public) to backup: \(String(describing: error), privacy: .public)"
                        )
                        throw error
                    }
                }
            }

            return backupDir
        }
    }

    // Restore the latest backup directory by copying files back next to the store
    nonisolated private static func restoreFromBackup() throws {
        try Self.runBlockingOnUtilityQueue {
            let fm = FileManager.default
            let root = Self.backupsDirectoryURL
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles])
            } catch {
                Self.log.error(
                    "Failed to list backups: \(String(describing: error), privacy: .public)")
                throw error
            }

            let backups = contents.filter { url in
                url.lastPathComponent.hasPrefix(Self.backupPrefix)
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            guard !backups.isEmpty else { throw PersistenceBackupError.noBackupsFound }

            // Pick the most recently modified backup directory
            let latest = backups.max { lhs, rhs in
                let l =
                    (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? Date.distantPast
                let r =
                    (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? Date.distantPast
                return l < r
            }!

            // Remove current store files first
            try Self.deleteStore()

            // Copy all files from backup dir back to app support dir
            let backupFiles = try fm.contentsOfDirectory(
                at: latest, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for file in backupFiles {
                let dest = Self.appSupportURL.appendingPathComponent(
                    file.lastPathComponent, isDirectory: false)
                do { try fm.copyItem(at: file, to: dest) } catch {
                    Self.log.error(
                        "Restore copy failed for \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    throw error
                }
            }

            Self.log.notice(
                "Restored store from backup directory: \(latest.lastPathComponent, privacy: .public)"
            )
        }
    }

    // Deletes the base store and known SQLite sidecars if present
    nonisolated private static func deleteStore() throws {
        try Self.runBlockingOnUtilityQueue {
            let fm = FileManager.default
            let base = Self.storeURL
            let files = [base] + Self.sidecarURLs(for: base)
            for file in files {
                if fm.fileExists(atPath: file.path) {
                    do { try fm.removeItem(at: file) } catch {
                        Self.log.error(
                            "Failed to remove \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                        )
                        throw error
                    }
                }
            }
        }
    }

    // MARK: - Helpers
    nonisolated private static func sidecarURLs(for base: URL) -> [URL] {
        // SQLite commonly uses -wal and -shm sidecars when WAL journaling is active
        // Compose manually to append -wal/-shm
        let walURL = URL(fileURLWithPath: base.path + "-wal")
        let shmURL = URL(fileURLWithPath: base.path + "-shm")
        return [walURL, shmURL]
    }

    nonisolated private static func makeBackupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: Date())
    }

    // Run a throwing closure on a background utility queue and block until it finishes
    nonisolated private static func runBlockingOnUtilityQueue<T>(_ work: @escaping () throws -> T)
        throws -> T
    {
        let group = DispatchGroup()
        group.enter()
        var result: Result<T, Error>!
        DispatchQueue.global(qos: .utility).async {
            do { result = .success(try work()) } catch { result = .failure(error) }
            group.leave()
        }
        group.wait()
        switch result! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

@MainActor
class BrowserManager: ObservableObject {
    // Legacy global state - kept for backward compatibility during transition
    /// Tracks which pinned tab tile is hovered (for middle-click → reset to pinned URL)
    @Published var hoveredPinnedTabId: UUID? = nil
    @Published var sidebarWidth: CGFloat = SidebarWidth.standard
    @Published var sidebarContentWidth: CGFloat = 234
    @Published var isSidebarVisible: Bool = true
    @Published var isCommandPaletteVisible: Bool = false
    // Frame of the URL bar within the window; used to anchor the mini palette precisely
    @Published var urlBarFrame: CGRect = .zero
    @Published var shouldShowZoomPopup: Bool = false
    /// The website data store of the active window's space. Not @Published: a switch must not
    /// redraw every view observing BrowserManager.
    private let currentProfileSubject: CurrentValueSubject<Profile?, Never>

    var currentProfile: Profile? {
        get { currentProfileSubject.value }
        set { currentProfileSubject.send(newValue) }
    }

    var currentProfilePublisher: AnyPublisher<Profile?, Never> {
        currentProfileSubject.eraseToAnyPublisher()
    }

    /// True for the length of a space change, so views do not animate content from the old space
    /// into the new one.
    @Published var isSwitchingSpace: Bool = false
    private var transitionEndTask: Task<Void, Never>?
    // Tab closure undo notification
    @Published var showTabClosureToast: Bool = false
    /// The card offering to make Nook the default browser, in the window in front.
    @Published var showDefaultBrowserPrompt = false
    @Published var tabClosureToastCount: Int = 0
    @Published var isExtensionPopupActive: Bool = false

    /// Track tabs currently being synced to prevent recursive sync calls
    private var isSyncingTab: Set<UUID> = []

    var nativeOpenSettings: ((SettingsTabs) -> Void)?
    var nativeCreateIncognitoWindow: (() -> Void)?
    var nativeCreateWindow: (() -> Void)?

    var modelContext: ModelContext
    /// The tab model: tree, device state, window selection and live pages.
    let tabs: TabsController
    /// iCloud sync of spaces between the person's Macs.
    let spaceSyncManager: SpaceSyncManager
    var dialogManager: DialogManager
    var downloadManager: DownloadManager
    var authenticationManager: AuthenticationManager
    var historyManager: HistoryManager
    let cookieManager: CookieManager? = nil
    let cacheManager: CacheManager? = nil
    let extensionManager: ExtensionManager? = nil
    /// Store ids an import found, installed once a browser window can show their permission sheets.
    var pendingExtensionImports: [String] = []
    var splitManager: SplitViewManager
    var gradientColorManager: GradientColorManager
    var contentBlockerManager: ContentBlockerManager
    var sponsorBlockManager: SponsorBlockManager
    var findManager: FindManager
    let importManager: ImportManager
    let importSession: BrowserImportSession
    var zoomManager = ZoomManager()
    var keyboardShortcutManager: KeyboardShortcutManager?
    weak var mcpManager: MCPManager?
    weak var tabOrganizerManager: TabOrganizerManager?
    weak var nookSettings: NookSettingsService?
    weak var aiService: AIService?
    weak var aiConfigService: AIConfigService?

    var siteRoutingManager: SiteRoutingManager
    var externalMiniWindowManager = ExternalMiniWindowManager()
    let peekManager = PeekManager()
    let autofillManager = AutofillManager()
    weak var windowRegistry: WindowRegistry?

    private var savedSidebarWidth: CGFloat = SidebarWidth.standard
    private let userDefaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    /// Profiles from before spaces owned their data, read only to seed a first launch that has no
    /// tab files but does have data stores worth keeping. `ProfileEntity` is otherwise unused.
    private static func legacyProfileRecords(in context: ModelContext) -> [(id: UUID, name: String)] {
        let descriptor = FetchDescriptor<ProfileEntity>(sortBy: [SortDescriptor(\.index, order: .forward)])
        let entities = (try? context.fetch(descriptor)) ?? []
        return entities.map { ($0.id, $0.name) }
    }

    let engine: Profile.Engine = .chromium

    init(
        settings: NookSettingsService,
        windowRegistry: WindowRegistry,
        importManager: ImportManager,
        persistence: Persistence,
        userDefaults: UserDefaults,
        downloadManager: DownloadManager,
        tabsDirectory: URL,
        cloudSyncEnabled: Bool = false,
        vault: VaultService? = nil
    ) {
        self.nookSettings = settings
        self.modelContext = persistence.container.mainContext
        self.userDefaults = userDefaults
        let blocker = ContentBlockerManager(settings: settings,
            storageDirectory: tabsDirectory.deletingLastPathComponent().appendingPathComponent("ContentBlocker/FilterLists"),
            nativeNetworkBlocking: true)
        let sponsorBlock = SponsorBlockManager(settings: settings)
        let siteRouting = SiteRoutingManager(settings: settings)
        self.contentBlockerManager = blocker
        self.sponsorBlockManager = sponsorBlock
        self.siteRoutingManager = siteRouting
        let tabs = TabsController(
            settings: settings, windowRegistry: windowRegistry, blocker: blocker,
            sponsorBlock: sponsorBlock, siteRouting: siteRouting,
            legacyProfiles: Self.legacyProfileRecords(in: modelContext),
            legacyTree: { [modelContext] in LegacyTabImport.tree(from: modelContext) },
            profileEngine: .chromium,
            directory: tabsDirectory)
        self.tabs = tabs
        self.spaceSyncManager = SpaceSyncManager(tabs: tabs, enabled: cloudSyncEnabled)
        // The first space's data store is the one the app starts on.
        let initialProfile = tabs.orderedSpaces.first.flatMap { tabs.profile(forSpace: $0.id) }
        self.currentProfileSubject = CurrentValueSubject(initialProfile)

        self.dialogManager = DialogManager()
        self.downloadManager = downloadManager
        self.authenticationManager = AuthenticationManager(userDefaults: self.userDefaults)
        // Initialize managers with the current space's data store for isolation
        self.historyManager = HistoryManager(
            context: modelContext, profileId: initialProfile?.id,
            pageTextURL: tabsDirectory.deletingLastPathComponent()
                .appendingPathComponent("History/page-text.sqlite"),
            indexURL: tabsDirectory.deletingLastPathComponent()
                .appendingPathComponent("History/history-index.sqlite"),
            halfLifeDays: settings.historyHalfLifeDays,
            wordStops: PaletteText.stops(from: settings.paletteWordStops))
        self.splitManager = SplitViewManager()
        self.gradientColorManager = GradientColorManager()
        self.findManager = FindManager()
        self.importManager = importManager
        self.importSession = BrowserImportSession()

        // Phase 2: wire dependencies and perform side effects (safe to use self)
        self.splitManager.browserManager = self
        self.windowRegistry = windowRegistry
        self.tabs.history = self.historyManager
        self.historyManager.onHistoryCleared = { [caches = tabs.translationCaches] profile, cutoff in
            Task { await caches.erase(profile: profile, usedBefore: cutoff) }
        }
        self.tabs.sessionDelegate = self
        self.tabs.tabEvents = self
        self.tabs.alerts = self
        NotificationCenter.default.addObserver(
            forName: NookSettingsService.paletteWordStopsDidChange, object: nil, queue: .main
        ) { [weak self, settings] _ in
            MainActor.assumeIsolated {
                self?.historyManager.setWordStops(PaletteText.stops(from: settings.paletteWordStops))
            }
        }
        let vault = vault ?? VaultService(settings: settings)
        vault.presenter = autofillManager
        // Native Chromium retains its stock WebAuthn/security-key implementation.
        self.tabs.vault = vault
        if case .readOnly(let reason) = tabs.loadOutcome {
            TabsController.presentReadOnlyAlert(reason: reason, directory: tabs.directory)
        }
        self.gradientColorManager.setImmediate(.default)
        self.contentBlockerManager.attach(host: self)
        self.contentBlockerManager.prepareLinkCleaning()
        self.siteRoutingManager.host = self
        self.peekManager.attach(browserManager: self)
        // Migrate legacy history entries (with nil profile) to default profile to avoid cross-profile leakage
        self.migrateUnassignedDataToDefaultProfile()
        loadSidebarSettings()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabManagementModeChange),
            name: .tabManagementModeChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(self,
            selector: #selector(handleTabManagementModeChange), name: .startupLoadModeChanged, object: nil)

        NotificationCenter.default.addObserver(
            forName: .adBlockerEnabledChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let enabled = note.userInfo?["enabled"] as? Bool else { return }
            Task { @MainActor [weak self] in
                self?.contentBlockerManager.setEnabled(enabled)
            }
        }

    }

    // MARK: - Startup Loading

    private var startupWarmTasks: [UUID: Task<Void, Never>] = [:]
    private var nativeWarmAttempt: UUID?

    func cancelNativeStartupWarming() {
        guard engine == .chromium else { return }
        // Every close affects the global displayed-page barrier, even when
        // the optional task belongs to a different window.
        nativeWarmAttempt = nil
        let tasks = startupWarmTasks.values
        startupWarmTasks.removeAll()
        for task in tasks { task.cancel() }
    }

    func nativeStartupWindowPresented(_ window: BrowserWindowState) {
        guard engine == .chromium, startupWarmTasks.isEmpty, !window.isIncognito,
              windowRegistry?.windows[window.id] === window,
              tabs.settings.startupLoadMode != .nothing else { return }
        let attempt = UUID()
        nativeWarmAttempt = attempt
        let tabs = self.tabs
        startupWarmTasks[window.id] = Task { @MainActor [weak self, weak window] in
            guard let window else { return }
            defer {
                if self?.nativeWarmAttempt == attempt {
                    self?.nativeWarmAttempt = nil
                    self?.startupWarmTasks[window.id] = nil
                }
            }
            await tabs.warmNativeStartupPages(in: window, while: { [weak self] in
                self?.nativeWarmAttempt == attempt
            })
        }
    }
    // MARK: - Space Switching

    /// A window changed space. A space owns its login context, so cookies, cache and history
    /// follow it. Only the active window's space sets the app-wide managers.
    func windowSpaceChanged(_ windowState: BrowserWindowState) {
        if engine == .chromium {
            cancelNativeStartupWarming()
            nativeStartupWindowPresented(windowState)
        }
        guard !windowState.isIncognito else { return }
        guard windowRegistry?.activeWindow == nil || windowRegistry?.activeWindow?.id == windowState.id else { return }
        guard let spaceID = windowState.spaceID, let profile = tabs.profile(forSpace: spaceID),
              currentProfile?.id != profile.id else { return }

        isSwitchingSpace = true
        currentProfile = profile
        // No animation transaction: one here made the window render mid-switch. Settings loads
        // the cookie and data lists when it opens; reading them here stalled the switch.
        cookieManager?.switchDataStore(profile.dataStore, profileId: profile.id, eagerLoad: false)
        cacheManager?.switchDataStore(profile.dataStore, profileId: profile.id, eagerLoad: false)
        historyManager.switchProfile(profile.id)
        transitionEndTask?.cancel()
        transitionEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.spaceSwitchDuration))
            guard !Task.isCancelled else { return }
            self?.isSwitchingSpace = false
        }
    }

    private static let spaceSwitchDuration: TimeInterval = 0.2

    func updateSidebarWidth(_ width: CGFloat) {
        if let activeWindow = windowRegistry?.activeWindow {
            updateSidebarWidth(width, for: activeWindow)
            return
        }
        sidebarWidth = width
        savedSidebarWidth = width
        sidebarContentWidth = max(width - 16, 0)
    }

    func updateSidebarWidth(_ width: CGFloat, for windowState: BrowserWindowState) {
        windowState.sidebarWidth = width
        windowState.savedSidebarWidth = width
        windowState.sidebarContentWidth = max(width - 16, 0)
        if windowRegistry?.activeWindow?.id == windowState.id {
            sidebarWidth = width
            savedSidebarWidth = width
            sidebarContentWidth = max(width - 16, 0)
        }
    }

    func saveSidebarWidthToDefaults() {
        saveSidebarSettings()
    }

    func toggleSidebar() {
        if let windowState = windowRegistry?.activeWindow {
            toggleSidebar(for: windowState)
        } else {
            withAnimation(.easeInOut(duration: 0.1)) {
                isSidebarVisible.toggle()
                // Width stays the same whether visible or hidden
            }
            saveSidebarSettings()
        }
    }

    func toggleSidebar(for windowState: BrowserWindowState) {
        withAnimation(.easeInOut(duration: 0.1)) {
            windowState.isSidebarVisible.toggle()
            // Width stays the same whether visible or hidden
        }
        if !windowState.isSidebarVisible { sidebarPiPSidebarHidden(in: windowState) }
        if windowRegistry?.activeWindow?.id == windowState.id {
            isSidebarVisible = windowState.isSidebarVisible
            sidebarWidth = windowState.sidebarWidth
            savedSidebarWidth = windowState.savedSidebarWidth
            sidebarContentWidth = windowState.sidebarContentWidth
        }
        saveSidebarSettings()
    }

    func toggleAISidebar() {
        guard nookSettings?.showAIAssistant == true else { return }
        if let windowState = windowRegistry?.activeWindow {
            toggleAISidebar(for: windowState)
        }
    }

    /// Opens the right column on a dev tab, or closes it when that tab is already showing.
    func toggleDevPanel(_ tab: DevPanelTab) {
        if tabs.profileEngine == .chromium {
            guard let window = windowRegistry?.activeWindow,
                  windowRegistry?.windows[window.id] === window,
                  let keyWindow = CommandWindow.key, window.window === keyWindow,
                  let page = frontPage(in: window),
                  let native = page.navigation as? ChromiumPageNavigation,
                  tabs.nativePageHost?.isNativeSelection(native, in: window) == true else { return }
            let command: PageCommand
            switch tab {
            case .console: command = .developerConsole
            case .network: command = .developerNetwork
            case .perf: command = .developerPerformance
            default: return
            }
            let serial = page.nativeNavigationSerial
            let owner = native.nativeWindowID, tabID = native.nativeTabID
            withDeveloperCapture { [weak self, weak window, weak page, weak native] in
                guard let self, let window, let page, let native,
                      page.navigation === native, page.nativeNavigationSerial == serial,
                      native.nativeWindowID == owner, native.nativeTabID == tabID else { return }
                _ = self.performNativePageCommand(command, in: window, page: page)
            }
            return
        }
        withDeveloperCapture { [weak self] in self?.showDevPanel(tab) }
    }

    private func showDevPanel(_ tab: DevPanelTab) {
        guard let windowState = windowRegistry?.activeWindow else { return }
        withAnimation(NookDesign.Motion.standard) {
            if windowState.isSidebarAIChatVisible, windowState.devPanelTab == tab {
                windowState.isSidebarAIChatVisible = false
            } else {
                windowState.devPanelTab = tab
                windowState.isSidebarAIChatVisible = true
                windowState.isSidebarMenuVisible = false
            }
        }
    }

    func toggleAISidebar(for windowState: BrowserWindowState) {
        guard nookSettings?.showAIAssistant == true else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            if windowState.isSidebarAIChatVisible {
                windowState.isSidebarAIChatVisible = false
            } else {
                windowState.isSidebarAIChatVisible = true
                windowState.isSidebarMenuVisible = false
            }
        }
    }

    // MARK: - Extension Library Panel

    /// Toggles the site controls for the active window via keyboard shortcut. The window's overlay
    /// watches this flag; there is no panel to drive.
    func toggleExtensionLibrary() {
        guard let windowState = windowRegistry?.activeWindow else { return }
        windowState.isExtensionLibraryVisible.toggle()
    }

    // MARK: - Sidebar width access for overlays
    /// Returns the last saved sidebar width (used when sidebar is collapsed to size hover overlay)
    func getSavedSidebarWidth(for windowState: BrowserWindowState? = nil) -> CGFloat {
        if let state = windowState {
            return state.savedSidebarWidth
        }
        if let active = windowRegistry?.activeWindow {
            return active.savedSidebarWidth
        }
        return savedSidebarWidth
    }


    func toggleTopBarAddressView() {
        withAnimation(.easeInOut(duration: 0.2)) {
            nookSettings?.topBarAddressView.toggle()
        }
    }

    // MARK: - Dialog Methods

    func showQuitDialog() {
        // The dialog draws inside a browser window, so one must exist and be in front of Settings.
        if self.nookSettings?.askBeforeQuit == true, let front = windowRegistry?.dialogWindow {
            front.windowHandle?.bringToFront()
            dialogManager.showQuitDialog(
                onAlwaysQuit: {
                    self.nookSettings?.askBeforeQuit = false
                    self.quitApplication()
                },
                onQuit: {
                    self.quitApplication()
                }
            )
        } else {
            NSApplication.shared.terminate(nil)
        }

    }

    func showDialog<Content: View>(_ dialog: Content) {
        dialogManager.showDialog(dialog)
    }

    func showDialog<Content: View>(@ViewBuilder builder: () -> Content) {
        dialogManager.showDialog(builder: builder)
    }

    // MARK: - Space Settings

    /// Opens Space Settings for the active window's space, or a notice when there is none.
    func showSpaceSettings() {
        guard let spaceID = windowRegistry?.activeWindow?.spaceID, tabs.space(spaceID) != nil else {
            dialogManager.showDialog {
                StandardDialog(
                    header: {
                        DialogHeader(
                            icon: "square.grid.2x2",
                            title: "No Space Available",
                            subtitle: "Create a space to change its settings."
                        )
                    },
                    content: { Color.clear.frame(height: 0) },
                    footer: {
                        DialogFooter(rightButtons: [
                            DialogButton(text: "OK", variant: .primary) { [weak self] in
                                self?.closeDialog()
                            }
                        ])
                    }
                )
            }
            return
        }
        openSettings(tab: .spaces)
    }

    /// Opens the Boost panel over the page in front. Nothing is saved until the person saves, and a
    /// private window, which saves no Boost, opens none.
    func openBoostPanel(in windowState: BrowserWindowState) {
        guard !windowState.isIncognito, let url = frontPage(in: windowState)?.url,
              url.scheme == "http" || url.scheme == "https",
              !Boost.normalizeHost(url.host ?? "").isEmpty
        else { return }
        windowState.isBoostPanelVisible = true
    }

    /// Opens the Boost panel on its list of every Boost.
    func openBoostLibrary(in windowState: BrowserWindowState) {
        windowState.boostPanelOpensLibrary = true
        openBoostPanel(in: windowState)
        if !windowState.isBoostPanelVisible { windowState.boostPanelOpensLibrary = false }
    }

    func openSettings(tab: SettingsTabs) {
        nativeOpenSettings?(tab)
    }

    func closeDialog() {
        dialogManager.closeDialog()
    }

    private func quitApplication() {
        // Leave open tabs intact for the native quit snapshot.
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Private Methods
    private func loadSidebarSettings() {
        let savedWidth = userDefaults.double(forKey: "sidebarWidth")
        let savedVisibility = userDefaults.bool(forKey: "sidebarVisible")

        // Check if this is first launch (no saved width)
        let isFirstLaunch = savedWidth == 0

        if savedWidth > 0 {
            // A width saved under an older, smaller minimum would hide the history buttons.
            savedSidebarWidth = min(min(max(savedWidth, SidebarWidth.min), SidebarWidth.max), SidebarWidth.max)
            // Kept while hidden: showing the sidebar does not restore it, and the hover overlay uses it.
            sidebarWidth = savedSidebarWidth
        } else {
            // First launch: ensure sidebar is visible with default width
            savedSidebarWidth = SidebarWidth.standard
            sidebarWidth = SidebarWidth.standard
        }
        sidebarContentWidth = max(sidebarWidth - 16, 0)

        // On first launch, default to visible sidebar
        isSidebarVisible = isFirstLaunch ? true : savedVisibility
    }

    private func saveSidebarSettings() {
        userDefaults.set(savedSidebarWidth, forKey: "sidebarWidth")
        userDefaults.set(isSidebarVisible, forKey: "sidebarVisible")
    }

    @objc private func handleTabManagementModeChange(_ notification: Notification) {
        guard notification.object as? NookSettingsService === tabs.settings else { return }
        cancelNativeStartupWarming()
        if let window = windowRegistry?.activeWindow { nativeStartupWindowPresented(window) }
    }

    deinit {
        for task in startupWarmTasks.values { task.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Privacy-Compliant Management

    func clearThirdPartyCookies() {
        Task {
            await cookieManager?.deleteThirdPartyCookies()
        }
    }

    func clearHighRiskCookies() {
        Task {
            await cookieManager?.deleteHighRiskCookies()
        }
    }

    func performPrivacyCleanup() {
        Task {
            await cookieManager?.performPrivacyCleanup()
            await cacheManager?.performPrivacyCompliantCleanup()
        }
    }

    /// History written before entries carried a space belongs to the first space.
    func migrateUnassignedDataToDefaultProfile() {
        guard let firstSpace = tabs.orderedSpaces.first?.id else { return }
        assignDefaultProfileToExistingData(firstSpace)
    }

    func assignDefaultProfileToExistingData(_ profileId: UUID) {
        do {
            let predicate = #Predicate<HistoryEntity> { $0.profileId == nil }
            let descriptor = FetchDescriptor<HistoryEntity>(predicate: predicate)
            let entities = try modelContext.fetch(descriptor)
            var updated = 0
            for entity in entities {
                entity.profileId = profileId
                updated += 1
            }
            try modelContext.save()
            #if DEBUG
            print(
                "🔧 [BrowserManager] Assigned default profile to \(updated) legacy history entries")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [BrowserManager] Failed to assign default profile to existing data: \(error)")
            #endif
        }
    }

    func clearPersonalDataCache() {
        Task {
            await cacheManager?.clearPersonalDataCache()
        }
    }

    func clearFaviconCache() {
        cacheManager?.clearFaviconCache()
    }

    // MARK: - Extension Management

    func manageExtensions() {
        if engine == .chromium { openNativeExtensionControls(); return }
        openSettings(tab: .extensions)
    }

    /// Utility/settings windows must not borrow a stale active product identity.
    private func openNativeExtensionControls() {
        guard let window = windowRegistry?.activeWindow, let key = CommandWindow.key,
              window.window === key else { return }
        tabs.openExtensionControls(in: window) { [weak window] result in
            if case .failure(let error) = result {
                window?.copyToastText = error.localizedDescription
                window?.isShowingCopyURLToast = true
            }
        }
    }

    func showExtensionInstallDialog() {
        if engine == .chromium { openNativeExtensionControls(); return }
        extensionManager?.showExtensionInstallDialog()
    }

    func enableExtension(_ extensionId: String) {
        extensionManager?.enableExtension(extensionId)
    }

    func disableExtension(_ extensionId: String) {
        extensionManager?.disableExtension(extensionId)
    }

    func uninstallExtension(_ extensionId: String) {
        extensionManager?.uninstallExtension(extensionId)
    }

    /// Set the active window state (called when a window gains focus)
    /// NOTE: This is called BY the WindowRegistry callback, so we don't call setActive again
    func setActiveWindowState(_ windowState: BrowserWindowState) {
        // DO NOT call windowRegistry?.setActive(windowState) here - that would cause infinite recursion!
        // This method is called FROM the onActiveWindowChange callback
        sidebarWidth = windowState.sidebarWidth
        savedSidebarWidth = windowState.savedSidebarWidth
        sidebarContentWidth = windowState.sidebarContentWidth
        isSidebarVisible = windowState.isSidebarVisible
        urlBarFrame = windowState.urlBarFrame
        // Regular windows get their space accent from the sidebar; private windows keep their own look.
        if windowState.isIncognito {
            gradientColorManager.setImmediate(.incognito)
        }
        isCommandPaletteVisible = windowState.isCommandPaletteVisible
        // The newly active window's space is the app's login context.
        windowSpaceChanged(windowState)
        moveSidebarPiP(to: windowState)
    }

    // MARK: - Window-Aware Tab Operations

    /// Older app helpers still ask for a WK view. Chromium has no such view.
    func getWebView(for tabId: UUID, in windowId: UUID) -> WKWebView? { nil }

    func createNewWindow() {
        nativeCreateWindow?()
    }

    func createIncognitoWindow() {
        nativeCreateIncognitoWindow?()
    }

    /// Toggle full screen for the active window
    func toggleFullScreenForActiveWindow() {
        guard let activeWindow = windowRegistry?.activeWindow?.window else { return }
        activeWindow.toggleFullScreen(nil)
    }

    /// Show the downloads panel in the sidebar
    func showDownloads() {
        guard let windowState = windowRegistry?.activeWindow else { return }
        windowState.sidebarMenuSelectedTab = .downloads
        LibraryMotion.present(windowState)
    }

    /// Opens the Library on the page it last showed; again puts it away.
    func toggleLibrary() {
        guard let windowState = windowRegistry?.activeWindow else { return }
        if windowState.isSidebarMenuVisible { LibraryMotion.close(windowState) } else { LibraryMotion.present(windowState) }
    }

    /// Shows History as a page over the web content, as Arc does; again hides it.
    func showHistory() {
        guard let windowState = windowRegistry?.activeWindow else { return }
        if engine == .chromium {
            if windowState.isSidebarMenuVisible, windowState.sidebarMenuSelectedTab == .history {
                LibraryMotion.close(windowState)
            } else {
                windowState.sidebarMenuSelectedTab = .history
                LibraryMotion.present(windowState)
            }
            return
        }
        withAnimation(NookDesign.Motion.standard) {
            windowState.isHistoryPageVisible.toggle()
        }
    }

    // MARK: - Tab Closure Undo Notification

    func showTabClosureToast(tabCount: Int) {
        tabClosureToastCount = tabCount
        showTabClosureToast = true

        // Auto-hide the toast after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.hideTabClosureToast()
        }
    }

    func hideTabClosureToast() {
        showTabClosureToast = false
        tabClosureToastCount = 0
    }

    func undoCloseTab() {
        guard let window = windowRegistry?.activeWindow else { return }
        tabs.reopenLastClosed(in: window)
    }
}

// MARK: - Update Handling

extension BrowserManager {
    // MARK: - Default Browser

    func setAsDefaultBrowser() {
        DefaultBrowser.makeNook { [weak self] _ in self?.showDefaultBrowserPrompt = false }
    }

    func offerDefaultBrowserIfNeeded() {
        guard let settings = nookSettings,
              DefaultBrowserPrompt.shouldAsk(isDefault: DefaultBrowser.isNook, dismissedAt: settings.defaultBrowserPromptDismissedAt)
        else { return }
        showDefaultBrowserPrompt = true
    }

    func dismissDefaultBrowserPrompt() {
        nookSettings?.defaultBrowserPromptDismissedAt = Date()
        showDefaultBrowserPrompt = false
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
