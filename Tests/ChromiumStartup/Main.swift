import Foundation

@MainActor
private final class MockBridge: ChromiumStartupBridge {
    var callback: (@MainActor () -> Void)?
    var completion: (@MainActor (Int32?) -> Void)?
    var registrations = 0
    var profiles: [UUID?] = []
    var attachments: [Int32] = []
    var attachResult = true
    var deferAttachment = false
    var attachmentCompletion: (@MainActor (Int32?) -> Void)?
    var completed: [Int32] = []
    func completeStartup(_ window: Int32) { completed.append(window) }
    func registerReady(_ callback: @escaping @MainActor () -> Void) {
        registrations += 1
        self.callback = callback
    }
    func openProfile(_ id: UUID?, completion: @escaping @MainActor (Int32?) -> Void) {
        profiles.append(id)
        self.completion = completion
    }
    func attachShell(to window: Int32, completion: @escaping @MainActor (Int32?) -> Void) {
        attachments.append(window)
        if deferAttachment { attachmentCompletion = completion }
        else { completion(attachResult ? window : nil) }
    }
}

@main
struct StartupTests {
    @MainActor static func main() throws {
        let id = UUID()
        let config = try ChromiumStartupConfiguration(arguments: [
            "Nook", "--barc-app-data-dir=/private/tmp/nook-startup-test",
            "--barc-app-profile=\(id.uuidString)"])
        precondition(config.profileID == id)
        precondition(config.isVerification && config.engineArguments(executable: "Nook").contains("--use-mock-keychain"))
        let normalRoot = URL(fileURLWithPath: "/private/tmp/NookNormalConfig-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: normalRoot) }
        let normal = try ChromiumStartupConfiguration(arguments: ["Nook"], applicationSupportDirectory: normalRoot)
        precondition(!normal.isVerification && normal.profileID == nil)
        precondition(normal.root == normalRoot.appendingPathComponent("NookChromium", isDirectory: true))
        precondition(config.aiConfigURL.path == "/private/tmp/nook-startup-test/App/ai_config.json")
        precondition(config.aiKeychainService == "ee.qdo.nook.chromium-verification.aiProvider.26edca9982aeea417df94b6de0431c4c446fa35683d1e743c65a8f42fdedf377")
        let otherRoot = try ChromiumStartupConfiguration(arguments: [
            "Nook", "--barc-app-data-dir=/private/tmp/nook-startup-test-other", "--barc-app-profile=\(id.uuidString)"])
        precondition(otherRoot.aiKeychainService != config.aiKeychainService)
        precondition(normal.aiConfigURL == normal.root.appendingPathComponent("App/ai_config.json"))
        precondition(normal.aiKeychainService == "ee.qdo.nook.chromium.aiProvider")
        precondition(!normal.engineArguments(executable: "Nook").contains("--use-mock-keychain"))
        precondition(normal.engineArguments(executable: "Nook").contains("--disable-sync"))
        for launch in [["Nook"], ["Nook", "--bark-window=host"], ["Nook", "--", "https://fixture.invalid/cast"]] {
            let arguments = try ChromiumStartupConfiguration(arguments: launch, applicationSupportDirectory: normalRoot)
                .engineArguments(executable: "Nook")
            let pages = arguments.firstIndex(of: "--") ?? arguments.endIndex
            precondition(arguments.filter { $0.hasPrefix("--disable-features") } == ["--disable-features=MediaRouter"]
                         && arguments.firstIndex(of: "--disable-features=MediaRouter")! < pages,
                         "Cast has no entry point: the engine starts with Media Router off, once, before any page: \(arguments)")
        }
        func urls(_ value: Any) -> [URL] {
            Mirror(reflecting: value).children.flatMap { child -> [URL] in
                if let url = child.value as? URL { return [url] }
                return urls(child.value)
            }
        }
        precondition(urls(normal).allSatisfy { $0.standardizedFileURL.path.hasPrefix(normal.root.standardizedFileURL.path) },
                     "a plain launch names nothing outside its own store: \(urls(normal).map(\.path))")
        for verification in [false, true] {
            let arguments = verification
                ? ["Nook", "--barc-app-data-dir=/private/tmp/nook-startup-test", "--barc-app-profile=\(id.uuidString)"]
                : ["Nook"]
            let plain = try ChromiumStartupConfiguration(arguments: arguments, applicationSupportDirectory: normalRoot)
            let switched = try ChromiumStartupConfiguration(arguments: arguments + ["--barc-conversion-source=/private/tmp/nook-startup-source"],
                                                            applicationSupportDirectory: normalRoot)
            precondition(urls(switched).map(\.path) == urls(plain).map(\.path)
                         && switched.engineArguments(executable: "Nook") == plain.engineArguments(executable: "Nook"),
                         "--barc-conversion-source is an unknown switch, dropped like any other")
        }
        let withURLs = try ChromiumStartupConfiguration(arguments: ["Nook",
            "--no-sandbox", "https://fixture.invalid/cli", "file:///private/tmp/fixture.html"],
            applicationSupportDirectory: normalRoot)
        let engineURLs = withURLs.engineArguments(executable: "Nook")
        precondition(!engineURLs.contains("--no-sandbox"))
        precondition(Array(engineURLs.suffix(3)) == ["--", "https://fixture.invalid/cli", "file:///private/tmp/fixture.html"])
        let literal = try ChromiumStartupConfiguration(arguments: ["Nook", "--", "--barc-app-profile=literal"],
            applicationSupportDirectory: normalRoot)
        precondition(!literal.isVerification && literal.launchArguments == ["--barc-app-profile=literal"])
        precondition(config.launchArguments.isEmpty)
        for launch in [["Nook"], ["Nook", "--barc-app-data-dir=/private/tmp/nook-startup-test", "--barc-app-profile=\(id.uuidString)"]] {
            let byDefault = try ChromiumStartupConfiguration(arguments: launch, applicationSupportDirectory: normalRoot)
            precondition(byDefault.hostsWindows && byDefault.engineArguments(executable: "Nook").filter { $0.hasPrefix("--bark-window") } == ["--bark-window=host"],
                         "a launch with no window switch gets the Bark window: \(launch)")
        }
        let host = try ChromiumStartupConfiguration(arguments: ["Nook", "--bark-window=host"],
            applicationSupportDirectory: normalRoot)
        precondition(host.engineArguments(executable: "Nook").filter { $0.hasPrefix("--bark-window") } == ["--bark-window=host"],
                     "host mode reaches the engine")
        precondition(!host.engineArguments(executable: "Nook").contains("--"), "host mode is an engine switch, not a page to open")
        let legacy = try ChromiumStartupConfiguration(arguments: ["Nook", "--bark-window=legacy"],
            applicationSupportDirectory: normalRoot)
        precondition(!legacy.hostsWindows && !legacy.engineArguments(executable: "Nook").contains { $0.hasPrefix("--bark-window") },
                     "--bark-window=legacy keeps Chromium's own window")
        for bad in ["--bark-window=other", "--bark-window", "--bark-window="] {
            do {
                _ = try ChromiumStartupConfiguration(arguments: ["Nook", bad], applicationSupportDirectory: normalRoot)
                preconditionFailure("\(bad) is refused")
            } catch ChromiumStartupConfiguration.StartupError.invalidConfiguration {}
        }
        let literalLegacy = try ChromiumStartupConfiguration(arguments: ["Nook", "--", "--bark-window=legacy"],
            applicationSupportDirectory: normalRoot)
        let literalArguments = literalLegacy.engineArguments(executable: "Nook")
        precondition(literalLegacy.hostsWindows && literalArguments.suffix(2) == ["--", "--bark-window=legacy"]
                     && literalArguments.filter { $0.hasPrefix("--bark-window") } == ["--bark-window=host", "--bark-window=legacy"],
                     "a literal argument stays a page to open and does not pick the window: \(literalArguments)")
        try normal.prepare()
        precondition(FileManager.default.fileExists(atPath: normal.root.appendingPathComponent("Engine").path))
        let redirected = normalRoot.appendingPathComponent("RedirectedSupport")
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: redirected.appendingPathComponent("NookChromium"),
                                                  withDestinationURL: normal.root)
        do {
            _ = try ChromiumStartupConfiguration(arguments: ["Nook"], applicationSupportDirectory: redirected)
            preconditionFailure("Accepted redirected normal native store")
        } catch { }
        for partial in [
            ["--barc-app-profile=\(id)"], ["--barc-app-data-dir=/private/tmp/incomplete"],
            ["--barc-app-data-dir"], ["--barc-app-profile"],
            ["--barc-app-data-dir="], ["--barc-app-profile="],
            ["--barc-app-data-dir", "/private/tmp/owned", "--barc-app-profile=\(id)"],
            ["--barc-app-data-dir=/private/tmp/owned", "--barc-app-profile", "\(id)"],
            ["--barc-app-data-dir=/private/tmp/owned", "--barc-app-data-dir=/private/tmp/owned", "--barc-app-profile=\(id)"],
            ["--barc-app-data-dir=/private/tmp/owned", "--barc-app-profile=\(id)", "--barc-app-profile=\(id)"]
        ] {
            do { _ = try ChromiumStartupConfiguration(arguments: partial, applicationSupportDirectory: normalRoot); preconditionFailure("Accepted malformed verification mode") } catch { }
        }

        precondition(!config.engineArguments(executable: "Nook").contains { $0.hasPrefix("--profile-directory=") })
        precondition(config.engineArguments(executable: "Nook").contains("--disable-sync"))
        precondition(config.engineArguments(executable: "Nook").contains("--no-startup-window"))
        for bad in ["/Users/example/Library", "/private/tmp/../var", "/private/tmp"] {
            do {
                _ = try ChromiumStartupConfiguration(arguments: [
                    "--barc-app-data-dir=\(bad)", "--barc-app-profile=\(id)"])
                preconditionFailure("Accepted non-synthetic directory")
            } catch { }
        }
        let sandbox = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let outside = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: sandbox.appendingPathComponent("Engine"), withDestinationURL: outside)
        do {
            _ = try ChromiumStartupConfiguration(arguments: [
                "--barc-app-data-dir=\(sandbox.path)", "--barc-app-profile=\(id)"])
            preconditionFailure("Accepted escaped Engine child")
        } catch { }
        try FileManager.default.removeItem(at: sandbox.appendingPathComponent("Engine"))
        let safeConfig = try ChromiumStartupConfiguration(arguments: [
            "--barc-app-data-dir=\(sandbox.path)", "--barc-app-profile=\(id)"])
        try FileManager.default.createSymbolicLink(at: sandbox.appendingPathComponent("App"), withDestinationURL: outside)
        do {
            try safeConfig.prepare()
            preconditionFailure("Prepared escaped App child")
        } catch { }
        let bridge = MockBridge()
        var failures: [String] = []
        let startup = ChromiumStartup(bridge: bridge, profile: id) { failures.append($0) }
        startup.register()
        startup.register()
        precondition(bridge.registrations == 1 && bridge.profiles.isEmpty)
        bridge.callback?()
        bridge.callback?()
        precondition(bridge.profiles == [id] && bridge.attachments.isEmpty)
        bridge.completion?(43)
        bridge.completion?(43)
        precondition(bridge.attachments == [43] && startup.window == 43 && failures.isEmpty && bridge.completed == [43])
        let failedBridge = MockBridge()
        let failed = ChromiumStartup(bridge: failedBridge, profile: id) { failures.append($0) }
        failed.register()
        failedBridge.callback?()
        failedBridge.completion?(nil)
        failedBridge.completion?(46)
        precondition(failedBridge.attachments.isEmpty && failures.count == 1 && failedBridge.completed == [0])
        let attachBridge = MockBridge()
        attachBridge.attachResult = false
        let attachFailure = ChromiumStartup(bridge: attachBridge, profile: id) { failures.append($0) }
        attachFailure.register()
        attachBridge.callback?()
        attachBridge.completion?(44)
        precondition(attachFailure.window == nil && failures.count == 2 && attachBridge.completed == [0])
        let earlyBridge = MockBridge()
        let early = ChromiumStartup(bridge: earlyBridge, profile: id) { _ in preconditionFailure() }
        early.register()
        precondition(early.runtimeReturned(0) == 1)
        earlyBridge.callback?()
        precondition(earlyBridge.profiles.isEmpty && earlyBridge.completed == [0])
        let pendingBridge = MockBridge()
        let pending = ChromiumStartup(bridge: pendingBridge, profile: id) { _ in preconditionFailure() }
        pending.register()
        pendingBridge.callback?()
        precondition(pending.runtimeReturned(0) == 1)
        pendingBridge.completion?(45)
        precondition(pendingBridge.attachments.isEmpty && pendingBridge.completed == [0])
        let delayedBridge = MockBridge()
        delayedBridge.deferAttachment = true
        let delayed = ChromiumStartup(bridge: delayedBridge, profile: id) { _ in preconditionFailure() }
        delayed.register()
        delayedBridge.callback?()
        delayedBridge.completion?(47)
        precondition(delayed.window == nil && delayedBridge.completed.isEmpty)
        delayedBridge.attachmentCompletion?(47)
        delayedBridge.attachmentCompletion?(nil)
        precondition(delayed.window == 47 && delayedBridge.completed == [47])
        let supersededBridge = MockBridge()
        supersededBridge.deferAttachment = true
        let superseded = ChromiumStartup(bridge: supersededBridge, profile: id) { _ in preconditionFailure() }
        superseded.register(); supersededBridge.callback?(); supersededBridge.completion?(49)
        precondition(supersededBridge.completed.isEmpty)
        supersededBridge.attachmentCompletion?(50)
        precondition(superseded.window == 50 && supersededBridge.completed == [50])
        let cancelledBridge = MockBridge()
        cancelledBridge.deferAttachment = true
        let cancelled = ChromiumStartup(bridge: cancelledBridge, profile: id) { _ in preconditionFailure() }
        cancelled.register()
        cancelledBridge.callback?()
        cancelledBridge.completion?(48)
        precondition(cancelled.runtimeReturned(0) == 1)
        cancelledBridge.attachmentCompletion?(48)
        precondition(cancelled.window == nil && cancelledBridge.completed == [0])
        precondition(startup.runtimeReturned(0) == 0)
        precondition(bridge.completed == [43, 0])
        print("Chromium startup: configuration isolation, callback ordering, duplicate readiness, profile failure and attachment failure PASS")
    }
}
