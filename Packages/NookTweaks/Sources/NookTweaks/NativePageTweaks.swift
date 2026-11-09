// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookSettings

/// Fixed preferences for the existing packaged scripts, not an executable IPC.
/// Only explicitly enabled saved Boosts carry user code, in list order.
public struct NativePageTweaks: Codable, Equatable, Sendable {
    public struct YouTube: Codable, Equatable, Sendable {
        public var css: String
        public var frameThumbnails: Bool
        public var noHoverPreview: Bool
    }
    public struct Script: Codable, Equatable, Sendable {
        public var host: String
        public var includeSubdomains: Bool
        public var source: String
    }
    public var mediaDownloadSites: [String]
    public var sponsorBlock: [String: String]
    public let version: Int
    public var youtube: YouTube
    public var facebookReels: Bool
    public var facebookSuggested: Bool
    public var redditHot: Bool
    public var scripts: [Script]
    public static let maxPayloadBytes = 16 * 1024 * 1024

    @MainActor public init(settings: NookSettingsService) throws {
        version = 1
        mediaDownloadSites = settings.mediaDownloadSites.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && Boost.normalizeHost($0) == $0 }
        guard mediaDownloadSites.count <= 256 else { throw Failure.payloadTooLarge }
        sponsorBlock = settings.sponsorBlockEnabled ? settings.sponsorBlockCategoryOptions.filter {
            SponsorBlockCategory(rawValue: $0.key) != nil && ($0.value == "auto" || $0.value == "manual")
        } : [:]
        guard settings.boostsLoaded else { throw Failure.boostsLoading }
        youtube = .init(css: YouTubeTweaks.css(for: settings),
            frameThumbnails: settings.youTubeFrameThumbnails, noHoverPreview: settings.youTubeNoHoverPreview)
        facebookReels = settings.facebookHideReels
        facebookSuggested = settings.facebookHideSuggested
        redditHot = settings.redditSortHot
        scripts = settings.boosts.filter { $0.isEnabled && $0.scriptEnabled && !$0.script.isEmpty && !$0.host.isEmpty }
            .map { .init(host: $0.host, includeSubdomains: $0.includeSubdomains, source: $0.script) }
        guard scripts.count <= Boost.maxCount,
              scripts.allSatisfy({ $0.source.utf8.count <= Boost.maxScriptBytes && Boost.normalizeHost($0.host) == $0.host })
        else { throw Failure.invalidSavedScript }
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxPayloadBytes else { throw Failure.payloadTooLarge }
        return data
    }
    public enum Failure: Error { case boostsLoading, invalidSavedScript, payloadTooLarge }
}
