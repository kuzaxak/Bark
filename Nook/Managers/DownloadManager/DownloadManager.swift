// Licensed under GPL-3.0. See LICENSE.
//
//  DownloadManager.swift
//  Nook
//
//  Created by Maciek Bagiński on 05/08/2025.
//

import AppKit
import Foundation
import CryptoKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import NookDesign
import NookSettings
import NookWeb

// MARK: - Download Origin

/// Which page started a download, captured when it starts.
struct DownloadOrigin {
    /// A private window or the Agent space (or no page known): kept off disk and away from Tidy.
    var isPrivate: Bool
    /// The data store id of the page's profile, for the downloads list filter.
    var profileID: UUID?

    static let unknown = DownloadOrigin(isPrivate: true, profileID: nil)
}

extension DownloadOrigin {
    @MainActor
    init(session: PageSession?) {
        guard let session else { self = .unknown; return }
        let profile = session.profile
        self.init(
            isPrivate: session.isPrivate || session.isAgentPage || profile?.isEphemeral == true,
            profileID: profile?.id)
    }
}

/// Native identity scopes an engine GUID to its actual profile/session.
struct NativeDownloadIdentity: Equatable {
    let profileID: UUID
    let isPrivate: Bool
    let guid: String
    var rowID: UUID {
        let key = "native-download\n\(profileID.uuidString.lowercased())\n\(isPrivate)\n\(guid)"
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

struct NativeDownloadUpdate {
    let identity: NativeDownloadIdentity
    let manager: UInt64
    let observation: UInt64
    let url: URL
    let filename: String
    let target: URL?
    let state: Download.DownloadState
    let unsafe: Bool
    let safeFile: Bool
    let received: Int64
    let total: Int64?
    let started: Date
    let error: Int32
}

// MARK: - Download Model

@Observable
public class Download: Identifiable {
    public let id: UUID
    let originalURL: URL
    var suggestedFilename: String
    var destinationURL: URL?
    var nativeIdentity: NativeDownloadIdentity?
    var nativeManager: UInt64 = 0
    var nativeObservation: UInt64 = 0
    var nativeUnsafe = false
    var nativeSafeFile = false
    var nativeRemoveAfterCancel = false
    @ObservationIgnored var nativeAction: ((Bool) -> Bool)?
    @ObservationIgnored var nativeSafeTarget: (() -> URL?)?
    let origin: DownloadOrigin
    var progress: Double
    var state: DownloadState {
        didSet {
            if state == .completed && oldValue != .completed {
                Task {
                    await loadThumbnail()
                }
            }
        }
    }

    var error: Error?
    var fileSize: Int64?
    var downloadedBytes: Int64
    let icon: NSImage
    var startDate: Date
    var downloadThumbnail: NSImage?
    /// Where it started, for the flight to the downloads button: the window, and the pointer in
    /// window coordinates when it began, which is where the click was. Nothing renders from these.
    @ObservationIgnored weak var sourceWindow: NSWindow?
    @ObservationIgnored var launchPoint: NSPoint?

    enum DownloadState {
        case pending
        case downloading
        case completed
        case failed
        case cancelled

        var description: String {
            switch self {
            case .pending:
                return "Pending"
            case .downloading:
                return "Downloading"
            case .completed:
                return "Completed"
            case .failed:
                return "Failed"
            case .cancelled:
                return "Cancelled"
            }
        }

        var icon: String {
            switch self {
            case .pending:
                return "clock"
            case .downloading:
                return "arrow.down.circle"
            case .completed:
                return "checkmark.circle"
            case .failed:
                return "exclamationmark.circle"
            case .cancelled:
                return "xmark.circle"
            }
        }
    }

    init(
        id: UUID = UUID(),
        originalURL: URL,
        suggestedFilename: String,
        origin: DownloadOrigin,
        state: DownloadState = .pending
    ) {
        self.id = id
        self.originalURL = originalURL
        self.suggestedFilename = suggestedFilename
        self.origin = origin
        progress = state == .completed ? 1 : 0
        self.state = state
        downloadedBytes = 0
        startDate = Date()

        // Set default icon based on file extension
        icon = Self.icon(forFilename: suggestedFilename)
    }

    @MainActor
    func loadThumbnail(size: CGSize = CGSize(width: 80, height: 80)) async {
        guard let destinationURL = validatedCompletedFile(),
              downloadThumbnail == nil
        else {
            return
        }

        #if DEBUG
        print("Loading thumbnail for: \(destinationURL.lastPathComponent)")
        #endif

        if shouldGenerateThumbnail(for: destinationURL) {
            if let thumbnail = await getQuickLookThumbnail(for: destinationURL, size: size) {
                guard validatedCompletedFile() == destinationURL else { return }
                downloadThumbnail = thumbnail
                #if DEBUG
                print("QuickLook thumbnail loaded for: \(destinationURL.lastPathComponent)")
                #endif
                return
            }
            #if DEBUG
            print("QuickLook thumbnail failed, falling back to Finder icon for: \(destinationURL.lastPathComponent)")
            #endif
        }

        guard validatedCompletedFile() == destinationURL else { return }
        let finderIcon = NSWorkspace.shared.icon(forFile: destinationURL.path)

        let targetSize = NSSize(width: size.width, height: size.height)
        let highResIcon = NSImage(size: targetSize)

        highResIcon.lockFocus()
        finderIcon.draw(in: NSRect(origin: .zero, size: targetSize),
                        from: NSRect(origin: .zero, size: finderIcon.size),
                        operation: .copy,
                        fraction: 1.0)
        highResIcon.unlockFocus()

        downloadThumbnail = highResIcon
        #if DEBUG
        print("Finder icon loaded for: \(destinationURL.lastPathComponent)")
        #endif
    }

    private func shouldGenerateThumbnail(for fileURL: URL) -> Bool {
        let fileExtension = fileURL.pathExtension.lowercased()

        let supportedExtensions: Set<String> = [
            // Images
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "webp", "ico", "svg",
            // Videos
            "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v",
            // Documents
            "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "pages", "numbers", "keynote",
            // Text files
            "txt", "rtf", "html", "htm", "md", "swift", "js", "css", "json", "xml",
            // Audio files
            "mp3", "m4a", "flac", "aac",
        ]

        return supportedExtensions.contains(fileExtension)
    }

    private func getQuickLookThumbnail(for fileURL: URL, size: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 1.0,
            representationTypes: .thumbnail
        )

        do {
            let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return thumbnail.nsImage
        } catch {
            return nil
        }
    }

    private static func icon(forFilename filename: String) -> NSImage {
        let fileExtension = (filename as NSString).pathExtension.lowercased()

        let possibleTypes = UTType.types(tag: fileExtension,
                                         tagClass: .filenameExtension,
                                         conformingTo: nil)

        if let utType = possibleTypes.first {
            return NSWorkspace.shared.icon(for: utType)
        } else {
            return NSWorkspace.shared.icon(for: .item)
        }
    }

    var formattedFileSize: String {
        guard let fileSize = fileSize else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDownloadedSize: String {
        return ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var formattedProgress: String {
        return String(format: "%.1f%%", progress * 100)
    }

    var displayName: String { destinationURL?.lastPathComponent ?? suggestedFilename }

    var completedFile: URL? {
        guard state == .completed, nativeIdentity == nil || (nativeSafeFile && !nativeUnsafe), let destinationURL,
              FileManager.default.fileExists(atPath: destinationURL.path) else { return nil }
        return destinationURL
    }

    /// Validate native authority only on file/thumbnail/preview actions, not on
    /// row rendering. The returned path is the current engine-owned target.
    func validatedCompletedFile() -> URL? {
        if nativeIdentity != nil {
            guard state == .completed, nativeSafeFile, !nativeUnsafe,
                  let target = nativeSafeTarget?(), FileManager.default.fileExists(atPath: target.path) else { return nil }
            return target
        }
        return completedFile
    }

    var statusDescription: String { nativeUnsafe ? "Blocked by browser" : state.description }

    /// Drags the file itself. The old provider also read the whole file into memory on the main
    /// thread as the drag began, which hung the app on a large download.
    func dragItemProvider() -> NSItemProvider {
        validatedCompletedFile().flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
    }
}

extension Notification.Name {
    /// Posted with the `Download` once it has a destination and bytes are on the way.
    static let downloadDidStart = Notification.Name("NookDownloadDidStart")
}

// MARK: - Download Manager

@MainActor
@Observable
public class DownloadManager: NSObject {
    private var downloads: [UUID: Download] = [:]

    /// Bumped each time a download finishes, so the downloads button can bounce.
    private(set) var completedCount = 0

    /// The window a Chromium download that starts now came from, and the point in it where it was
    /// clicked; set by the app. Chromium does not say which page started a download.
    @ObservationIgnored var nativeLaunch: ((Download) -> (window: NSWindow, point: NSPoint)?)?
    /// Each profile's download location; set by the app.
    @ObservationIgnored weak var settings: NookSettingsService?
    /// The download open in the in-window preview, if any.
    private(set) var previewFileURL: URL?
    private(set) var previewWindowID: UUID?
    private(set) var previewing: Download? {
        didSet {
            previewFileURL = previewing?.validatedCompletedFile()
            if previewing != nil && previewFileURL == nil { previewing = nil }
            if previewing == nil { previewWindowID = nil }
        }
    }

    var activeDownloads: [Download] {
        return Array(downloads.values).filter { $0.state == .downloading || $0.state == .pending }
    }

    var allDownloads: [Download] {
        Array(downloads.values).sorted { $0.startDate > $1.startDate }
    }

    func isVisible(_ item: Download, in window: BrowserWindowState) -> Bool {
        if window.isIncognito {
            guard let profile = window.ephemeralProfile, profile.isEphemeral else { return false }
            return item.origin.isPrivate && item.origin.profileID == profile.id
        }
        return !item.origin.isPrivate
    }

    func visibleDownloads(in window: BrowserWindowState) -> [Download] {
        allDownloads.filter { isVisible($0, in: window) }
    }

    func recentDownloads(in window: BrowserWindowState) -> [Download] {
        let newest = visibleDownloads(in: window)
        return Array((newest.filter { $0.state == .pending || $0.state == .downloading } +
            newest.filter { $0.state == .completed } + newest.filter { $0.state == .failed }).prefix(4))
    }

    func preview(_ item: Download, in window: BrowserWindowState) {
        guard downloads[item.id] === item, isVisible(item, in: window) else { return }
        previewWindowID = window.id
        previewing = item
    }

    func previewTarget(for item: Download, in window: BrowserWindowState) -> URL? {
        guard previewing === item, previewWindowID == window.id, isVisible(item, in: window),
              let target = previewFileURL, item.validatedCompletedFile() == target else { return nil }
        return target
    }

    func dismissPreview(in window: BrowserWindowState) {
        if previewWindowID == window.id { previewing = nil }
    }

    /// Update the existing dictionary directly; no native history/index mirror.
    func applyNativeDownload(_ update: NativeDownloadUpdate,
                             action: @escaping (Bool) -> Bool,
                             safeTarget: @escaping () -> URL?) {
        let id = update.identity.rowID
        if let existing = downloads[id], existing.nativeIdentity != update.identity { return }
        let existed = downloads[id] != nil
        let item = downloads[id] ?? Download(id: id, originalURL: update.url,
            suggestedFilename: update.filename, origin: DownloadOrigin(isPrivate: update.identity.isPrivate,
                profileID: update.identity.profileID), state: update.state)
        let previous = item.state
        item.nativeIdentity = update.identity; item.nativeManager = update.manager
        item.nativeObservation = update.observation
        item.nativeAction = action; item.nativeSafeTarget = safeTarget
        item.nativeUnsafe = update.unsafe; item.nativeSafeFile = update.safeFile
        let starts = item.destinationURL == nil && update.target != nil && update.state == .downloading
        if update.unsafe || !update.safeFile || item.destinationURL != update.target { item.downloadThumbnail = nil }
        item.destinationURL = update.target; item.suggestedFilename = update.filename
        item.startDate = update.started; item.downloadedBytes = update.received; item.fileSize = update.total
        item.progress = update.total.flatMap { $0 > 0 ? min(1, Double(update.received) / Double($0)) : nil } ?? 0
        item.error = update.error == 0 ? nil : NSError(domain: "ChromiumDownload", code: Int(update.error),
            userInfo: [NSLocalizedDescriptionKey: "The download was interrupted."])
        if !existed { downloads[id] = item }
        guard downloads[id] === item else { return }
        item.state = update.state
        guard downloads[id] === item else { return }
        if update.state == .completed { item.progress = 1 }
        if existed, previous != .completed, update.state == .completed, !update.identity.isPrivate { completedCount += 1 }
        if item.nativeRemoveAfterCancel, update.state != .pending, update.state != .downloading {
            item.nativeRemoveAfterCancel = false
            _ = item.nativeAction?(true)
        }
        if previewing === item, (!update.safeFile || update.unsafe || previewFileURL != update.target) { previewing = nil }
        if starts {
            if let launch = nativeLaunch?(item) { item.sourceWindow = launch.window; item.launchPoint = launch.point }
            NotificationCenter.default.post(name: .downloadDidStart, object: item)
        }
    }

    func removeNativeDownload(_ identity: NativeDownloadIdentity, manager: UInt64, observation: UInt64) {
        let id = identity.rowID
        guard let item = downloads[id], item.nativeIdentity == identity, item.nativeManager == manager, item.nativeObservation == observation else { return }
        if previewing === item { previewing = nil }
        item.nativeAction = nil; item.nativeSafeTarget = nil; item.nativeSafeFile = false
        item.downloadThumbnail = nil
        downloads.removeValue(forKey: id)
    }

    func nativeManagerEnded(_ manager: UInt64, observation: UInt64) {
        // Source teardown is rare; progress uses direct dictionary lookup.
        for item in downloads.values.filter({ $0.nativeManager == manager && $0.nativeObservation == observation }) {
            if previewing === item { previewing = nil }
            item.nativeAction = nil; item.nativeSafeTarget = nil; item.nativeSafeFile = false
            item.downloadThumbnail = nil
            downloads.removeValue(forKey: item.id)
        }
    }

    func stopNativeDownloads(observation: UInt64) {
        let managers = Set(downloads.values.filter { $0.nativeIdentity != nil && $0.nativeObservation == observation }.map(\.nativeManager))
        for manager in managers { nativeManagerEnded(manager, observation: observation) }
    }

    // MARK: - Download Management

    /// Moves a finished file to the Trash and takes its row out of the list.
    func moveToTrash(_ download: Download, expectedFile: URL? = nil) {
        guard downloads[download.id] === download else { return }
        guard let file = download.validatedCompletedFile() else {
            if expectedFile == nil, download.nativeIdentity == nil { removeDownload(download.id) }
            return
        }
        guard expectedFile == nil || expectedFile == file else { return }
        let manager = download.nativeManager
        let observation = download.nativeObservation
        let destination = download.destinationURL
        NSWorkspace.shared.recycle([file]) { [weak self] _, error in
            guard error == nil else { return }
            Task { @MainActor in
                guard let self, self.downloads[download.id] === download,
                      download.nativeManager == manager, download.nativeObservation == observation,
                      download.destinationURL == destination else { return }
                withAnimation(NookDesign.Motion.standard) { self.removeDownload(download.id) }
            }
        }
    }

    func removeDownload(_ id: UUID) {
        if let item = downloads[id], item.nativeIdentity != nil {
            if item.state == .pending || item.state == .downloading {
                item.nativeRemoveAfterCancel = true
                if item.nativeAction?(false) != true {
                    item.nativeRemoveAfterCancel = false
                    _ = item.nativeAction?(true) // The engine may already be terminal.
                }
            } else { _ = item.nativeAction?(true) }
            return
        }
        if previewing?.id == id { previewing = nil }
        downloads.removeValue(forKey: id)
    }

    func cancelDownload(_ id: UUID) {
        _ = downloads[id]?.nativeAction?(false)
    }

    /// Writes bytes Bark already holds into Downloads and lists them as a finished download, with
    /// the same naming, quarantine, flight and bounce as a network download.
    @discardableResult
    func saveCompletedFile(
        _ data: Data,
        suggestedFilename: String,
        originalURL: URL,
        from window: NSWindow?,
        origin: DownloadOrigin
    ) -> Download? {
        let name = Self.sanitizedFilename(suggestedFilename)
        // The bytes are already here, so Ask Every Time saves where the last panel did.
        let folder: URL
        switch destination(for: origin) {
        case .folder(let url), .ask(startingIn: let url): folder = url
        }
        let destination = Self.uniqueDestination(for: name, in: folder)
        do {
            try data.write(to: destination, options: .withoutOverwriting)
        } catch {
            return nil
        }
        Self.setQuarantineAttribute(on: destination)

        let saved = Download(originalURL: originalURL, suggestedFilename: destination.lastPathComponent, origin: origin)
        saved.destinationURL = destination
        saved.fileSize = Int64(data.count)
        saved.downloadedBytes = Int64(data.count)
        saved.progress = 1
        saved.sourceWindow = window
        saved.launchPoint = window?.mouseLocationOutsideOfEventStream
        downloads[saved.id] = saved
        NotificationCenter.default.post(name: .downloadDidStart, object: saved)
        saved.state = .completed
        completedCount += 1
        Self.announceFinished(destination)
        return saved
    }

    // MARK: - Location

    private static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// The origin profile's choice in Settings > Profiles. Private pages always use Downloads.
    func destination(for origin: DownloadOrigin) -> DownloadDestination {
        let downloads = settings?.downloads(forProfile: origin.isPrivate ? nil : origin.profileID) ?? ProfileDownloads()
        return downloads.destination(downloads: Self.downloadsFolder) { url in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        }
    }

    /// Tells the Dock the file is complete, so its Downloads stack bounces and redraws the item,
    /// which it otherwise leaves as the gray icon it drew while the file was still being written.
    private static func announceFinished(_ url: URL?) {
        guard let url else { return }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.resolvingSymlinksInPath().path)
    }

    /// A name safe to create in a folder: one path component, no leading dots or NULs, at most 255
    /// characters. Idempotent, so a caller can adjust the name and run it again.
    static func sanitizedFilename(_ suggested: String) -> String {
        var name = (suggested.isEmpty ? "download" : suggested)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        while name.hasPrefix(".") {
            name = String(name.dropFirst())
        }
        if name.isEmpty { name = "download" }
        if name.count > 255 {
            // Cap the extension: a server can name a file that is almost all extension, which
            // made maxBase negative and trapped in String.prefix.
            let ext = (name as NSString).pathExtension.prefix(32)
            let base = (name as NSString).deletingPathExtension
            let maxBase = 255 - (ext.isEmpty ? 0 : ext.count + 1)
            name = String(base.prefix(maxBase)) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return (name as NSString).lastPathComponent
    }

    /// `name` in `directory`, or "name (1)", "name (2)" and so on past files already there.
    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        var destination = directory.appendingPathComponent(name)
        let ext = destination.pathExtension
        let base = destination.deletingPathExtension().lastPathComponent
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)"))
            counter += 1
        }
        return destination
    }

    /// Sets the `com.apple.quarantine` extended attribute on a downloaded file.
    ///
    /// This ensures macOS Gatekeeper will prompt the user before opening
    /// executables, disk images, or other potentially dangerous files
    /// downloaded from the web.
    nonisolated static func setQuarantineAttribute(on fileURL: URL) {
        // com.apple.quarantine format: flags;timestamp_hex;agent_name;uuid
        // 0083 = "downloaded from the web, not yet opened by the user"
        let quarantineValue = "0083;\(String(format: "%08x", Int(Date().timeIntervalSince1970)));Bark;\(UUID().uuidString)"
        guard let data = quarantineValue.data(using: .utf8) else { return }

        fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path = path else { return }
            let result = setxattr(path, "com.apple.quarantine", (data as NSData).bytes, data.count, 0, 0)
            if result != 0 {
                #if DEBUG
                print("Failed to set quarantine attribute on \(fileURL.lastPathComponent): errno \(errno)")
                #endif
            }
        }
    }
}
