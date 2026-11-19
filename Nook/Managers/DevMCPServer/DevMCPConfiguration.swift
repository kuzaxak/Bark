import Foundation
import Darwin

/// Explicit destinations for the existing local server. Constructing this value never reads a token.
struct DevMCPConfiguration: Equatable, Sendable {
    let port: UInt16
    let tokenFile: URL
    let filesRoot: URL
    var confinedRoot: URL? = nil

    static func isEnabled(developerMode: Bool, browserControl: Bool) -> Bool {
        developerMode && browserControl
    }

    static func native(appRoot: URL, port: UInt16 = 47823) throws -> Self {
        let standardized = appRoot.standardizedFileURL
        let expected = DevMCPFiles.realPath(standardized.deletingLastPathComponent())
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
        let root = DevMCPFiles.realPath(standardized)
        // Startup validates App against its configured root as well; never canonicalize
        // a substituted App symlink into a different store when used independently.
        guard root.path == expected.path else { throw ConfigurationError.unsafePath }
        let directory = root.appendingPathComponent("DevMCP", isDirectory: true)
        let result = Self(port: port, tokenFile: directory.appendingPathComponent("token"),
                          filesRoot: directory.appendingPathComponent("Files", isDirectory: true), confinedRoot: root)
        for url in [directory, result.tokenFile, result.filesRoot] {
            guard DevMCPFiles.realPath(url).path.hasPrefix(root.path + "/") else {
                throw ConfigurationError.unsafePath
            }
        }
        return result
    }

    func validatePaths() throws {
        guard let confinedRoot else { return }
        for url in [tokenFile, filesRoot] {
            let resolved = DevMCPFiles.realPath(url.standardizedFileURL)
            guard resolved.path.hasPrefix(confinedRoot.path + "/"),
                  resolved.path == url.standardizedFileURL.path else { throw ConfigurationError.unsafePath }
        }
    }

    func resolve(_ relative: String) -> URL? {
        guard (try? validatePaths()) != nil else { return nil }
        return DevMCPFiles.resolve(relative, root: filesRoot)
    }

    func loadOrCreateToken() throws -> String {
        try validatePaths()
        let manager = FileManager.default
        try manager.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try validatePaths()
        var descriptor = open(tokenFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT {
            descriptor = open(tokenFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ConfigurationError.unsafeToken }
            defer { close(descriptor) }
            let bytes = Array((UUID().uuidString + UUID().uuidString).utf8)
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard written == bytes.count, fsync(descriptor) == 0 else { throw ConfigurationError.unsafeToken }
            return String(decoding: bytes, as: UTF8.self)
        }
        guard descriptor >= 0 else { throw ConfigurationError.unsafeToken }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_size >= 32, info.st_size <= 1024 else {
            throw ConfigurationError.unsafeToken
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count, let value = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count >= 32 else { throw ConfigurationError.unsafeToken }
        return value
    }

    enum ConfigurationError: Error { case unsafePath, unsafeToken }
}
