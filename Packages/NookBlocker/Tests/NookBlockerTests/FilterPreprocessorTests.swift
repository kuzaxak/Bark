// Licensed under GPL-3.0. See LICENSE.

import Foundation
import Testing
@testable import NookBlocker

@MainActor
struct FilterPreprocessorTests {
    @Test func desktopChromiumDoesNotAdvertiseMobileExtensionOrUnsupportedCapabilities() {
        #expect(FilterPreprocessor.evaluate("env_chromium && ext_ublock"))
        #expect(!FilterPreprocessor.evaluate("env_safari || env_firefox || env_mobile || env_mv3"))
        #expect(!FilterPreprocessor.evaluate("ext_ubol || cap_html_filtering || cap_ipaddress"))
        #expect(FilterPreprocessor.evaluate("!env_mobile && !ext_ubol"))
    }

    @Test func shippedChromiumRulesRetainOriginalTrustAndReachMatcher() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FilterListManager(directory: root)
        let sources = manager.loadFilterSources(enabledFilenames: [])
        let chromiumRule = "||doubleclick.net^$script,important,domain=auto-motor-und-sport.de"
        let shipped = try #require(sources.first { $0.rules.contains(chromiumRule) })
        #expect(shipped.isTrusted)
        let unprocessed = try #require(Bundle.module.url(
            forResource: "ublock-filters.min", withExtension: "txt", subdirectory: "Resources"))
        let raw = try String(contentsOf: unprocessed, encoding: .utf8)
        let safari = FilterPreprocessor.apply(raw, environment: ["env_safari", "ext_ublock"])
        #expect(!safari.contains(chromiumRule))
        #expect(FilterPreprocessor.apply(raw) == shipped.rules)
        #expect(sources.contains { !$0.isTrusted })
        let engine = BlockerEngine(cacheFile: nil)
        #expect(await engine.build(sources: [shipped]))
        #expect(engine.matches(url: "https://doubleclick.net/fixture.js",
                               sourceURL: "https://auto-motor-und-sport.de/", type: "script"))
        #expect(!engine.matches(url: "https://doubleclick.net/fixture.js",
                                sourceURL: "https://auto-motor-und-sport.de/", type: "image"))
    }
}
