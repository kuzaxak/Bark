import AppKit
import Darwin
import NookSettings
import NookWeb
import SwiftUI

private typealias ReadyCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias ProfileCallback = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void

@MainActor
final class ChromiumApplication: ChromiumStartupBridge {
    private typealias Register = @convention(c) (ReadyCallback?, UnsafeMutableRawPointer?) -> Void
    private typealias Open = @convention(c) (UnsafePointer<CChar>?, Int32, ProfileCallback?, UnsafeMutableRawPointer?) -> Void
    private typealias TabAt = @convention(c) (Int32, Int) -> Int32
    private typealias Attach = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32
    private typealias Main = @convention(c) (Int32, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    private typealias Complete = @convention(c) (Int32) -> Void
    private let registerCallback: Register
    private let open: Open
    private let tabAt: TabAt
    private let navigationAPI: ChromiumNavigationAPI
    private let configuration: ChromiumStartupConfiguration
    private let pageHost: ChromiumNativePageHost
    private let discoveryAPI: ChromiumDiscoveryAPI
    private let catalog: ChromiumWindowCatalog
    private var admission: ChromiumCreatedPageAdmission?
    private let profilePages: ChromiumProfilePagePresenter
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    private var storage: ChromiumAppStorage?
    private var browserManager: BrowserManager?
    private let registry = WindowRegistry()
    private var initialWindow: BrowserWindowState?
    private let attach: Attach
    private let chromeMain: Main
    private let complete: Complete
    private var ready: (@MainActor () -> Void)?
    private var opened: (@MainActor (Int32?) -> Void)?

    private init(framework handle: UnsafeMutableRawPointer, configuration: ChromiumStartupConfiguration) throws {
        self.configuration = configuration
        navigationAPI = try ChromiumNavigationAPI(library: handle)
        discoveryAPI = try ChromiumDiscoveryAPI(library: handle)
        catalog = ChromiumWindowCatalog(api: discoveryAPI)
        pageHost = try ChromiumNativePageHost(api: ChromiumPageHostAPI(library: handle),
            navigationAPI: navigationAPI, discoveryAPI: discoveryAPI)
        profilePages = try ChromiumProfilePagePresenter(api: ChromiumProfilePageAPI(library: handle), navigationAPI: navigationAPI)
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw LoaderError.missingSymbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        let version = try symbol("barc_bridge_version", (@convention(c) () -> UInt32).self)
        guard version() >= 2 else { throw LoaderError.ownerEndedProtocolRequired }
        registerCallback = try symbol("barc_set_runtime_ready_callback", Register.self)
        open = try symbol("barc_profile_open_window", Open.self)
        tabAt = try symbol("barc_window_tab_at", TabAt.self)
        attach = try symbol("barc_window_attach_native_shell", Attach.self)
        chromeMain = try symbol("ChromeMain", Main.self)
        complete = try symbol("barc_runtime_complete_startup", Complete.self)
    }

    // Entered only after stock main initialized allocator and loaded framework.
    static func run(framework: UnsafeMutableRawPointer, arguments: [String]) -> Int32 {
        do {
            let config = try ChromiumStartupConfiguration(arguments: arguments)
            try config.prepare()
            let app = try ChromiumApplication(framework: framework, configuration: config)
            let startup = ChromiumStartup(bridge: app, profile: config.profileID) { message in
                fputs(message + "\n", stderr)
            }
            startup.register()
            let engineArguments = config.engineArguments(executable: arguments[0])
            let strings = engineArguments.map { strdup($0)! }
            defer { strings.forEach { free($0) } }
            var argv: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) } + [nil]
            return withExtendedLifetime((app, startup)) {
                let code = app.chromeMain(Int32(engineArguments.count), &argv)
                app.catalog.stop()
                return startup.runtimeReturned(code)
            }
        } catch {
            fputs("Native Chromium startup refused: \(error)\n", stderr)
            return EXIT_FAILURE
        }
    }

    func registerReady(_ callback: @escaping @MainActor () -> Void) {
        ready = callback
        registerCallback({ pointer in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                let app = Unmanaged<ChromiumApplication>.fromOpaque(pointer).takeUnretainedValue()
                let callback = app.ready
                app.ready = nil
                callback?()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func openProfile(_ id: UUID, completion: @escaping @MainActor (Int32?) -> Void) {
        // This runs only after runtime-ready. The persisted model UUID owns
        // the native profile; the CLI hint must never relabel a model profile.
        do {
            let storage = try ChromiumAppStorage(configuration: configuration)
            let manager = BrowserManager(settings: storage.settings, windowRegistry: registry,
                persistence: storage.persistence, userDefaults: storage.defaults,
                downloadManager: storage.downloads, tabsDirectory: storage.tabsDirectory,
                cloudSyncEnabled: false, engine: .chromium)
            manager.tabs.nativePageHost = pageHost
            manager.tabs.onOpenProfilePage = { [weak profilePages] profile, destination, canPresent, completion in
                guard let profilePages else { completion(.failure(.presentationUnavailable)); return }
                profilePages.open(profile, destination: destination, canPresent: canPresent, completion: completion)
            }
            manager.nativeOpenSettings = { [weak self] tab in self?.showSettings(tab) }
            let modelWindow = BrowserWindowState()
            initialWindow = modelWindow
            modelWindow.sidebarWidth = manager.sidebarWidth
            modelWindow.sidebarContentWidth = max(manager.sidebarWidth - 16, 0)
            modelWindow.isSidebarVisible = true
            registry.register(modelWindow)
            manager.tabs.attach(window: modelWindow)
            guard modelWindow.split == nil, let space = modelWindow.spaceID,
                  let profile = manager.tabs.profile(forSpace: space) else {
                completion(nil); return
            }
            self.storage = storage
            browserManager = manager
            registry.onActiveWindowChange = { [weak manager] in manager?.setActiveWindowState($0) }
            registry.onWindowClose = { [weak manager, weak registry = self.registry] id in
                guard let tabs = manager?.tabs, let state = registry?.windows[id],
                      tabs.device.windows.contains(where: { $0.id == id }) else { return }
                tabs.detach(window: state)
            }
            let admission = ChromiumCreatedPageAdmission(api: discoveryAPI, host: pageHost,
                tabs: manager.tabs, registry: registry,
                isUtility: { [weak profilePages] in profilePages?.ownsNativeWindow($0) == true },
                makeShell: { [unowned self, manager, storage] state in
                    self.makeShell(for: state, manager: manager, storage: storage)
                })
            self.admission = admission
            catalog.onSnapshot = { [weak admission] in admission?.apply($0) }
            opened = completion
            profile.id.uuidString.withCString { uuid in
            open(uuid, 5, { status, window, pointer in
                MainActor.assumeIsolated {
                    guard let pointer else { return }
                    let app = Unmanaged<ChromiumApplication>.fromOpaque(pointer).takeUnretainedValue()
                    let completion = app.opened
                    app.opened = nil
                    completion?(status == 0 && window > 0 ? window : nil)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
            }
        } catch {
            fputs("Chromium app stores refused: \(error)\n", stderr)
            completion(nil)
        }
    }

    func completeStartup(_ window: Int32) {
        complete(window)
    }

    private func makeShell(for state: BrowserWindowState, manager: BrowserManager,
                           storage: ChromiumAppStorage) -> NSView {
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
            commandPalette: palette, organizer: organizer, hover: hover))
    }

    func attachShell(to window: Int32) -> Bool {
        guard let storage, let manager = browserManager, let modelWindow = initialWindow,
              let admission else { return false }
        let blank = tabAt(window, 0)
        guard blank > 0 else { return false }
        let view = makeShell(for: modelWindow, manager: manager, storage: storage)
        guard attach(window, Unmanaged.passUnretained(view).toOpaque()) == 1,
              pageHost.registerWindow(modelWindow, nativeOwner: window, shell: view,
                                      initialBlankTab: blank),
              admission.registerInitial(ChromiumProductWindow(state: modelWindow, shell: view),
                                        nativeWindow: window) else { return false }
        initialWindow = nil
        modelWindow.windowHandle = view.window
        if let selected = modelWindow.selectedItemID {
            manager.tabs.select(selected, in: modelWindow)
        } else {
            _ = manager.tabs.open(url: URL(string: "about:blank")!, in: modelWindow, placement: .newTab)
        }
        // Existing-client blank binding is synchronous. Refuse startup if model
        // admission did not produce a real engine page; never create WebKit.
        guard manager.tabs.selectedSession(in: modelWindow)?.isUnloaded == false else { return false }
        return catalog.start()
    }

    private func showSettings(_ tab: SettingsTabs) {
        guard tab == .spaces || tab == .profiles, let manager = browserManager, let storage else { return }
        SettingsNavigation.shared.currentSettingsTab = tab
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let view = SettingsWindow()
            .environmentObject(manager)
            .environmentObject(manager.gradientColorManager)
            .environment(manager.tabs)
            .environment(storage.settings)
            .environment(\.nookSettings, storage.settings)
            .environment(\.tabActions, manager)
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

    enum LoaderError: Error { case missingSymbol(String), ownerEndedProtocolRequired }
}

#if NOOK_CHROMIUM_LIBRARY
@MainActor
@_cdecl("barc_native_main")
public func barcNativeMain(
    _ framework: UnsafeMutableRawPointer?, _ argc: Int32,
    _ argv: UnsafePointer<UnsafePointer<CChar>?>?
) -> Int32 {
    guard Thread.isMainThread, let framework, argc > 0, let argv else { return EXIT_FAILURE }
    var arguments: [String] = []
    for index in 0..<Int(argc) {
        guard let value = argv[index] else { return EXIT_FAILURE }
        arguments.append(String(cString: value))
    }
    return ChromiumApplication.run(framework: framework, arguments: arguments)
}
#endif
