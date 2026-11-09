// Licensed under GPL-3.0. See LICENSE.

import Foundation
import NookAdblockFFI
import Testing
@testable import NookBlocker

@MainActor
struct NativeRulesExportTests {
    private let sources = [
        FilterListManager.Source(rules: "||ads.test^$script,image\n||tracker.test^$third-party", isTrusted: false),
        FilterListManager.Source(rules: "@@||ads.test/allowed.js$script", isTrusted: true),
    ]

    @Test func exportedRulesPreserveRequestTypesAndCrossListExceptions() async throws {
        let engine = BlockerEngine(cacheFile: nil)
        #expect(engine.networkRules == nil)
        #expect(await engine.build(sources: sources, exportingNetworkRules: true))
        let snapshot = try #require(engine.networkRules)
        let restored = try restore(snapshot.bytes)
        defer { nook_adblock_engine_free(restored) }
        let cases = [
            ("https://ads.test/ad.js", "https://site.test/", "script", true),
            ("https://ads.test/ad.png", "https://site.test/", "image", true),
            ("https://ads.test/allowed.js", "https://site.test/", "script", false),
            ("https://ads.test/style.css", "https://site.test/", "stylesheet", false),
            ("https://tracker.test/beacon", "https://site.test/", "xmlhttprequest", true),
            ("https://tracker.test/beacon", "https://tracker.test/", "xmlhttprequest", false),
        ]
        for (url, source, type, expected) in cases {
            #expect(engine.matches(url: url, sourceURL: source, type: type) == expected)
            #expect(matches(restored, url: url, source: source, type: type) == expected)
        }
        #expect(engine.networkRules?.generation == snapshot.generation)
        #expect(engine.networkRules?.bytes == snapshot.bytes)
    }

    @Test func cacheHitExportsRawBytesAndCorruptionRebuilds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("engine.dat")
        let first = BlockerEngine(cacheFile: cache)
        #expect(await first.build(sources: sources, exportingNetworkRules: true))
        let snapshot = try #require(first.networkRules)
        let saved = try Data(contentsOf: cache)
        #expect(saved.count == snapshot.bytes.count + 32)
        #expect(Data(saved.dropFirst(32)) == snapshot.bytes)

        let cached = BlockerEngine(cacheFile: cache)
        #expect(await cached.build(sources: sources, exportingNetworkRules: true))
        #expect(cached.networkRules?.bytes == snapshot.bytes)

        var corrupted = Data(saved.prefix(32))
        corrupted.append(contentsOf: [0, 1, 2])
        try corrupted.write(to: cache, options: .atomic)
        let rebuilt = BlockerEngine(cacheFile: cache)
        #expect(await rebuilt.build(sources: sources, exportingNetworkRules: true))
        let restored = try restore(try #require(rebuilt.networkRules).bytes)
        defer { nook_adblock_engine_free(restored) }
        #expect(matches(restored, url: "https://ads.test/ad.js", source: "https://site.test/", type: "script"))
        #expect(!matches(restored, url: "https://ads.test/allowed.js", source: "https://site.test/", type: "script"))
    }

    @Test func emptyNativePolicyIsAUsableReplacementAndWebKitRetainsNoExport() async throws {
        let engine = BlockerEngine(cacheFile: nil)
        #expect(await engine.build(sources: sources, exportingNetworkRules: true))
        let old = try #require(engine.networkRules)
        #expect(await engine.build(sources: [], exportingNetworkRules: true))
        let empty = try #require(engine.networkRules)
        #expect(empty.generation > old.generation)
        let restored = try restore(empty.bytes)
        defer { nook_adblock_engine_free(restored) }
        #expect(!matches(restored, url: "https://ads.test/ad.js", source: "https://site.test/", type: "script"))
        // A previously exported immutable value remains valid for an outstanding request.
        let previous = try restore(old.bytes)
        defer { nook_adblock_engine_free(previous) }
        #expect(matches(previous, url: "https://ads.test/ad.js", source: "https://site.test/", type: "script"))

        #expect(await engine.build(sources: sources))
        #expect(engine.networkRules == nil)
        #expect(engine.matches(url: "https://ads.test/ad.js", sourceURL: "https://site.test/", type: "script"))
        engine.clear()
        #expect(!engine.isLoaded && engine.networkRules == nil)
    }

    @Test func cancelledReplacementKeepsAcceptedRules() async throws {
        let engine = BlockerEngine(cacheFile: nil)
        #expect(await engine.build(sources: sources, exportingNetworkRules: true))
        let accepted = try #require(engine.networkRules)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.build(sources: [], exportingNetworkRules: true)
        }
        #expect(await cancelled.value == false)
        #expect(engine.networkRules?.generation == accepted.generation)
        #expect(engine.networkRules?.bytes == accepted.bytes)
        #expect(engine.matches(url: "https://ads.test/ad.js", sourceURL: "https://site.test/", type: "script"))
    }

    @Test func ownerRefusalAfterParsingPreservesAcceptedMatcherAndExport() async throws {
        let engine = BlockerEngine(cacheFile: nil)
        #expect(await engine.build(sources: sources, exportingNetworkRules: true))
        let accepted = try #require(engine.networkRules)
        let replacement = [FilterListManager.Source(rules: "||replacement.test^$script", isTrusted: false)]
        #expect(await engine.build(sources: replacement, exportingNetworkRules: true, accepting: { false }) == false)
        #expect(engine.networkRules?.generation == accepted.generation)
        #expect(engine.networkRules?.bytes == accepted.bytes)
        #expect(engine.matches(url: "https://ads.test/ad.js", sourceURL: "https://site.test/", type: "script"))
        #expect(!engine.matches(url: "https://replacement.test/ad.js", sourceURL: "https://site.test/", type: "script"))
        // Final owner validation may synchronously revoke the entire engine.
        #expect(await engine.build(sources: replacement, exportingNetworkRules: true, accepting: {
            engine.clear()
            return true
        }) == false)
        #expect(!engine.isLoaded && engine.networkRules == nil)
    }

    @Test func serializedRulesAndCachePreserveSourceTrust() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("engine.dat")
        for trusted in [true, false] {
            let engine = BlockerEngine(cacheFile: cache)
            #expect(await engine.build(sources: [
                FilterListManager.Source(rules: "example.test##+js(trusted-mark, hello)", isTrusted: trusted),
            ], exportingNetworkRules: true))
            let restored = try restore(try #require(engine.networkRules).bytes)
            defer { nook_adblock_engine_free(restored) }
            // Resource bodies are deliberately separate from the compiled rule snapshot.
            #expect(injectedScript(restored).isEmpty)
            let body = Data("function nookMark(a) { window.__m = a; }".utf8).base64EncodedString()
            let json = """
            [{"name":"trusted-mark.js","aliases":[],"kind":{"mime":"application/javascript"},"content":"\(body)","dependencies":[],"permission":1}]
            """
            #expect(json.withCString { nook_adblock_engine_use_resources(restored, $0, json.utf8.count) })
            #expect(injectedScript(restored).contains("nookMark") == trusted)
        }
    }

    private func restore(_ data: Data) throws -> UnsafeMutableRawPointer {
        try #require(data.withUnsafeBytes {
            nook_adblock_engine_deserialize($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        })
    }

    private func matches(_ engine: UnsafeMutableRawPointer, url: String, source: String, type: String) -> Bool {
        url.withCString { url in
            source.withCString { source in
                type.withCString { nook_adblock_engine_matches(engine, url, source, $0) }
            }
        }
    }

    private func injectedScript(_ engine: UnsafeMutableRawPointer) -> String {
        guard let text = "https://example.test/".withCString({ nook_adblock_cosmetic_for_url(engine, $0) }) else { return "" }
        defer { nook_adblock_string_free(text) }
        let data = Data(String(cString: text).utf8)
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return value?["injected_script"] as? String ?? ""
    }
}
