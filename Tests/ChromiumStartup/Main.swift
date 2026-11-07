import Foundation

@MainActor
private final class MockBridge: ChromiumStartupBridge {
    var callback: (@MainActor () -> Void)?
    var completion: (@MainActor (Int32?) -> Void)?
    var registrations = 0
    var profiles: [UUID?] = []
    var attachments: [Int32] = []
    var attachResult = true
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
    func attachShell(to window: Int32) -> Bool {
        attachments.append(window)
        return attachResult
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
        precondition(normal.minimumBridgeVersion == 3 && config.minimumBridgeVersion == 2)
        precondition(normal.root == normalRoot.appendingPathComponent("NookChromium", isDirectory: true))
        precondition(!normal.engineArguments(executable: "Nook").contains("--use-mock-keychain"))
        precondition(normal.engineArguments(executable: "Nook").contains("--disable-sync"))
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
        precondition(startup.runtimeReturned(0) == 0)
        precondition(bridge.completed == [43, 0])
        print("Chromium startup: configuration isolation, callback ordering, duplicate readiness, profile failure and attachment failure PASS")
    }
}
