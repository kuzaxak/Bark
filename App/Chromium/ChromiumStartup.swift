import CryptoKit
import Darwin
import Foundation

/// Native stores are separate from legacy Nook. Explicit verification inputs
/// stay synthetic; normal startup never infers an import or migration.
struct ChromiumStartupConfiguration {
    let root: URL
    let profileID: UUID?
    let isVerification: Bool
    let launchArguments: [String]

    var rootDigest: String {
        SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var aiConfigURL: URL {
        root.appendingPathComponent("App", isDirectory: true).appendingPathComponent("ai_config.json")
    }
    var preferencesDomain: String {
        isVerification ? "ee.qdo.nook.chromium-verification." + rootDigest : "ee.qdo.nook.chromium"
    }
    var aiKeychainService: String {
        isVerification ? "ee.qdo.nook.chromium-verification.aiProvider." + rootDigest : "ee.qdo.nook.chromium.aiProvider"
    }

    init(arguments: [String], applicationSupportDirectory: URL? = nil,
         rehearsal: (root: String, profile: UUID)? = nil) throws {
        func value(_ name: String) throws -> String? {
            let supplied = arguments.prefix { $0 != "--" }.filter { $0 == name || $0.hasPrefix(name + "=") }
            guard supplied.count <= 1 else { throw StartupError.invalidConfiguration }
            guard let argument = supplied.first else { return nil }
            guard argument.hasPrefix(name + "="), argument.count > name.count + 1 else {
                throw StartupError.invalidConfiguration
            }
            return String(argument.dropFirst(name.count + 1))
        }
        // Forward only positional input to Chromium's own startup parser. App
        // overrides remain consumed here; unknown switches never become engine
        // security/configuration overrides. `--` permits a literal dash prefix.
        var positional: [String] = [], literal = false
        for argument in arguments.dropFirst() {
            if argument == "--", !literal { literal = true; continue }
            if literal || !argument.hasPrefix("-") { positional.append(argument) }
        }
        launchArguments = positional
        if let backend = try value("--bark-window"), backend != "host" {
            throw StartupError.invalidConfiguration
        }
        let suppliedPath = try value("--barc-app-data-dir"), suppliedHint = try value("--barc-app-profile")
        if let rehearsal, suppliedPath != nil || suppliedHint != nil {
            guard suppliedPath == rehearsal.root,
                  suppliedHint.flatMap(UUID.init(uuidString:)) == rehearsal.profile else {
                throw StartupError.invalidConfiguration
            }
        }
        let path = rehearsal?.root ?? suppliedPath, hint = rehearsal?.profile.uuidString ?? suppliedHint
        if path != nil || hint != nil {
            guard let path, path.hasPrefix("/private/tmp/"), let id = hint.flatMap(UUID.init(uuidString:)) else {
                throw StartupError.invalidConfiguration
            }
            let canonical = Self.canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
            guard canonical.path.hasPrefix("/private/tmp/"), canonical.path != "/private/tmp" else {
                throw StartupError.invalidConfiguration
            }
            root = canonical; profileID = id; isVerification = true
        } else {
            guard let support = applicationSupportDirectory ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw StartupError.invalidConfiguration
            }
            let expected = Self.canonicalURL(support).appendingPathComponent("NookChromium", isDirectory: true)
            let canonical = Self.canonicalURL(expected)
            // A preexisting root symlink must not quietly redirect normal
            // startup into an installed browser's store.
            guard canonical.path == expected.standardizedFileURL.path else { throw StartupError.invalidConfiguration }
            root = canonical; profileID = nil; isVerification = false
        }
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
        guard Self.canonicalURL(root).path == root.path else {
            throw StartupError.invalidConfiguration
        }
        // Check both slots before creating either. lstat rejects a link even
        // when it targets its sibling or a path that does not exist yet.
        for directory in [root, root.appendingPathComponent("App"), root.appendingPathComponent("Engine")] {
            var metadata = stat()
            if lstat(directory.path, &metadata) == 0 {
                guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                    throw StartupError.invalidConfiguration
                }
            } else if errno != ENOENT {
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
        var result = [executable, "--no-startup-window", "--no-first-run", "--no-default-browser-check",
                      "--bark-window=host", "--disable-sync", "--disable-features=MediaRouter", "--barc-shared-native-window", "--barc-native-shell",
                      "--user-data-dir=" + root.appendingPathComponent("Engine").path]
        if isVerification { result.append("--use-mock-keychain") }
        if !launchArguments.isEmpty { result.append("--"); result += launchArguments }
        return result
    }

    enum StartupError: Error { case invalidConfiguration, providerRefused }
}

/// Set before the model can write starter tabs. A pending setup survives an
/// interrupted launch without being mistaken for a completed onboarding.
struct ChromiumOnboardingSetup {
    let appDirectory: URL
    private var marker: URL { appDirectory.appendingPathComponent("onboarding-state") }
    private static let pending = Data("pending\n".utf8)
    private static let completed = Data("completed\n".utf8)

    func requiresOnboarding(explicitlyFinished: Bool, hasSavedSetup: @autoclosure () -> Bool) throws -> Bool {
        if explicitlyFinished {
            try finish()
            return false
        }
        if FileManager.default.fileExists(atPath: marker.path) {
            let state = try Data(contentsOf: marker)
            if state == Self.completed { return false }
            guard state == Self.pending else { throw ChromiumStartupConfiguration.StartupError.invalidConfiguration }
            return true
        }
        if hasSavedSetup() {
            try finish()
            return false
        }
        try Self.pending.write(to: marker, options: .atomic)
        return true
    }

    func finish() throws {
        if (try? Data(contentsOf: marker)) != Self.completed {
            try Self.completed.write(to: marker, options: .atomic)
        }
    }
}

/// The concrete bridge owns Chromium; this object only sequences its callbacks.
@MainActor
protocol ChromiumStartupBridge: AnyObject {
    func registerReady(_ callback: @escaping @MainActor () -> Void)
    func openProfile(_ id: UUID?, completion: @escaping @MainActor (Int32?) -> Void)
    func attachShell(to window: Int32, completion: @escaping @MainActor (Int32?) -> Void)
    func completeStartup(_ window: Int32)
}

@MainActor
final class ChromiumStartup {
    private unowned let bridge: any ChromiumStartupBridge
    private let profile: UUID?
    private let prepareData: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let failure: (String) -> Void
    private var started = false
    private var ready = false
    private var returned = false
    private var completed = false
    private(set) var window: Int32?
    private(set) var failed = false

    init(bridge: any ChromiumStartupBridge, profile: UUID?,
         prepareData: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { $0() },
         failure: @escaping (String) -> Void) {
        self.bridge = bridge
        self.profile = profile
        self.prepareData = prepareData
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
            self.prepareData { [weak self] in
                guard let self, !self.returned, !self.failed else { return }
                self.openDestination()
            }
        }
    }

    private func openDestination() {
        bridge.openProfile(profile) { [weak self] window in
            guard let self, !self.returned, !self.failed, !self.completed else { return }
            self.completed = true
            guard let window, window > 0 else { self.fail("Chromium profile startup failed"); return }
            self.bridge.attachShell(to: window) { [weak self] admitted in
                guard let self, !self.returned, !self.failed, self.window == nil else { return }
                guard let admitted, admitted > 0 else { self.fail("Chromium native hosting failed"); return }
                self.window = admitted
                self.bridge.completeStartup(admitted)
            }
        }
    }
}
