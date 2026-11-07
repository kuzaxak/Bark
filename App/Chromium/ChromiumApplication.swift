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
    private let profileID: UUID
    private var page: PageSession?
    private let attach: Attach
    private let chromeMain: Main
    private let complete: Complete
    private var ready: (@MainActor () -> Void)?
    private var opened: (@MainActor (Int32?) -> Void)?
    private var shell: NSView?

    private init(framework handle: UnsafeMutableRawPointer, profileID: UUID) throws {
        self.profileID = profileID
        navigationAPI = try ChromiumNavigationAPI(library: handle)
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw LoaderError.missingSymbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
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
            let app = try ChromiumApplication(framework: framework, profileID: config.profileID)
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
        opened = completion
        id.uuidString.withCString { uuid in
            open(uuid, 0, { status, window, pointer in
                MainActor.assumeIsolated {
                    guard let pointer else { return }
                    let app = Unmanaged<ChromiumApplication>.fromOpaque(pointer).takeUnretainedValue()
                    let completion = app.opened
                    app.opened = nil
                    completion?(status == 0 && window > 0 ? window : nil)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func completeStartup(_ window: Int32) {
        complete(window)
    }

    func attachShell(to window: Int32) -> Bool {
        let tab = tabAt(window, 0)
        guard tab > 0 else { return false }
        do {
            let navigation = try ChromiumPageNavigation(
                profileID: profileID, window: window, tab: tab, api: navigationAPI)
            // No HTTP favicon/cache access at construction, and no WebKit
            // surface. Bind native observation before accepting UI navigation.
            let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                      title: "", isPrivate: false, controller: nil)
            session.installNavigation(navigation)
            let view = NSHostingView(rootView: ChromiumNavigationShell(page: session))
            guard attach(window, Unmanaged.passUnretained(view).toOpaque()) == 1 else {
                navigation.invalidate()
                return false
            }
            page = session
            shell = view
            return true
        } catch {
            fputs("Chromium page binding failed: \(error)\n", stderr)
            return false
        }
    }

    enum LoaderError: Error { case missingSymbol(String) }
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
