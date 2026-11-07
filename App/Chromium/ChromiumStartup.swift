import Foundation

/// Verification startup never reads the installed application's stores.
struct ChromiumStartupConfiguration {
    let root: URL
    let profileID: UUID

    init(arguments: [String]) throws {
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        guard let path = value("--barc-app-data-dir"), path.hasPrefix("/private/tmp/"),
              let id = value("--barc-app-profile").flatMap(UUID.init(uuidString:)) else {
            throw StartupError.invalidConfiguration
        }
        let canonical = Self.canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
        guard canonical.path.hasPrefix("/private/tmp/"), canonical.path != "/private/tmp" else {
            throw StartupError.invalidConfiguration
        }
        root = canonical
        profileID = id
        try validateChildDirectories()
    }

    private static func canonicalURL(_ url: URL) -> URL {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        // Foundation can abbreviate an existing /private/tmp URL to /tmp.
        // Use one spelling for fresh and persisted verification directories.
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func validateChildDirectories() throws {
        for name in ["App", "Engine"] {
            let child = Self.canonicalURL(root.appendingPathComponent(name))
            guard child.path.hasPrefix(root.path + "/") else {
                throw StartupError.invalidConfiguration
            }
        }
    }

    func prepare() throws {
        try validateChildDirectories()
        for name in ["App", "Engine"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    func engineArguments(executable: String) -> [String] {
        [executable, "--no-startup-window", "--no-first-run", "--no-default-browser-check",
         "--disable-sync", "--use-mock-keychain", "--barc-shared-native-window",
         "--barc-native-shell",
         "--user-data-dir=" + root.appendingPathComponent("Engine").path]
    }

    enum StartupError: Error { case invalidConfiguration }
}

/// The concrete bridge owns Chromium; this object only sequences its callbacks.
@MainActor
protocol ChromiumStartupBridge: AnyObject {
    func registerReady(_ callback: @escaping @MainActor () -> Void)
    func openProfile(_ id: UUID, completion: @escaping @MainActor (Int32?) -> Void)
    func attachShell(to window: Int32) -> Bool
    func completeStartup(_ window: Int32)
}

@MainActor
final class ChromiumStartup {
    private unowned let bridge: any ChromiumStartupBridge
    private let profile: UUID
    private let failure: (String) -> Void
    private var started = false
    private var ready = false
    private var returned = false
    private var completed = false
    private(set) var window: Int32?
    private(set) var failed = false

    init(bridge: any ChromiumStartupBridge, profile: UUID, failure: @escaping (String) -> Void) {
        self.bridge = bridge
        self.profile = profile
        self.failure = failure
    }

    func runtimeReturned(_ code: Int32) -> Int32 {
        returned = true
        bridge.completeStartup(0)
        return (failed || window == nil) && code == 0 ? 1 : code
    }

    private func fail(_ message: String) {
        failed = true
        bridge.completeStartup(0)
        failure(message)
    }

    func register() {
        guard !started else { return }
        started = true
        bridge.registerReady { [weak self] in
            guard let self, !self.ready, !self.returned else { return }
            self.ready = true
            self.bridge.openProfile(self.profile) { [weak self] window in
                guard let self, !self.returned, !self.failed, !self.completed else { return }
                self.completed = true
                guard let window, window > 0 else { self.fail("Chromium profile startup failed"); return }
                guard self.bridge.attachShell(to: window) else { self.fail("Chromium native hosting failed"); return }
                self.window = window
                self.bridge.completeStartup(window)
            }
        }
    }
}
