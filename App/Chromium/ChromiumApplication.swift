import AppKit
import BarcChromium
import Darwin
import NookSettings
import NookWeb
import Observation
import SwiftUI

@MainActor
final class ChromiumApplication: ChromiumStartupBridge {
    private let bridge: BarcBridge
    private let engineMain: BarcEngineMain
    private var acceptsWindows = true
    private var didPresentInitialWindow = false
    private let miniAPI: ChromiumMiniWindowAPI
    private let configuration: ChromiumStartupConfiguration
    private let pageHost: ChromiumNativePageHost
    private let catalog: ChromiumWindowCatalog
    private let profileDeletion: ChromiumProfileDeletion
    private let downloads: ChromiumDownloads
    private let liveFetch: ChromiumLiveFetch
    private var blocker: ChromiumContentBlocker?
    private var pageTweaks: ChromiumPageTweaks?
    private var blockerRegistered = false
    private var admission: ChromiumCreatedPageAdmission?
    private let profilePages: ChromiumProfilePagePresenter
    private let profileSearch: ChromiumProfileSearch
    private var devMCPSettingsGeneration: UInt64 = 0
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    private var storage: ChromiumAppStorage?
    private var appearance: ChromiumAppearance?
    private var quitSave: ChromiumQuitSave?
    private var browserManager: BrowserManager?
    private let mcpManager = MCPManager()
    private var aiService: AIService?
    private var appMenu: ChromiumAppMenu?
    private var mouseButtons: ChromiumMouseButtons?
    private let registry = WindowRegistry()
    private var initialWindow: BrowserWindowState?
    private var ready: (@MainActor () -> Void)?
    private var opened: (@MainActor (Int32?) -> Void)?

    private init(bridge: BarcBridge, engineMain: @escaping BarcEngineMain, configuration: ChromiumStartupConfiguration) {
        self.bridge = bridge
        self.engineMain = engineMain
        self.configuration = configuration
        catalog = ChromiumWindowCatalog(bridge: bridge)
        profileDeletion = ChromiumProfileDeletion(bridge: bridge)
        downloads = ChromiumDownloads(bridge: bridge)
        liveFetch = ChromiumLiveFetch(bridge: bridge)
        pageHost = ChromiumNativePageHost(bridge: bridge)
        profileSearch = ChromiumProfileSearch(bridge: bridge)
        profilePages = ChromiumProfilePagePresenter(bridge: bridge)
        miniAPI = ChromiumMiniWindowAPI(bridge: bridge,
            canUse: { window, tab in
                guard let row = bridge.windowState(window) else { return false }
                return row.selected_client == window && row.active_tab == tab &&
                    row.flags & BARC_DISCOVERY_COMPACT_MINI.rawValue != 0 &&
                    row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0
            }, applicationPending: { window, tab in bridge.tab_application_pending(window, tab) == 1 })
    }

    // Entered only after stock main initialized allocator, loaded framework and checked its table.
    static func run(bridge: BarcBridge, engineMain: @escaping BarcEngineMain, arguments: [String]) -> Int32 {
        do {
            let config = try ChromiumStartupConfiguration(arguments: arguments)
            try config.prepare()
            let app = ChromiumApplication(bridge: bridge, engineMain: engineMain, configuration: config)
            let startup = ChromiumStartup(bridge: app, profile: config.profileID, prepareData: { proceed in
                guard let conversion = ChromiumDataConversion(configuration: config), conversion.shouldOffer() else {
                    proceed()
                    return
                }
                ChromiumDataConversionWindow.present(conversion, finished: proceed)
            }) { message in
                fputs(message + "\n", stderr)
            }
            startup.register()
            guard app.blockerRegistered else { return startup.runtimeReturned(EXIT_FAILURE) }
            let engineArguments = config.engineArguments(executable: arguments[0])
            let strings = engineArguments.map { strdup($0)! }
            defer { strings.forEach { free($0) } }
            var argv: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) } + [nil]
            return withExtendedLifetime((app, startup)) {
                let code = app.engineMain(Int32(engineArguments.count), &argv)
                // An OS logout ends the runtime without the close manager's accepted callback.
                app.quitSave?.save()
                app.acceptsWindows = false
                app.blocker?.stop()
                app.pageTweaks?.stop()
                DevMCPServer.shared.shutdown()
                app.mcpManager.stopAllSync()
                app.browserManager?.cancelNativeStartupWarming()
                app.catalog.stop()
                app.downloads.stop()
                app.profileDeletion.runtimeReturned()
                let status = startup.runtimeReturned(code)
                app.profilePages.cancelPending()
                return status
            }
        } catch {
            fputs("Native Chromium startup refused: \(error)\n", stderr)
            return EXIT_FAILURE
        }
    }

    private func observePeekSettings() {
        guard let storage else { return }
        pageHost.peekOnShiftClick = withObservationTracking {
            storage.settings.peekOnShiftClick
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePeekSettings() }
        }
    }

    private func observeDevMCPSettings() {
        guard acceptsWindows, let storage, let manager = browserManager else { return }
        devMCPSettingsGeneration &+= 1
        let expected = devMCPSettingsGeneration
        let enabled = withObservationTracking {
            DevMCPConfiguration.isEnabled(developerMode: storage.settings.developerModeEnabled,
                                         browserControl: storage.settings.browserControlServerEnabled)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.devMCPSettingsGeneration == expected else { return }
                self.observeDevMCPSettings()
            }
        }
        manager.tabs.setDeveloperMode(storage.settings.developerModeEnabled)
        DevMCPServer.shared.applyEnabledSetting(enabled)
    }

    private func applyMiniPages(_ snapshot: ChromiumDiscoverySnapshot) {
        guard acceptsWindows, let manager = browserManager, let admission else { return }
        for row in snapshot.windows where row.flags & BARC_DISCOVERY_COMPACT_MINI.rawValue != 0 &&
            row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 {
            guard let id = bridge.identity(row) else { continue }
            let profile: Profile
            if row.profile_kind == BARC_DISCOVERY_GUEST.rawValue {
                profile = manager.tabs.privateWindows.compactMap(\.ephemeralProfile).first(where: { $0.id == id }) ??
                    Profile.createEphemeral(id: id, engine: .chromium)
            } else {
                guard row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue,
                      manager.tabs.isProfileAvailable(id),
                      let regular = manager.tabs.profile(forStore: id) else { continue }
                profile = regular
            }
            // All real pages retain an observer, including a queued incoming
            // document superseded by a newer selected tab before admission.
            for tab in snapshot.tabs where tab.window == row.window {
                guard manager.externalMiniWindowManager.nativeController(tab: tab.tab) == nil else { continue }
                guard let navigation = try? ChromiumPageNavigation(profileID: id, window: row.window,
                          tab: tab.tab, bridge: bridge, privateSession: profile.isEphemeral),
                      let controller = ChromiumMiniWindowController(tabs: manager.tabs, profile: profile,
                        navigation: navigation, origin: registry.activeWindow, api: miniAPI,
                        promote: { [weak self, weak admission] page, space in
                            guard let self, let admission, self.acceptsWindows else { return false }
                            return admission.promoteDetached(page, spaceID: space, peerInGroup: self.bridge.window_new_peer_in_native_window,
                                newPeer: self.bridge.window_new_peer, close: self.bridge.window_close)
                        }, destinations: { [weak admission] page in admission?.miniDestinations(for: page) ?? [] },
                        openCopy: { [weak self, weak admission] page, space in
                            guard let self, let admission, self.acceptsWindows else { return false }
                            return admission.openDetachedCopy(page, in: space, open: self.bridge.profile_open_window, close: self.bridge.window_close,
                                canPresent: { [weak self] in self?.acceptsWindows == true })
                        }, canPromote: { [weak manager] page in
                            guard let manager, let profile = page.profile else { return false }
                            return page.isPrivate || (manager.tabs.isProfileAvailable(profile.id) &&
                                manager.tabs.profiles.first(where: { $0.id == profile.id })?.spaceIDs.isEmpty == false)
                        }, onEnd: { [weak manager] controller in
                            manager?.externalMiniWindowManager.releaseNative(controller)
                        }) else { continue }
                if !manager.externalMiniWindowManager.retainNative(controller) {
                    navigation.invalidate() // Observation only; no unclaimed native close.
                }
            }
            guard row.selected_client == row.window,
                  let selected = manager.externalMiniWindowManager.nativeController(tab: row.active_tab) as? ChromiumMiniWindowController else { continue }
            manager.externalMiniWindowManager.relinquishNativeHeader(window: row.window, except: row.active_tab)
            _ = selected.present(canPresent: { [weak self] in self?.acceptsWindows == true })
        }
    }

    private static func copyUUID<T>(_ id: UUID, into field: inout T) {
        let bytes = id.uuidString.lowercased().utf8CString
        withUnsafeMutableBytes(of: &field) { output in
            precondition(output.count == bytes.count)
            for (index, byte) in bytes.enumerated() { output[index] = UInt8(bitPattern: byte) }
        }
    }

    func registerReady(_ callback: @escaping @MainActor () -> Void) {
        ready = callback
        bridge.set_runtime_browser_target_callback({ kind, url, pendingWindow, pendingTab, output, pointer in
            MainActor.assumeIsolated {
                let refused = BARC_APPLICATION_TARGET_REFUSED.rawValue, found = BARC_APPLICATION_TARGET_FOUND.rawValue
                let ordinaryWindow = BARC_APPLICATION_TARGET_ORDINARY_WINDOW.rawValue
                guard let output, output.pointee.size >= MemoryLayout<BarcApplicationTarget>.size else { return refused }
                let size = output.pointee.size
                output.pointee = BarcApplicationTarget()
                output.pointee.size = size
                guard let pointer else { return refused }
                let app = Unmanaged<ChromiumApplication>.fromOpaque(pointer).takeUnretainedValue()
                guard app.acceptsWindows, let manager = app.browserManager, let admission = app.admission else { return refused }
                guard app.pageTweaks?.isReady == true else { return ordinaryWindow }
                if kind == BARC_APPLICATION_TARGET_PENDING_PAGE.rawValue {
                    guard let row = app.bridge.windowState(pendingWindow),
                          row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0,
                          app.bridge.tab_application_pending(pendingWindow, pendingTab) == 1,
                          !app.profilePages.ownsNativeWindow(pendingWindow) else { return refused }
                    let hint = app.bridge.requestedSpace(window: pendingWindow, tab: pendingTab)
                    if hint.supplied {
                        guard let space = hint.id, manager.tabs.space(space) != nil,
                              let profile = manager.tabs.tree.dataStoreID(for: space),
                              manager.tabs.isProfileAvailable(profile), app.bridge.identity(row) == profile else { return refused }
                    }
                    let pendingSession: PageSession?
                    if row.flags & BARC_DISCOVERY_COMPACT_MINI.rawValue != 0 {
                        guard let mini = manager.externalMiniWindowManager.nativeController(tab: pendingTab) as? ChromiumMiniWindowController else { return ordinaryWindow }
                        guard mini.nativeWindowID == pendingWindow, !mini.presentationRefused else { return refused }
                        guard let selected = manager.externalMiniWindowManager.nativeController(tab: row.active_tab) as? ChromiumMiniWindowController else { return ordinaryWindow }
                        guard selected.nativeWindowID == pendingWindow, !selected.presentationRefused else { return refused }
                        guard selected.isPresented else { return ordinaryWindow }
                        pendingSession = manager.externalMiniWindowManager.nativePage(tab: pendingTab)
                    } else {
                        pendingSession = admission.admittedApplicationSession(window: pendingWindow, tab: pendingTab)
                        guard pendingSession != nil else { return ordinaryWindow }
                    }
                    guard let blocker = app.blocker, let session = pendingSession else { return refused }
                    guard let profileID = app.bridge.identity(row) else { return refused }
                    let privateSession = row.profile_kind == BARC_DISCOVERY_GUEST.rawValue
                    let outcome = blocker.admitApplicationPage(window: pendingWindow, tab: pendingTab, session: session,
                        isPending: { [weak app] in
                            guard let app, app.acceptsWindows,
                                  app.bridge.tab_application_pending(pendingWindow, pendingTab) == 1,
                                  let current = app.bridge.windowState(pendingWindow),
                                  current.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 else { return false }
                            return app.bridge.identity(current) == profileID &&
                                (current.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == privateSession
                        }, canAdmit: { [weak app, weak session] in
                            guard let app, let session else { return false }
                            return app.pendingApplicationSession(window: pendingWindow, tab: pendingTab) === session
                        })
                    guard outcome == found else { return outcome }
                    output.pointee.window = pendingWindow
                    output.pointee.presentation = (row.flags & BARC_DISCOVERY_COMPACT_MINI.rawValue != 0 ?
                        BARC_APPLICATION_MINI : BARC_APPLICATION_CURRENT_SPACE).rawValue
                    return found
                }
                if kind == BARC_APPLICATION_TARGET_URL.rawValue, let url, let validatedURL = URL(string: String(cString: url)) {
                    let rule = manager.siteRoutingManager.resolve(url: validatedURL)
                    guard let target = admission.incomingTarget(ruleSpace: rule?.targetSpaceId,
                        mini: manager.nookSettings?.externalLinkDestination != .currentSpace,
                        regularProfile: manager.currentProfile?.id) else { return refused }
                    if target.window == -1 { return ordinaryWindow }
                    output.pointee.window = target.window
                    output.pointee.presentation = (target.mini ? BARC_APPLICATION_MINI : BARC_APPLICATION_CURRENT_SPACE).rawValue
                    if let id = target.profile { ChromiumApplication.copyUUID(id, into: &output.pointee.regular_profile_uuid) }
                    if let id = target.space { ChromiumApplication.copyUUID(id, into: &output.pointee.space_uuid) }
                    return found
                }
                guard let target = admission.browserTarget(kind: kind, regularProfile: manager.currentProfile?.id) else { return refused }
                if target.window == -1 { return ordinaryWindow }
                output.pointee.window = target.window
                if let id = target.regularProfile { ChromiumApplication.copyUUID(id, into: &output.pointee.regular_profile_uuid) }
                return found
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        bridge.set_runtime_close_callback({ accepted, pointer in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let app = Unmanaged<ChromiumApplication>.fromOpaque(pointer).takeUnretainedValue()
                if accepted == 1 {
                    app.acceptsWindows = false
                    app.blocker?.cancelApplicationPreparation()
                    DevMCPServer.shared.shutdown()
                    app.profilePages.cancelPending()
                    app.quitSave?.save()
                } else {
                    app.quitSave?.cancelled()
                    app.browserManager?.tabs.resumeAfterCancelledTermination()
                    app.acceptsWindows = true
                    if let manager = app.browserManager {
                        DevMCPServer.shared.configure(browserManager: manager, enabled: false)
                        app.observeDevMCPSettings()
                    }
                    app.admission?.resumeRestoredWindows(canPresent: { [weak app] in app?.acceptsWindows == true })
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        bridge.set_runtime_window_request_callback({ request, pointer in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let app = Unmanaged<ChromiumApplication>.fromOpaque(pointer).takeUnretainedValue()
                guard app.acceptsWindows, let manager = app.browserManager, let admission = app.admission else { return }
                switch request {
                case Int32(BARC_APPLICATION_NEW_WINDOW.rawValue):
                    admission.openNewWindow(open: app.bridge.profile_open_window, close: app.bridge.window_close,
                        canPresent: { [weak app] in app?.acceptsWindows == true })
                case Int32(BARC_APPLICATION_NEW_PRIVATE_WINDOW.rawValue):
                    manager.createIncognitoWindow()
                default:
                    break
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        bridge.set_runtime_ready_callback({ pointer in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let app = Unmanaged<ChromiumApplication>.fromOpaque(pointer).takeUnretainedValue()
                let callback = app.ready
                app.ready = nil
                callback?()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        // No stores/settings exist before ChromeMain. Unknown is deliberately
        // distinct from the saved disabled policy published at runtime-ready.
        blockerRegistered = bridge.blocker_set_policy(BARC_BLOCKER_UNRESOLVED.rawValue, 0, nil, 0) == 1
    }

    /// Read the existing admitted model owner, never construct or retarget one
    /// while an asynchronous first-request preparation is pending.
    private func pendingApplicationSession(window: Int32, tab: Int32) -> PageSession? {
        guard acceptsWindows, let manager = browserManager, let admission,
              let row = bridge.windowState(window),
              row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0,
              bridge.tab_application_pending(window, tab) == 1,
              !profilePages.ownsNativeWindow(window) else { return nil }
        let hint = bridge.requestedSpace(window: window, tab: tab)
        if hint.supplied {
            guard let space = hint.id, manager.tabs.space(space) != nil,
                  let profile = manager.tabs.tree.dataStoreID(for: space),
                  manager.tabs.isProfileAvailable(profile), bridge.identity(row) == profile else { return nil }
        }
        if row.flags & BARC_DISCOVERY_COMPACT_MINI.rawValue != 0 {
            guard let mini = manager.externalMiniWindowManager.nativeController(tab: tab) as? ChromiumMiniWindowController,
                  mini.nativeWindowID == window, !mini.presentationRefused,
                  let selected = manager.externalMiniWindowManager.nativeController(tab: row.active_tab) as? ChromiumMiniWindowController,
                  selected.nativeWindowID == window, selected.isPresented, !selected.presentationRefused else { return nil }
            return manager.externalMiniWindowManager.nativePage(tab: tab)
        }
        return admission.admittedApplicationSession(window: window, tab: tab)
    }

    func openProfile(_ id: UUID?, completion: @escaping @MainActor (Int32?) -> Void) {
        // This runs only after runtime-ready. The persisted model UUID owns
        // the native profile; the CLI hint must never relabel a model profile.
        do {
            let storage = try ChromiumAppStorage(configuration: configuration)
            let hadTabs = ChromiumOnboarding.hasTabs(in: storage.tabsDirectory)
            appearance = ChromiumAppearance(settings: storage.settings)
            let manager = BrowserManager(settings: storage.settings, windowRegistry: registry,
                persistence: storage.persistence, userDefaults: storage.defaults,
                downloadManager: storage.downloads, tabsDirectory: storage.tabsDirectory,
                cloudSyncEnabled: false, engine: .chromium)
            if configuration.isVerification { manager.importManager = ImportManager(sources: .fixtures(in: configuration.root)) }
            appearance?.onEffectiveChange = { [weak manager, registry] in
                guard let manager else { return }
                manager.tabs.sessions.forEach { $0.resetNativeTopBarSample() }
                registry.windows.values.forEach { manager.frontPage(in: $0)?.sampleNativeTopBarColor() }
            }
            manager.tabs.blocker.setEnabled(storage.settings.adBlockerEnabled)
            let blocker = ChromiumContentBlocker(bridge: bridge, manager: manager.tabs.blocker)
            guard blocker.synchronize(), pageHost.configureBlocker(blocker), downloads.start(manager: storage.downloads) else { completion(nil); return }
            self.blocker = blocker
            let shortcuts = KeyboardShortcutManager(userDefaults: storage.defaults, usesWebKitShortcuts: false)
            shortcuts.setBrowserManager(manager)
            manager.keyboardShortcutManager = shortcuts
            let appMenu = ChromiumAppMenu { [weak manager, weak shortcuts] command in
                guard let manager, let shortcuts else { return }
                switch command {
                case .settings: manager.openSettings(tab: .general)
                case .quit: manager.showQuitDialog()
                case .newTab: shortcuts.perform(.newTab)
                case .reopenClosedTab: shortcuts.reopenClosedTab()
                case .focusAddress: shortcuts.perform(.focusAddressBar)
                case .closeTab: shortcuts.closeTab(isRepeat: false)
                case .history: manager.showHistory()
                case .downloads: manager.showDownloads()
                case .toggleSidebar: manager.toggleSidebar()
                case .toggleAIAssistant: manager.toggleAISidebar()
                case .commandBar: shortcuts.perform(.openCommandPalette)
                case .addSplitView: shortcuts.perform(.addSplitView)
                case .nextSpace: shortcuts.perform(.nextSpace)
                case .previousSpace: shortcuts.perform(.previousSpace)
                case .manageExtensions: manager.manageExtensions()
                }
            }
            if let mainMenu = NSApp.mainMenu { appMenu.install(in: mainMenu) }
            self.appMenu = appMenu
            manager.tabs.nativePageHost = pageHost
            pageHost.pageIsHidden = { [weak tabs = manager.tabs] state in
                state.showsNativeEmptySpace || tabs?.showsPageElsewhere(in: state) == true
            }
            manager.tabs.nativeLiveFetch = { [liveFetch] profile, source in
                try await liveFetch.fetch(profileID: profile, source: source)
            }
            manager.tabs.onDeleteProfile = { [weak profileDeletion] intent, reconcileOnly, canDelete, completion in
                guard let profileDeletion else { completion(.pending); return }
                profileDeletion.request(intent, reconcileOnly: reconcileOnly, canDelete: canDelete, completion: completion)
            }
            manager.tabs.onProfileSearch = { [profileSearch] id, page, seed, selection, choices, completion in
                profileSearch.read(profile: id, page: page, seed: seed, selection: selection, includeChoices: choices, completion: completion)
            }
            manager.tabs.onOpenProfilePage = { [weak profilePages] profile, destination, canPresent, completion in
                guard let profilePages else { completion(.failure(.presentationUnavailable)); return }
                profilePages.open(profile, destination: destination, canPresent: canPresent, completion: completion)
            }
            manager.nativeOpenSettings = { [weak self] tab in self?.showSettings(tab) }
            manager.tabs.onSpaceDeletionNotice = { message in
                let alert = NSAlert()
                alert.messageText = message
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
            self.storage = storage
            browserManager = manager
            quitSave = ChromiumQuitSave(flushTabs: { [weak manager] in manager?.tabs.flushSync() },
                                        flushBoosts: { [settings = storage.settings] in settings.flushBoosts() },
                                        saveContext: { [weak manager] in try manager?.modelContext.save() })
            guard DevMCPServer.shared.setConfiguration(storage.devMCP) else { completion(nil); return }
            DevMCPServer.shared.configure(browserManager: manager, enabled: false)
            observeDevMCPSettings()
            observePeekSettings()
            let aiService = AIService(configService: storage.aiConfig)
            aiService.browserManager = manager
            aiService.mcpManager = mcpManager
            aiService.browserToolExecutor = BrowserToolExecutor(browserManager: manager)
            self.aiService = aiService
            manager.aiService = aiService
            manager.aiConfigService = storage.aiConfig
            manager.mcpManager = mcpManager
            manager.tabs.pageTranslation = { [aiConfig = storage.aiConfig] in aiConfig.pageTranslation }
            mcpManager.startEnabledServers(configs: storage.aiConfig.mcpServers)
            registry.onActiveWindowChange = { [weak manager] in manager?.setActiveWindowState($0) }
            LiveFavorites.shared.start(tabs: manager.tabs, windows: registry)
            mouseButtons = ChromiumMouseButtons(manager: manager, registry: registry)
            registry.onWindowClose = { [weak self, weak manager, weak registry = self.registry] id in
                guard let manager, let state = registry?.windows[id] else { return }
                let tabs = manager.tabs
                manager.cancelNativeStartupWarming()
                manager.downloadManager.dismissPreview(in: state)
                manager.peekManager.windowClosed(id)
                if state.isIncognito || (tabs.device.windows.contains(where: { $0.id == id }) &&
                    self?.admission?.shouldDetachModelWindow(state) == true) {
                    tabs.detach(window: state)
                }
            }
            let admission = ChromiumCreatedPageAdmission(bridge: bridge, host: pageHost,
                tabs: manager.tabs, registry: registry,
                isUtility: { [weak profilePages] in profilePages?.ownsNativeWindow($0) == true },
                makeShell: { [unowned self, manager, storage, aiService] state in
                    self.makeShell(for: state, manager: manager, storage: storage, aiService: aiService)
                }, detachedPage: { [weak manager] in
                    manager?.externalMiniWindowManager.nativePage(tab: $0) ?? manager?.peekManager.nativePage(tab: $0)
                }, didAdoptDetached: { [weak manager] tab in
                    manager?.externalMiniWindowManager.completeNativeAdoption(tab: tab)
                    manager?.peekManager.completeNativeAdoption(tab: tab)
                }, coveredByPeek: { [weak manager] source, window in
                    manager?.peekManager.coversNativeSource(source, in: window) == true
                },
                didPresent: { [weak manager] in manager?.nativeStartupWindowPresented($0) })
            self.admission = admission
            manager.peekManager.nativeAdmission = admission
            manager.tabs.onProfileWindowsNeedReload = { [weak self, weak admission] ids in
                guard let self, let admission, self.acceptsWindows, self.didPresentInitialWindow else { return }
                admission.reloadProfileWindows(ids, open: self.bridge.profile_open_window, close: self.bridge.window_close,
                    canPresent: { [weak self] in self?.acceptsWindows == true })
            }
            manager.nativeCreateWindow = { [weak self, weak admission] in
                guard let self, let admission, self.acceptsWindows else { return }
                _ = admission.openNewWindow(open: self.bridge.profile_open_window, close: self.bridge.window_close,
                    canPresent: { [weak self] in self?.acceptsWindows == true })
            }
            manager.nativeCreateIncognitoWindow = { [weak self, weak admission] in
                guard let self, let admission, self.acceptsWindows else { return }
                let origin = self.registry.activeWindow, originID = origin?.id
                _ = admission.openPrivateWindow(open: self.bridge.private_session_open_window, close: self.bridge.window_close,
                    canPresent: { [weak self, weak origin] in
                        guard let self, self.acceptsWindows else { return false }
                        guard let originID else { return true } // App menu with no product window.
                        guard let origin else { return false }
                        return self.registry.windows[originID] === origin
                    })
            }
            catalog.onSnapshot = { [weak self, weak admission] snapshot in
                self?.applyMiniPages(snapshot)
                admission?.apply(snapshot)
                if let self, let manager = self.browserManager {
                    manager.peekManager.reconcileNativeOwners()
                    for window in self.registry.windows.values {
                        manager.peekManager.refreshNativePresentation(in: window)
                    }
                }
            }
            let pageTweaks = ChromiumPageTweaks(bridge: bridge, settings: storage.settings)
            self.pageTweaks = pageTweaks
            Task { @MainActor [weak self, weak manager] in
                guard await pageTweaks.prepare(while: { [weak self, weak manager] in
                    guard let self, let manager else { return false }
                    return self.acceptsWindows && self.browserManager === manager && self.pageTweaks === pageTweaks
                }), let self, let manager else { completion(nil); return }
                manager.tabs.resumePendingProfileDeletion { [weak self] _ in
                    guard let self, self.acceptsWindows else { completion(nil); return }
                    guard ChromiumOnboarding.isNeeded(didFinish: &storage.settings.didFinishOnboarding, hadTabs: hadTabs) else {
                        self.openInitialModelWindow(completion: completion)
                        return
                    }
                    ChromiumOnboarding.present(manager: manager, settings: storage.settings) { [weak self] in
                        guard let self, self.acceptsWindows else { completion(nil); return }
                        self.openInitialModelWindow(completion: completion)
                    }
                }
            }
        } catch {
            fputs("Chromium app stores refused: \(error)\n", stderr)
            completion(nil)
        }
    }

    private func openInitialModelWindow(completion: @escaping @MainActor (Int32?) -> Void) {
        guard let manager = browserManager, let admission else { completion(nil); return }
        guard let modelWindow = admission.prepareInitialWindow() else {
            guard let intent = manager.tabs.device.pendingProfileDeletion,
                  manager.tabs.isProfileAvailable(intent.survivor),
                  let survivor = manager.tabs.profiles.first(where: { $0.id == intent.survivor }) else {
                completion(nil); return
            }
            profilePages.openRecovery(survivor, canPresent: { [weak self, weak manager] in
                self?.acceptsWindows == true && manager?.tabs.device.pendingProfileDeletion == intent &&
                manager?.tabs.isProfileAvailable(intent.survivor) == true
            }, openSettings: { [weak self] in
                guard let self, self.acceptsWindows else { return }
                self.showSettings(.profiles)
            }) { result in
                completion(try? result.get())
            }
            return
        }
        initialWindow = modelWindow
        guard let space = modelWindow.spaceID, let profile = manager.tabs.profile(forSpace: space) else {
            registry.unregister(modelWindow.id); completion(nil); return
        }
        opened = completion
        profile.id.uuidString.withCString { uuid in
        bridge.profile_open_window(uuid, BARC_PROFILE_BLANK, { status, window, pointer in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let app = Unmanaged<ChromiumApplication>.fromOpaque(pointer).takeUnretainedValue()
                let completion = app.opened
                app.opened = nil
                completion?(status == BARC_PROFILE_OK && window > 0 ? window : nil)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func completeStartup(_ window: Int32) {
        if window <= 0 {
            acceptsWindows = false
            admission?.cancelPendingProductPresentation()
            profilePages.cancelPending()
        }
        bridge.runtime_complete_startup(window)
        guard window > 0, acceptsWindows,
              let row = bridge.windowState(window), row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 else { return }
        didPresentInitialWindow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.acceptsWindows else { return }
            self.browserManager?.offerDefaultBrowserIfNeeded()
        }
        admission?.restoreSavedWindows(open: bridge.profile_open_window, close: bridge.window_close, canPresent: { [weak self] in self?.acceptsWindows == true })
    }

    private func makeShell(for state: BrowserWindowState, manager: BrowserManager,
                           storage: ChromiumAppStorage, aiService: AIService) -> NSView {
        let palette = CommandPalette()
        let organizer = TabOrganizerManager()
        let hover = HoverSidebarManager()
        state.sidebarWidth = manager.sidebarWidth
        state.sidebarContentWidth = max(manager.sidebarWidth - 16, 0)
        state.isSidebarVisible = true
        state.commandPalette = palette
        hover.browserManager = manager
        hover.windowRegistry = registry
        hover.nookSettings = storage.settings
        return NSHostingView(rootView: ChromiumSidebarShell(browserManager: manager,
            storage: storage, window: state, registry: registry,
            commandPalette: palette, organizer: organizer, hover: hover, aiService: aiService,
            setPageHidden: { [weak pageHost, weak state] hidden in
                guard let state else { return }
                pageHost?.setPageHidden(hidden, in: state)
            }))
    }

    func attachShell(to window: Int32, completion: @escaping @MainActor (Int32?) -> Void) {
        guard acceptsWindows, storage != nil, let manager = browserManager,
              let admission else { completion(nil); return }
        if initialWindow == nil {
            guard let intent = manager.tabs.device.pendingProfileDeletion,
                  manager.tabs.isProfileAvailable(intent.survivor),
                  let row = bridge.windowState(window),
                  row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0, row.selected_client == window,
                  row.profileID == intent.survivor,
                  profilePages.ownsRecoveryWindow(window, profile: intent.survivor, activeTab: row.active_tab),
                  catalog.start() else { completion(nil); return }
            guard acceptsWindows, manager.tabs.device.pendingProfileDeletion == intent,
                  let checked = bridge.windowState(window), checked.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0,
                  checked.physical_group == row.physical_group, checked.selected_client == window,
                  checked.profileID == intent.survivor,
                  profilePages.ownsRecoveryWindow(window, profile: intent.survivor, activeTab: checked.active_tab) else {
                completion(nil); return
            }
            completion(window)
            return
        }
        guard let modelWindow = initialWindow, let space = modelWindow.spaceID,
              let profile = manager.tabs.profile(forSpace: space) else { completion(nil); return }
        var finished = false, catalogReady = false, hasResult = false
        var result: Int32?
        func resolved(_ native: Int32?) {
            guard !finished else { return }
            result = native
            hasResult = true
            guard catalogReady else { return }
            finished = true
            guard self.acceptsWindows, self.initialWindow === modelWindow else { completion(nil); return }
            if native != nil { self.initialWindow = nil }
            completion(native)
        }
        guard admission.admitRestoredWindow(modelWindow, native: window, profile: profile.id,
                show: false, canPresent: { [weak self] in self?.acceptsWindows == true },
                completion: { outcome in
                    switch outcome {
                    case .admitted: resolved(window)
                    case .refused: resolved(nil)
                    case .superseded:
                        if !admission.whenProductPresented(modelWindow, completion: resolved) { resolved(nil) }
                    }
                }) else { finished = true; completion(nil); return }
        // Delivery progresses the newer selection, but startup is completed
        // only after its exact product/header/page/layout is actually admitted.
        let started = catalog.start()
        catalogReady = true
        if !started { resolved(nil) }
        else if hasResult { resolved(result) }
    }

    private func showSettings(_ tab: SettingsTabs) {
        guard tab.availableInChromium, let manager = browserManager, let storage,
              let shortcuts = manager.keyboardShortcutManager else { return }
        SettingsNavigation.shared.currentSettingsTab = tab
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let view = SettingsWindow()
            .environmentObject(manager)
            .environmentObject(manager.gradientColorManager)
            .environment(manager.tabs)
            .environment(storage.settings)
            .environment(\.nookSettings, storage.settings)
            .environment(\.tabActions, manager)
            .environment(\.contentBlocker, manager.contentBlockerManager)
            .environment(\.siteRouting, manager.siteRoutingManager)
            .environment(shortcuts)
            .environment(storage.aiConfig)
            .environment(mcpManager)
            .defaultAppStorage(storage.defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        settingsWindow = window
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsWindow = nil
                if let observer = self.settingsCloseObserver { NotificationCenter.default.removeObserver(observer) }
                self.settingsCloseObserver = nil
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@_cdecl("barc_native_main")
public func barcNativeMain(
    _ bridge: UnsafePointer<BarcBridge>?, _ engineMain: BarcEngineMain?, _ argc: Int32,
    _ argv: UnsafePointer<UnsafePointer<CChar>?>?
) -> Int32 {
    guard Thread.isMainThread, let bridge, let engineMain, argc > 0, let argv else { return EXIT_FAILURE }
    var arguments: [String] = []
    for index in 0..<Int(argc) {
        guard let value = argv[index] else { return EXIT_FAILURE }
        arguments.append(String(cString: value))
    }
    return ChromiumApplication.run(bridge: bridge.pointee, engineMain: engineMain, arguments: arguments)
}
