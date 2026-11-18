// Licensed under GPL-3.0. See LICENSE.

#if os(macOS)
import Darwin
import Foundation
import NookSettings

extension VaultService {
    /// Disposable Chromium verification always uses this in-memory transport.
    public convenience init(verificationSettings settings: NookSettingsService, root: URL, profile: UUID) throws {
        let origin = try VerificationVault.origin(in: root)
        if origin != nil { VerificationVault.record("Bark verification vault: ready") }
        self.init(settings: settings, client: VerificationVault(origin: origin, profile: profile))
    }
}

actor VerificationVault: VaultRequests {
    private struct Fixture: Decodable { let origin: String }
    enum ConfigurationError: Error { case invalidFixture }

    static func record(_ marker: String) {
        try? FileHandle.standardError.write(contentsOf: Data((marker + "\n").utf8))
    }

    static func origin(in root: URL) throws -> String? {
        let fixture = root.appendingPathComponent("VaultFixture.json")
        // Read the same regular file that was validated. A swapped symlink or FIFO
        // in the disposable root cannot redirect or stall the startup read.
        let descriptor = open(fixture.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ConfigurationError.invalidFixture
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              let data = try handle.read(upToCount: 1025), data.count <= 1024 else {
            throw ConfigurationError.invalidFixture
        }
        let origin = try JSONDecoder().decode(Fixture.self, from: data).origin
        let prefix = "http://localhost:"
        guard origin.hasPrefix(prefix), let port = UInt16(origin.dropFirst(prefix.count)),
              port > 0, origin == prefix + String(port) else {
            throw ConfigurationError.invalidFixture
        }
        return origin
    }

    private let origin: String?
    private let profile: UUID
    private var logins: [VaultLogin] = [
        VaultLogin(id: "fixture-existing", username: "synthetic-existing", title: "Synthetic local vault")
    ]
    private var passwords = ["fixture-existing": "fixture-password"]

    init(origin: String?, profile: UUID) {
        self.origin = origin
        self.profile = profile
    }

    func disconnect() async {}

    func send<C: VaultCall>(_ call: C) async throws -> C.Reply {
        try Task.checkCancellation()
        guard let origin else { throw VaultClientError.notRunning }
        let reply: (any Sendable)
        switch call {
        case let request as VaultHello where request.profile == nil || matches(request.profile):
            reply = VaultHello.Reply(vault: "Synthetic local vault", version: 1, paired: true, unlocked: true)
        case let request as VaultLogins where request.origin == origin && matches(request.profile):
            reply = VaultLogins.Reply(logins: logins)
        case let request as VaultPassword where request.origin == origin && matches(request.profile):
            guard let login = logins.first(where: { $0.id == request.id }),
                  let password = passwords[request.id] else {
                throw VaultClientError.server(.notFound, "")
            }
            Self.record("Bark verification vault: password")
            reply = VaultPassword.Reply(username: login.username, password: password)
        case let request as VaultSave where request.origin == origin && matches(request.profile):
            let id = logins.first(where: { $0.username == request.username })?.id ?? UUID().uuidString
            if passwords[id] == nil {
                logins.append(VaultLogin(id: id, username: request.username, title: "Synthetic local vault"))
            }
            passwords[id] = request.password
            Self.record("Bark verification vault: save")
            reply = VaultSave.Reply(saved: true, id: id)
        case let request as VaultPasskeys where request.rpId == "localhost" && matches(request.profile):
            reply = VaultPasskeys.Reply(passkeys: [])
        case let request as VaultRegister where request.origin == origin && matches(request.profile):
            Self.record("Bark verification vault: register")
            throw VaultClientError.server(.denied, "")
        case let request as VaultAssert where request.origin == origin && matches(request.profile):
            Self.record("Bark verification vault: assert")
            throw VaultClientError.server(.denied, "")
        default:
            throw VaultClientError.server(.denied, "")
        }
        guard let typed = reply as? C.Reply else { throw VaultClientError.malformedResponse }
        return typed
    }

    private func matches(_ requestProfile: String?) -> Bool {
        requestProfile.flatMap(UUID.init(uuidString:)) == profile
    }
}
#endif
