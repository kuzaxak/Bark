// Licensed under GPL-3.0. See LICENSE.
//
//  BlockerEngine.swift
//  Nook
//
//  One adblock-rust Engine (MPL-2.0), serving both per-URL cosmetic lookup and
//  request matching. Replaces AdGuard's FilterEngine/WebExtension, which is
//  GPL-3.0, and the second engine RequestStatsEngine used to build from the
//  same rules.
//
//  The engine pointer is Send but not Sync: it holds a RefCell regex cache.
//  It is therefore confined to the main actor, and only `build` steps off to
//  construct a fresh one, which is the same arrangement the AdGuard-era
//  WebExtension used. Lookups stay synchronous on purpose, because the
//  main-frame config script has to be installed before navigation commits.
//
//  Foundation only; nothing here is AppKit-specific.
//

import CryptoKit
import Foundation
import NookAdblockFFI
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "AdvancedRules")

@MainActor
public final class BlockerEngine {

    /// Raw adblock-rust serialization for the native network matcher. This is
    /// not WK rule-list JSON and has no app-cache prefix or scriptlet bodies.
    /// The consumer must use the same pinned Rust implementation.
    public struct NetworkRules: Sendable {
        public let generation: UInt64
        public let bytes: Data
    }

    private var engine: UnsafeMutableRawPointer?
    private let cacheFile: URL?
    private var buildGeneration: UInt64 = 0

    /// Immutable serialized rules from the last accepted build.
    public private(set) var networkRules: NetworkRules?

    public var isLoaded: Bool { engine != nil }

    init(cacheFile: URL?) {
        self.cacheFile = cacheFile
    }

    deinit {
        if let engine { nook_adblock_engine_free(engine) }
    }

    /// Build or rebuild from the filter lists, replacing any previous engine.
    /// Per list rather than one blob: `ParseOptions.permissions` is applied at
    /// parse time and is what gates `trusted-*` scriptlets.
    /// Construction and serialization run off the main actor. A failed,
    /// cancelled or superseded build leaves the last accepted policy intact.
    @discardableResult
    func build(sources: [FilterListManager.Source],
               accepting: (@MainActor () -> Bool)? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        precondition(buildGeneration < UInt64.max)
        buildGeneration += 1
        let generation = buildGeneration
        let start = CFAbsoluteTimeGetCurrent()
        let resources = ScriptletResources.json()
        let cacheFile = self.cacheFile
        let (built, restored, serialized) = await Task.detached(priority: .userInitiated) { () -> (UnsafeMutableRawPointer?, Bool, Data?) in
            let key = Self.cacheKey(for: sources)
            let cached = Self.restore(matching: key, from: cacheFile)
            var engine = cached?.engine
            var bytes = cached?.bytes
            let restored = engine != nil
            if engine == nil {
                engine = Self.parse(sources)
                if let engine {
                    bytes = Self.serialize(engine)
                    if let bytes { Self.save(bytes, key: key, to: cacheFile) }
                }
            }
            guard let bytes else {
                if let engine { nook_adblock_engine_free(engine) }
                return (nil, restored, nil)
            }
            // Resources are not part of the saved bytes, so both paths install them.
            if let engine, var resources {
                let ok = resources.withUTF8 { buf in
                    nook_adblock_engine_use_resources(
                        engine, UnsafeRawPointer(buf.baseAddress)?.assumingMemoryBound(to: CChar.self), buf.count)
                }
                if !ok {
                    log.error("Scriptlet resource set rejected by the engine")
                    nook_adblock_engine_free(engine)
                    return (nil, restored, nil)
                }
            }
            return (engine, restored, bytes)
        }.value

        let ownerAccepts = accepting?() ?? true
        guard ownerAccepts, generation == buildGeneration, !Task.isCancelled else {
            if let built { nook_adblock_engine_free(built) }
            return false
        }
        guard let built else {
            log.error("Failed to build the blocker engine")
            return false
        }
        if let engine { nook_adblock_engine_free(engine) }
        engine = built
        networkRules = serialized.map { NetworkRules(generation: generation, bytes: $0) }
        let trusted = sources.filter(\.isTrusted).count
        log.info("Engine sources: \(sources.count, privacy: .public) list(s), \(trusted, privacy: .public) trusted, resources: \(resources != nil ? "yes" : "no", privacy: .public)")
        log.info("Blocker engine \(restored ? "restored" : "built", privacy: .public) in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start), privacy: .public)s")
        return true
    }

    nonisolated private static func parse(_ sources: [FilterListManager.Source]) -> UnsafeMutableRawPointer? {
        let payload = sources.map { ["rules": $0.rules, "trusted": $0.isTrusted] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var text = String(data: data, encoding: .utf8) else {
            log.error("Could not encode filter lists for the engine")
            return nil
        }
        // Pass the byte count, not strlen: a NUL in one list would otherwise
        // cut off every list after it.
        return text.withUTF8 { buf in
            nook_adblock_engine_from_lists(
                UnsafeRawPointer(buf.baseAddress)?.assumingMemoryBound(to: CChar.self), buf.count)
        }
    }

    // MARK: - Saved engine

    /// The parsed engine, saved so a launch with unchanged lists skips the parse (0.3 s).
    /// One file: a 32-byte key, then `Engine::serialize` bytes.
    /// Everything the parse depends on: each list's text and trust, and the build, since a new
    /// build can carry a new parser. Bump the leading tag if the Rust side changes without one.
    nonisolated private static func cacheKey(for sources: [FilterListManager.Source]) -> Data {
        var hasher = SHA256()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        hasher.update(data: Data("engine-v1 \(build)".utf8))
        for source in sources {
            // The length keeps two lists from hashing like one list split elsewhere.
            hasher.update(data: Data("\n\(source.isTrusted) \(source.rules.utf8.count)\n".utf8))
            var rules = source.rules
            rules.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        }
        return Data(hasher.finalize())
    }

    nonisolated private static func restore(matching key: Data, from cacheFile: URL?)
        -> (engine: UnsafeMutableRawPointer, bytes: Data)? {
        guard let cacheFile, let saved = try? Data(contentsOf: cacheFile, options: .mappedIfSafe),
              saved.count > key.count, saved.prefix(key.count) == key else { return nil }
        // A file the Rust side cannot read comes back nil, and the caller parses.
        guard let engine = saved.withUnsafeBytes({ bytes in
            nook_adblock_engine_deserialize(
                bytes.bindMemory(to: UInt8.self).baseAddress?.advanced(by: key.count), bytes.count - key.count)
        }) else { return nil }
        return (engine, Data(saved.dropFirst(key.count)))
    }

    nonisolated private static func serialize(_ engine: UnsafeMutableRawPointer) -> Data? {
        var length = 0
        guard let bytes = nook_adblock_engine_serialize(engine, &length) else { return nil }
        defer { nook_adblock_buffer_free(bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    nonisolated private static func save(_ bytes: Data, key: Data, to cacheFile: URL?) {
        guard let cacheFile else { return }
        var file = key
        file.append(bytes)
        do {
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.write(to: cacheFile, options: .atomic)
        } catch {
            log.error("Could not save the engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        precondition(buildGeneration < UInt64.max)
        buildGeneration += 1
        if let engine { nook_adblock_engine_free(engine) }
        engine = nil
        networkRules = nil
    }

    /// True when the request would be blocked. Used by the dev MCP `check_urls`
    /// tool. Chromium consumes the serialized policy on its own request path.
    public func matches(url: String, sourceURL: String, type: String) -> Bool {
        guard let engine else { return false }
        return url.withCString { u in
            sourceURL.withCString { s in
                type.withCString { t in
                    nook_adblock_engine_matches(engine, u, s, t)
                }
            }
        }
    }
}
