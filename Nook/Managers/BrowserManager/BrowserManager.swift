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
import SwiftData
import SwiftUI
import NookBlocker
import NookDesign
import NookSettings
import NookTweaks
import NookUI
import NookWeb

@MainActor
final class Persistence {
    let container: ModelContainer

    static let schema = Schema([
        SpaceEntity.self,
        ProfileEntity.self,
        TabEntity.self,
        FolderEntity.self,
        TabsStateEntity.self,
        HistoryEntity.self,
        ExtensionEntity.self,
    ])

    /// Startup chooses the store directory before creating the browser manager.
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("default.store"), cloudKitDatabase: .none)
        container = try ModelContainer(for: Self.schema, configurations: [configuration])
    }
}

/// Automatic warming starts with the first native presentation. While active
/// it can follow its owner to a new space or profile. Preference changes are
/// an explicit request to re-evaluate the current window.
struct NativeStartupWarmTrigger {
    enum Event { case presented, contextChanged, preferencesChanged }

    struct Context: Equatable {
        let window: UUID
        let space: UUID?
        let profile: UUID?
    }

    struct Attempt {
        let id = UUID()
        let context: Context
    }

    private var hasPresented = false
    private(set) var attempt: Attempt?

    mutating func shouldReplace(for event: Event, context: Context?) -> Bool {
        switch event {
        case .presented:
            guard !hasPresented, context != nil else { return false }
            hasPresented = true
            return true
        case .contextChanged:
            guard let attempt, let context else { return false }
            return attempt.context.window == context.window && attempt.context != context
        case .preferencesChanged:
            return hasPresented
        }
    }

    mutating func begin(_ context: Context) -> Attempt {
        let next = Attempt(context: context)
        attempt = next
        return next
    }

    mutating func finish(_ id: UUID? = nil) {
        if id == nil || attempt?.id == id { attempt = nil }
    }
}

@MainActor
class BrowserManager: ObservableObject {
    // Legacy global state - kept for backward compatibility during transition
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
    var historyManager: HistoryManager
    var splitManager: SplitViewManager
    var gradientColorManager: GradientColorManager
    var contentBlockerManager: ContentBlockerManager
    let importManager: ImportManager
    let importSession: BrowserImportSession
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
            storageDirectory: tabsDirectory.deletingLastPathComponent().appendingPathComponent("ContentBlocker/FilterLists"))
        let siteRouting = SiteRoutingManager(settings: settings)
        self.contentBlockerManager = blocker
        self.siteRoutingManager = siteRouting
        let tabs = TabsController(
            settings: settings, windowRegistry: windowRegistry, blocker: blocker,
            siteRouting: siteRouting,
            legacyProfiles: Self.legacyProfileRecords(in: modelContext),
            legacyTree: { [modelContext] in LegacyTabImport.tree(from: modelContext) },
            directory: tabsDirectory)
        self.tabs = tabs
        self.spaceSyncManager = SpaceSyncManager(tabs: tabs, enabled: cloudSyncEnabled)
        // The first space's data store is the one the app starts on.
        let initialProfile = tabs.orderedSpaces.first.flatMap { tabs.profile(forSpace: $0.id) }
        self.currentProfileSubject = CurrentValueSubject(initialProfile)

        self.dialogManager = DialogManager()
        self.downloadManager = downloadManager
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

    private var nativeWarmTrigger = NativeStartupWarmTrigger()
    private var startupWarmTask: Task<Void, Never>?

    func cancelNativeStartupWarming() {
        nativeWarmTrigger.finish()
        startupWarmTask?.cancel()
        startupWarmTask = nil
    }

    func nativeStartupWindowPresented(_ window: BrowserWindowState) {
        updateNativeStartupWarming(.presented, in: window)
    }

    private func updateNativeStartupWarming(_ event: NativeStartupWarmTrigger.Event, in window: BrowserWindowState?) {
        let context: NativeStartupWarmTrigger.Context? = window.flatMap { window in
            guard !window.isIncognito, windowRegistry?.windows[window.id] === window else { return nil }
            return .init(window: window.id, space: window.spaceID,
                         profile: window.spaceID.flatMap { self.tabs.tree.dataStoreID(for: $0) })
        }
        guard nativeWarmTrigger.shouldReplace(for: event, context: context) else { return }
        cancelNativeStartupWarming()
        guard let window, let context, tabs.settings.startupLoadMode != .nothing else { return }
        let attempt = nativeWarmTrigger.begin(context)
        let tabs = self.tabs
        startupWarmTask = Task { @MainActor [weak self, weak window] in
            defer {
                if self?.nativeWarmTrigger.attempt?.id == attempt.id {
                    self?.nativeWarmTrigger.finish(attempt.id)
                    self?.startupWarmTask = nil
                }
            }
            guard let window else { return }
            await tabs.warmNativeStartupPages(in: window, while: { [weak self] in
                self?.nativeWarmTrigger.attempt?.id == attempt.id
            })
        }
    }
    // MARK: - Space Switching

    /// App-owned history follows the active window’s profile. Chromium owns its site data.
    func windowSpaceChanged(_ windowState: BrowserWindowState) {
        updateNativeStartupWarming(.contextChanged, in: windowState)
        guard !windowState.isIncognito else { return }
        guard windowRegistry?.activeWindow == nil || windowRegistry?.activeWindow?.id == windowState.id else { return }
        guard let spaceID = windowState.spaceID, let profile = tabs.profile(forSpace: spaceID),
              currentProfile?.id != profile.id else { return }

        isSwitchingSpace = true
        currentProfile = profile
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

    func toggleSidebar(for windowState: BrowserWindowState) {
        withAnimation(.easeInOut(duration: 0.1)) {
            windowState.isSidebarVisible.toggle()
            // Width stays the same whether visible or hidden
        }
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
        updateNativeStartupWarming(.preferencesChanged, in: windowRegistry?.activeWindow)
    }

    deinit {
        startupWarmTask?.cancel()
        NotificationCenter.default.removeObserver(self)
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

    // MARK: - Extension Management

    func manageExtensions(deferred: Bool = false) {
        // Utility/settings windows must not borrow a stale active product identity.
        guard let window = windowRegistry?.activeWindow, let key = CommandWindow.key,
              window.window === key, !window.nativePresentationIsPreparing,
              !window.nativeSpaceSwitchIsUnresolved else { return }
        let space = window.spaceID, selection = window.selectedItemID
        let profile = tabs.extensionControlsProfileID(in: window)
        let open: @MainActor () -> Void = { [weak self, weak window, weak key] in
            guard let self, let window, let key, CommandWindow.key === key, window.window === key,
                  self.windowRegistry?.activeWindow === window,
                  self.windowRegistry?.windows[window.id] === window,
                  window.spaceID == space, window.selectedItemID == selection,
                  self.tabs.extensionControlsProfileID(in: window) == profile,
                  !window.nativePresentationIsPreparing, !window.nativeSpaceSwitchIsUnresolved else { return }
            self.tabs.openExtensionControls(in: window) { [weak window] result in
                if case .failure(let error) = result {
                    window?.copyToastText = error.localizedDescription
                    window?.isShowingCopyURLToast = true
                }
            }
        }
        if deferred { DispatchQueue.main.async { open() } }
        else { open() }
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
    }

    // MARK: - Window-Aware Tab Operations

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

    /// Toggles the History section of this window’s Library.
    func showHistory() {
        guard let windowState = windowRegistry?.activeWindow else { return }
        if windowState.isSidebarMenuVisible, windowState.sidebarMenuSelectedTab == .history {
            LibraryMotion.close(windowState)
        } else {
            windowState.sidebarMenuSelectedTab = .history
            LibraryMotion.present(windowState)
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
