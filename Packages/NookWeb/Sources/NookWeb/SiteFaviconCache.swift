// Licensed under GPL-3.0. See LICENSE.
import AppKit
import CryptoKit
import Foundation
import ImageIO
import NookSettings
import NookTabsCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A device-only cache of icons Chromium has already fetched for regular profiles.
@MainActor
@Observable
public final class SiteFaviconCache {
    private struct Entry: Codable {
        let profile: UUID
        let key: Data
        let png: Data
    }

    private static let maxEntries = 256
    private static let maxFileSize = 9 * 1024 * 1024
    private let file: URL
    private var images: [Data: PlatformImage] = [:]
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var dirty = false

    init(directory: URL) {
        file = directory.appendingPathComponent("site-favicons.plist")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maxFileSize,
              let bytes = try? Data(contentsOf: file),
              let saved = try? PropertyListDecoder().decode([Entry].self, from: bytes) else { return }
        for entry in saved.suffix(Self.maxEntries) where entry.key.count == SHA256.Digest.byteCount {
            guard images[entry.key] == nil, let image = Self.decodePNG(entry.png) else { continue }
            images[entry.key] = image
            entries.append(entry)
        }
    }

    private static func key(profile: UUID, url: URL) -> Data? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        let address = KagiSession.withoutToken(url).absoluteString
        return Data(SHA256.hash(data: Data((profile.uuidString + "\n" + address).utf8)))
    }

    func image(profile: UUID, url: URL) -> PlatformImage? {
        Self.key(profile: profile, url: url).flatMap { images[$0] }
    }

    func remember(_ png: Data, image: PlatformImage, profile: UUID, url: URL) {
        guard (1...32_768).contains(png.count), let key = Self.key(profile: profile, url: url),
              entries.first(where: { $0.key == key })?.png != png else { return }
        entries.removeAll { $0.key == key }
        entries.append(Entry(profile: profile, key: key, png: png))
        images[key] = image
        if entries.count > Self.maxEntries {
            images[entries.removeFirst().key] = nil
        }
        dirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.flush()
        }
    }

    func removeProfile(_ profile: UUID) {
        let removed = entries.filter { $0.profile == profile }
        guard !removed.isEmpty else { return }
        entries.removeAll { $0.profile == profile }
        for entry in removed { images[entry.key] = nil }
        dirty = true
        flush()
    }

    func flush() {
        guard dirty else { return }
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let bytes = try? encoder.encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            dirty = false
        } catch { }
    }

    // Also used to validate the borrowed PNG copied at the Chromium bridge.
    nonisolated public static func decodePNG(_ data: Data) -> PlatformImage? {
        guard (1...32_768).contains(data.count),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...32).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...32).contains(height),
              let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PlatformImage(cgImage: bitmap, size: NSSize(width: width, height: height))
    }
}

extension TabsController {
    func rememberFavicon(_ png: Data, image: PlatformImage, url: URL, profileID: UUID, for page: PageSession) {
        guard !isReadOnly, !isTerminating, !page.isPrivate, !page.isAgentPage, !page.isDetached,
              session(for: page.itemID) === page, faviconProfile(for: page.itemID) == profileID else { return }
        siteFavicons.remember(png, image: image, profile: profileID, url: url)
    }

    func faviconImage(for item: Item) -> PlatformImage? {
        let page = session(for: item.id)
        if let image = page?.faviconImage { return image }
        guard let profileID = faviconProfile(for: item.id),
              let url = page?.url ?? item.url else { return nil }
        return siteFavicons.image(profile: profileID, url: url)
    }

    public func favicon(for item: Item) -> Image {
        faviconImage(for: item).map(Image.init(platformImage:)) ?? Image(systemName: "globe")
    }

    private func faviconProfile(for itemID: UUID) -> UUID? {
        guard let space = tree.spaceID(of: itemID), space != agentSpaceID,
              profileSpaceIsReady(space) else { return nil }
        return tree.dataStoreID(for: space)
    }
}
