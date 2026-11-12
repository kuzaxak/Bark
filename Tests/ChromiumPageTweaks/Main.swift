import BarcChromium
import Foundation
import NookSettings
import NookTweaks
private struct NoTokens: KagiTokenStore { func load() -> String? { nil }; func save(_ token: String?) {} }
@MainActor private enum Native {
    static var calls: [Data?] = []
    static var live: Data?
    static var refusing = false
    static var onPublish: (() -> Void)?
    static let bridge: BarcBridge = {
        var bridge = trappingBridge
        bridge.page_tweaks_publish = { bytes, count in
            MainActor.assumeIsolated {
                let data = bytes.map { Data(bytes: $0, count: count) }
                Native.calls.append(data)
                if Native.refusing { return 0 }
                Native.live = data
                let action = Native.onPublish; Native.onPublish = nil; action?()
                return 1
            }
        }
        return bridge
    }()
    static func reset() { calls = []; live = nil; refusing = false; onPublish = nil }
}
@main @MainActor private enum Checks {
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("native-tweaks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var suites: [String] = []
        defer { suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) } }
        func settings(_ boosts: [Boost], _ name: String) throws -> NookSettingsService {
            let suite = "native-tweaks-test-" + UUID().uuidString; suites.append(suite)
            let file = dir.appendingPathComponent(name + ".json")
            try JSONEncoder().encode(boosts).write(to: file)
            return NookSettingsService(kagiTokenStore: NoTokens(), userDefaults: UserDefaults(suiteName: suite)!, boostStore: BoostStore(fileURL: file))
        }
        var boost = Boost(host: "example.test", script: "await Promise.resolve();return 1;", scriptEnabled: true)
        let saved = try settings([boost], "valid")
        let source = ChromiumPageTweaks(bridge: Native.bridge, settings: saved)
        precondition(Native.calls.isEmpty)
        let admitted = await source.prepare(while: { true })
        precondition(admitted && source.lastError == nil && saved.boostsLoaded)
        let first = try JSONSerialization.jsonObject(with: Native.live!) as! [String: Any]
        precondition((first["scripts"] as! [[String: Any]]).first!["source"] as! String == boost.script)
        let count = Native.calls.count
        precondition(source.synchronize() && Native.calls.count == count)
        saved.adBlockerEnabled.toggle()
        precondition(source.synchronize() && Native.calls.count == count)
        // A failed update revokes old permission, but optional data cannot stop
        // ordinary startup once native confirms the empty publication.
        saved.boosts[0].script = String(repeating: "x", count: Boost.maxScriptBytes + 1)
        precondition(source.synchronize() && Native.live == nil && source.lastError != nil)
        source.stop();Native.reset()
        let invalid = try settings([Boost(host: "example.test", script: String(repeating: "x", count: Boost.maxScriptBytes + 1), scriptEnabled: true)], "invalid")
        let bad = ChromiumPageTweaks(bridge: Native.bridge, settings: invalid)
        let badAdmitted = await bad.prepare(while: { true })
        precondition(badAdmitted && bad.lastError != nil && Native.calls.count == 1 && Native.live == nil)
        bad.stop();Native.reset()
        let hugeScript = "//" + String(repeating: "\\", count: Boost.maxScriptBytes - 2)
        let oversized = try settings((0..<Boost.maxCount).map { _ in Boost(host: "example.test", script: hugeScript, scriptEnabled: true) }, "oversized")
        let huge = ChromiumPageTweaks(bridge: Native.bridge, settings: oversized)
        let hugeAdmitted = await huge.prepare(while: { true })
        precondition(hugeAdmitted && huge.lastError != nil && Native.calls.count == 1 && Native.live == nil)
        precondition(oversized.boosts.count == Boost.maxCount)
        huge.stop();Native.reset()
        let cancelled = ChromiumPageTweaks(bridge: Native.bridge, settings: try settings([boost], "cancelled"))
        let stale = await cancelled.prepare(while: { false })
        precondition(!stale && Native.calls.isEmpty)
        cancelled.stop();Native.reset()
        saved.boosts = [boost]
        let refused = ChromiumPageTweaks(bridge: Native.bridge, settings: saved)
        Native.refusing = true
        let unsafe = await refused.prepare(while: { true })
        precondition(!unsafe && Native.calls.count == 2 && Native.live == nil)
        refused.stop();Native.reset()
        saved.boosts = [boost]
        let reentrant = ChromiumPageTweaks(bridge: Native.bridge, settings: saved)
        Native.onPublish = { boost.script = "return 2;"; saved.boosts = [boost]; _ = reentrant.synchronize() }
        precondition(!reentrant.synchronize())
        let latest = try JSONSerialization.jsonObject(with: Native.live!) as! [String: Any]
        precondition((latest["scripts"] as! [[String: Any]]).first!["source"] as! String == "return 2;")
        let beforeStop = Native.calls.count
        reentrant.stop();saved.boosts = []
        for _ in 0..<3 { await Task.yield() }
        precondition(Native.calls.count == beforeStop)
        print("Native page tweaks startup/publisher PASS: valid first load, invalid/oversized fail-closed admission, unchanged policy, cancellation, refusal, reentrancy, stop")
    }
}
