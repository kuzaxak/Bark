import AppKit
import Darwin
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
    private var storage: ChromiumAppStorage?
    private var browserManager: BrowserManager?
    private let registry = WindowRegistry()
    private let modelWindow = BrowserWindowState()
    private let commandPalette = CommandPalette()
    private let organizer = TabOrganizerManager()
    private let hover = HoverSidebarManager()
    private let attach: Attach
    private let chromeMain: Main
    private let complete: Complete
    private var ready: (@MainActor () -> Void)?
    private var opened: (@MainActor (Int32?) -> Void)?
    private var shell: NSView?

    private init(framework handle: UnsafeMutableRawPointer, configuration: ChromiumStartupConfiguration) throws {
        self.configuration = configuration
        navigationAPI = try ChromiumNavigationAPI(library: handle)
        pageHost = try ChromiumNativePageHost(api: ChromiumPageHostAPI(library: handle), navigationAPI: navigationAPI)
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
            modelWindow.sidebarWidth = manager.sidebarWidth
            modelWindow.sidebarContentWidth = max(manager.sidebarWidth - 16, 0)
            modelWindow.isSidebarVisible = true
            modelWindow.commandPalette = commandPalette
            registry.register(modelWindow)
            manager.tabs.attach(window: modelWindow)
            guard modelWindow.split == nil, let space = modelWindow.spaceID,
                  let profile = manager.tabs.profile(forSpace: space) else {
                completion(nil); return
            }
            self.storage = storage
            browserManager = manager
            hover.browserManager = manager
            hover.windowRegistry = registry
            hover.nookSettings = storage.settings
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

    func attachShell(to window: Int32) -> Bool {
        guard let storage, let manager = browserManager else { return false }
        let blank = tabAt(window, 0)
        guard blank > 0 else { return false }
        let view = NSHostingView(rootView: ChromiumSidebarShell(browserManager: manager,
            storage: storage, window: modelWindow, registry: registry,
            commandPalette: commandPalette, organizer: organizer, hover: hover))
        guard attach(window, Unmanaged.passUnretained(view).toOpaque()) == 1,
              pageHost.registerWindow(modelWindow, nativeOwner: window, shell: view,
                                      initialBlankTab: blank) else { return false }
        shell = view
        modelWindow.windowHandle = view.window
        registry.onActiveWindowChange = { [weak manager] in manager?.setActiveWindowState($0) }
        registry.setActive(modelWindow)
        if let selected = modelWindow.selectedItemID {
            manager.tabs.select(selected, in: modelWindow)
        } else {
            _ = manager.tabs.open(url: URL(string: "about:blank")!, in: modelWindow, placement: .newTab)
        }
        // Existing-client blank binding is synchronous. Refuse startup if model
        // admission did not produce a real engine page; never create WebKit.
        return manager.tabs.selectedSession(in: modelWindow)?.isUnloaded == false
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
