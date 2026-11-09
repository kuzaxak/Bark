// Licensed under GPL-3.0. See LICENSE.
//
//  DevMCPFiles.swift
//  Nook
//
//  Where DevMCP's evaluate saveTo and download tools may write (only under ~/Downloads/Nook MCP),
//  file names for downloaded URLs, and which of the page's cookies a download sends.
//  Foundation only, so scripts/tests/DevMCPFilesCheck.swift can compile it directly.
//

import Foundation
import Darwin

enum DevMCPFiles {
    static let root = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nook MCP", isDirectory: true)

    /// `relative` under `root`, or nil when it is empty, absolute, or climbs out through `..` or a symlink.
    static func resolve(_ relative: String, root: URL = root) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return nil }
        let base = realPath(root.standardizedFileURL)
        let url = realPath(base.appendingPathComponent(relative).standardizedFileURL)
        return url.path.hasPrefix(base.path + "/") ? url : nil
    }

    /// `resolvingSymlinksInPath` leaves a path alone when its last part doesn't exist yet,
    /// so resolve the deepest existing ancestor and put the rest back on.
    static func realPath(_ url: URL) -> URL {
        var existing = url, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    /// Native preflight uses libc's canonical spelling; Foundation may
    /// abbreviate /private/tmp to /tmp. Keep ordinary configuration unchanged.
    static func nativeDirectory(_ url: URL) -> URL? {
        guard url.isFileURL, let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// A short hash of the URL (so two `image.jpg`s don't collide) plus its last path component made safe;
    /// the extension comes from the content type when the URL has none.
    static func fileName(for url: URL, contentType: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var name = String(url.lastPathComponent.unicodeScalars.filter { allowed.contains($0) }.prefix(80).map(Character.init))
        if name.isEmpty || name == "." || name == ".." { name = "file" }
        if !name.contains("."), let ext = contentType.flatMap(extensionFor) { name += "." + ext }
        return hash(url.absoluteString) + "-" + name
    }

    static func extensionFor(_ contentType: String) -> String? {
        let type = contentType.split(separator: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        return ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "image/avif": "avif",
                "image/svg+xml": "svg", "application/pdf": "pdf", "application/json": "json", "text/html": "html",
                "text/plain": "txt", "video/mp4": "mp4"][type]
    }

    /// FNV-1a, 8 hex digits: stable across launches, unlike `hashValue`.
    static func hash(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(format: "%08x", h)
    }

    /// The cookies a browser would send to `url`: domain and path match, secure ones only over https, unexpired.
    static func cookies(_ all: [HTTPCookie], for url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return all.filter { c in
            let domain = c.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let domainOK = host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare))
            let cp = c.path.isEmpty ? "/" : c.path
            let pathOK = path == cp || path.hasPrefix(cp.hasSuffix("/") ? cp : cp + "/")
            return domainOK && pathOK && (!c.isSecure || url.scheme == "https") && (c.expiresDate.map { $0 > now } ?? true)
        }
    }
}

/// The one native temporary file: cleanup and publication are anchored to its
/// actual parent descriptor, never an old absolute pathname after replacement.
final class DevMCPTemporaryFile: @unchecked Sendable {
    let url: URL
    let directory: FileHandle
    init(url: URL, directoryDescriptor: Int32) {
        self.url=url;directory=FileHandle(fileDescriptor:directoryDescriptor,closeOnDealloc:true)
    }
    deinit {
        let directory=directory,name=url.lastPathComponent
        Task.detached(priority:.utility) {
            unlinkat(directory.fileDescriptor,name,0)
            try? directory.close()
        }
    }
    var size: Int64? {
        var info=stat()
        guard fstatat(directory.fileDescriptor,url.lastPathComponent,&info,AT_SYMLINK_NOFOLLOW)==0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return info.st_size
    }
}

/// The download tool's job: fetches `urls` into `dir` six at a time with the page's cookies,
/// user agent and Referer, appending one `manifest.jsonl` line per URL. Outlives the tool call.
final class DevMCPDownload: @unchecked Sendable {
    static let maxBytes = 100 * 1024 * 1024

    let urls: [URL]
    let dir: URL
    private let cookies: [HTTPCookie]
    private let userAgent: String?
    private let referer: String?
    struct NativeFile: Sendable {
        let temporary: DevMCPTemporaryFile?
        let status: String
        let httpStatus: Int
        let contentType: String
        let bytes: Int64
    }
    typealias NativeFetch = @Sendable (URL, URL) async throws -> NativeFile
    private(set) weak var nativeOwner: AnyObject?
    private let nativeDirectory: FileHandle?
    private let nativeFetch: NativeFetch?
    private let filesRoot: URL?
    private let canPublish: (@MainActor @Sendable () -> Bool)?
    private let completionSignal = AsyncStream<Void>.makeStream()
    private var work: Task<Void, Never>?
    private let session: URLSession?
    private let lock = NSLock()
    private let manifestLock = NSLock()
    private var counts: [String: Int] = [:]
    private var finished = false
    private var cancelled = false

    init(urls: [URL], dir: URL, cookies: [HTTPCookie], userAgent: String?, referer: String?) {
        nativeFetch = nil; filesRoot = nil; canPublish = nil; nativeOwner = nil; nativeDirectory = nil
        self.urls = urls
        self.dir = dir
        self.cookies = cookies
        self.userAgent = userAgent
        self.referer = referer
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    init(urls: [URL], dir: URL, filesRoot: URL, owner: AnyObject, canPublish: @escaping @MainActor @Sendable () -> Bool, nativeFetch: @escaping NativeFetch) throws {
        self.urls = urls; self.dir = dir; self.filesRoot = filesRoot; nativeOwner=owner
        let descriptor=open(dir.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard descriptor>=0 else { throw POSIXError(.EACCES) }
        nativeDirectory=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        self.nativeFetch = nativeFetch; self.canPublish = canPublish
        cookies = []; userAgent = nil; referer = nil; session = nil
    }

    /// Status counts so far (ok, exists, http, error, tooLarge) and whether every URL is done.
    var progress: (counts: [String: Int], finished: Bool) { lock.withLock { (counts, finished) } }

    func cancel() {
        let pending = lock.withLock { cancelled = true; finished = true; return work }
        pending?.cancel()
        session?.invalidateAndCancel()
        completionSignal.continuation.finish()
    }

    var isCancelled: Bool {lock.withLock{cancelled}}
    var batchTask: Task<Void,Never>? {lock.withLock{work}}
    @discardableResult
    func start(after predecessors:[Task<Void,Never>] = []) -> Task<Void,Never> {
        lock.withLock {
            if let work {return work}
            let task=Task.detached(priority:.utility) { [self] in
                for preceding in predecessors {await preceding.value}
                if !Task.isCancelled, !lock.withLock({cancelled}) {
                    await withTaskGroup(of:Void.self) { group in
                        var pending=urls.makeIterator()
                        for _ in 0..<6 {if let url=pending.next(){group.addTask{await self.fetch(url)}}}
                        while await group.next() != nil {
                            guard !Task.isCancelled, !lock.withLock({cancelled}) else {group.cancelAll();break}
                            if let url=pending.next(){group.addTask{await self.fetch(url)}}
                        }
                    }
                }
                session?.finishTasksAndInvalidate()
                lock.withLock{work=nil;finished=true}
                completionSignal.continuation.finish()
            }
            work=task
            if cancelled {task.cancel()}
            return task
        }
    }
    func run() async {await start().value}

    /// One completion signal raced with the existing tool deadline; no progress
    /// polling. A normal 20s answer leaves the owned batch running, as before.
    func waitForCompletion(seconds: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in self.completionSignal.stream {} }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            _ = await group.next();group.cancelAll()
        }
    }

    private func directoryIsCurrent() -> Bool {
        guard let root = filesRoot else { return true }
        return DevMCPFiles.realPath(dir).path == dir.standardizedFileURL.path &&
            DevMCPFiles.realPath(root).path == root.standardizedFileURL.path && dir.path.hasPrefix(root.path + "/") &&
            nativeDirectory.map{directoryStillNames($0.fileDescriptor)} == true
    }

    private func fetchNative(_ url: URL, using fetch: NativeFetch) async {
        guard !Task.isCancelled, !lock.withLock({ cancelled }) else { return }
        var row: [String: Any] = ["url": url.absoluteString]
        let guess = dir.appendingPathComponent(DevMCPFiles.fileName(for: url, contentType: nil))
        if !url.pathExtension.isEmpty, FileManager.default.fileExists(atPath: guess.path) {
            row["status"] = "exists";row["file"] = guess.lastPathComponent;record(row);return
        }
        do {
            guard url.scheme?.lowercased() == "https", directoryIsCurrent() else { throw URLError(.unsupportedURL) }
            let result = try await fetch(url, dir)
            try Task.checkCancellation()
            guard let canPublish, await canPublish() else { cancel();throw CancellationError() }
            row["httpStatus"] = result.httpStatus;row["contentType"] = result.contentType
            if result.status == "ok" {
                guard let temporary = result.temporary, temporary.url.isFileURL,
                      let canonicalDirectory = DevMCPFiles.nativeDirectory(dir),
                      DevMCPFiles.nativeDirectory(temporary.url.deletingLastPathComponent()) == canonicalDirectory,
                      let size=temporary.size, size>=0, size<=Self.maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
                let file = dir.appendingPathComponent(DevMCPFiles.fileName(for: url,contentType: result.contentType))
                let parent = try publicationDirectory(temporary.url, at: file, ownedDirectory:temporary.directory.fileDescriptor)
                defer { close(parent) }
                // Final source/directory-identity checks and the exclusive
                // metadata rename run on MainActor; body writes and file
                // preparation stay off it.
                let published = try await MainActor.run {
                    guard canPublish() else { self.cancel();throw CancellationError() }
                    return try self.commitTemporary(temporary.url, at: file, parent: parent)
                }
                row["status"] = published ? "ok" : "exists"
                row["file"] = file.lastPathComponent;row["bytes"] = size
            } else { row["status"] = result.status }
        } catch {
            row["status"] = "error";row["error"] = error.localizedDescription
        }
        record(row)
    }

    private func fetch(_ url: URL) async {
        if let nativeFetch { await fetchNative(url,using: nativeFetch);return }
        guard let session else { return }
        guard !lock.withLock({ cancelled }) else { return }
        var row: [String: Any] = ["url": url.absoluteString]
        let guess = dir.appendingPathComponent(DevMCPFiles.fileName(for: url, contentType: nil))
        if !url.pathExtension.isEmpty, FileManager.default.fileExists(atPath: guess.path) {
            row["status"] = "exists"; row["file"] = guess.lastPathComponent
            return record(row)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (field, value) in HTTPCookie.requestHeaderFields(with: DevMCPFiles.cookies(cookies, for: url)) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let type = http?.value(forHTTPHeaderField: "Content-Type")
            row["httpStatus"] = http?.statusCode
            row["contentType"] = type
            if let code = http?.statusCode, !(200..<300).contains(code) {
                row["status"] = "http"
            } else if data.count > Self.maxBytes {
                row["status"] = "tooLarge"
            } else {
                let file = dir.appendingPathComponent(DevMCPFiles.fileName(for: url, contentType: type))
                if try store(data, at: file) {
                    row["status"] = "ok"
                    row["bytes"] = data.count
                } else {
                    row["status"] = "exists"
                }
                row["file"] = file.lastPathComponent
            }
        } catch {
            row["status"] = "error"
            row["error"] = error.localizedDescription
        }
        record(row)
    }

    /// Write large bytes outside the cancellation lock, then publish without replacing
    /// another job's destination. The writer seam also exercises cancellation mid-write.
    func store(_ data: Data, at file: URL,
               write: (Data, URL) throws -> Void = { try $0.write(to: $1) }) throws -> Bool {
        guard !lock.withLock({ cancelled }) else { throw CancellationError() }
        if FileManager.default.fileExists(atPath: file.path) { return false }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".devmcp-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(data, temporary)
        return try publishTemporary(temporary, at: file)
    }

    private func directoryStillNames(_ descriptor:Int32) -> Bool {
        var opened=stat(),named=stat()
        return fstat(descriptor,&opened)==0 && stat(dir.path,&named)==0 &&
            opened.st_dev==named.st_dev && opened.st_ino==named.st_ino
    }
    private func publicationDirectory(_ temporary: URL, at file: URL, ownedDirectory:Int32?=nil) throws -> Int32 {
        guard directoryIsCurrent(),
              (ownedDirectory == nil ? temporary.deletingLastPathComponent().path == dir.path :
                DevMCPFiles.nativeDirectory(dir).map { DevMCPFiles.nativeDirectory(temporary.deletingLastPathComponent()) == $0 } == true),
              file.deletingLastPathComponent().path == dir.path else { throw URLError(.noPermissionsToReadFile) }
        let parent = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(.EACCES) }
        guard directoryIsCurrent(), directoryStillNames(parent),
              ownedDirectory.map({directoryStillNames($0)}) ?? true else { close(parent);throw POSIXError(.EACCES) }
        return parent
    }
    private func commitTemporary(_ temporary: URL, at file: URL, parent: Int32) throws -> Bool {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard directoryStillNames(parent) else { throw POSIXError(.EACCES) }
            if renameatx_np(parent, temporary.lastPathComponent, parent, file.lastPathComponent, UInt32(RENAME_EXCL)) == 0 { return true }
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    private func publishTemporary(_ temporary: URL, at file: URL) throws -> Bool {
        let parent = try publicationDirectory(temporary, at: file)
        defer { close(parent) }
        return try commitTemporary(temporary, at: file, parent: parent)
    }

    private func record(_ row: [String: Any]) {
        if filesRoot != nil, !directoryIsCurrent() { cancel();return }
        guard var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        manifestLock.withLock {
            let admitted = lock.withLock {
                guard !cancelled else { return false }
                counts[row["status"] as? String ?? "error", default: 0] += 1
                return true
            }
            guard admitted else { return }
            if let directory=nativeDirectory {
                guard directoryIsCurrent() else {cancel();return}
                let descriptor=openat(directory.fileDescriptor,"manifest.jsonl",O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
                guard descriptor>=0 else {return}
                let file=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
                try? file.write(contentsOf:line);try? file.close();return
            }
            let manifest = dir.appendingPathComponent("manifest.jsonl")
            if let handle = try? FileHandle(forWritingTo: manifest) {
                handle.seekToEndOfFile(); handle.write(line); try? handle.close()
            } else {
                try? line.write(to: manifest)
            }
        }
    }
}
