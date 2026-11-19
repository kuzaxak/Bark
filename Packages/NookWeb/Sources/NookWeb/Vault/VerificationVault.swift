// Licensed under GPL-3.0. See LICENSE.

#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import NookSettings

extension VaultService {
    /// Disposable Chromium verification always uses this in-memory transport.
    public convenience init(verificationSettings settings: NookSettingsService, root: URL, profile: UUID,
                            pawlEnabledAtLaunch: Bool? = nil) throws {
        let fixture = try VerificationVault.configuration(in: root)
        let conditionalLoginWrites = fixture?.conditionalLoginWrites ?? true
        if fixture != nil {
            VerificationVault.record("Bark verification vault: ready")
            VerificationVault.record(conditionalLoginWrites
                ? "Bark verification vault: conditional login writes"
                : "Bark verification vault: legacy login writes")
        }
        self.init(settings: settings, client: VerificationVault(origin: fixture?.origin, profile: profile,
                                                               conditionalLoginWrites: conditionalLoginWrites,
                                                               assertionKey: fixture?.modalPasskey == true ? .init() : nil),
                  pawlEnabledAtLaunch: pawlEnabledAtLaunch)
    }
}

actor VerificationVault: VaultRequests {
    struct Fixture: Decodable {
        let origin: String
        let conditionalLoginWrites: Bool?
        let modalPasskey: Bool?
    }
    enum ConfigurationError: Error { case invalidFixture }

    static func record(_ marker: String) {
        try? FileHandle.standardError.write(contentsOf: Data((marker + "\n").utf8))
    }

    static func origin(in root: URL) throws -> String? {
        try configuration(in: root)?.origin
    }

    static func configuration(in root: URL) throws -> Fixture? {
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
        let configuration = try JSONDecoder().decode(Fixture.self, from: data)
        let origin = configuration.origin
        let prefix = "http://localhost:"
        guard origin.hasPrefix(prefix), let port = UInt16(origin.dropFirst(prefix.count)),
              port > 0, origin == prefix + String(port) else {
            throw ConfigurationError.invalidFixture
        }
        return configuration
    }

    private struct StoredLogin {
        let login: VaultLogin
        var password: String
        var revision = UUID()
    }

    private struct WriteTicket {
        enum Match: Equatable {
            case absent
            case entry(id: String, revision: UUID)
        }

        let id: String
        let origin: String
        let username: String
        let profile: String?
        let match: Match
        let expires: ContinuousClock.Instant
    }

    private let origin: String?
    private let profile: UUID
    private let conditionalLoginWrites: Bool
    private let ticketLifetime: Duration
    private let assertionKey: P256.Signing.PrivateKey?
    private static let credentialID = Base64URL.encode(Data("bark-fixture-passkey".utf8))
    private static let userHandle = Base64URL.encode(Data("bark-fixture-user".utf8))
    private var entries: [StoredLogin]
    private var tickets: [WriteTicket] = []
    private static let ticketLimit = 32

    init(origin: String?, profile: UUID, conditionalLoginWrites: Bool = true, assertionKey: P256.Signing.PrivateKey? = nil,
         logins: [VaultLogin] = [.init(id: "fixture-existing", username: "synthetic-existing",
                                      title: "Synthetic local vault", hasCode: true)],
         ticketLifetime: Duration = .seconds(60)) {
        self.origin = origin
        self.profile = profile
        self.conditionalLoginWrites = conditionalLoginWrites
        self.ticketLifetime = ticketLifetime
        self.assertionKey = assertionKey
        entries = logins.map { StoredLogin(login: $0, password: "fixture-password") }
    }

    func disconnect() async { tickets.removeAll() }

    func send<C: VaultCall>(_ call: C) async throws -> C.Reply {
        try Task.checkCancellation()
        guard let origin else { throw VaultClientError.notRunning }
        if call is VaultCommitLoginWrite {
            Self.record("Bark verification vault: checked commit attempted")
        } else if call is VaultSave {
            Self.record("Bark verification vault: save attempted")
        }
        let reply: (any Sendable)
        switch call {
        case let request as VaultHello where request.profile == nil || matches(request.profile):
            reply = VaultHello.Reply(vault: "Synthetic local vault", version: 1, paired: true, unlocked: true,
                                     capabilities: conditionalLoginWrites ? [VaultPrepareLoginWrite.capability] : nil)
        case let request as VaultLogins where request.origin == origin && matches(request.profile):
            reply = VaultLogins.Reply(logins: entries.map(\.login))
        case let request as VaultPassword where request.origin == origin && matches(request.profile):
            guard let entry = entries.first(where: { $0.login.id == request.id }) else {
                throw VaultClientError.server(.notFound, "")
            }
            Self.record("Bark verification vault: password")
            reply = VaultPassword.Reply(username: entry.login.username, password: entry.password)
        case let request as VaultCode where request.origin == origin && matches(request.profile):
            guard entries.contains(where: { $0.login.id == request.id && $0.login.hasCode }) else {
                throw VaultClientError.server(.notFound, "")
            }
            Self.record("Bark verification vault: code")
            reply = VaultCode.Reply(code: "246810", remaining: 30)
        case let request as VaultSave where !conditionalLoginWrites && request.origin == origin && matches(request.profile):
            let index = entries.firstIndex(where: { $0.login.username == request.username })
            let id = write(username: request.username, password: request.password, index: index)
            Self.record("Bark verification vault: save")
            reply = VaultSave.Reply(saved: true, id: id)
        case let request as VaultPrepareLoginWrite
            where conditionalLoginWrites && request.origin == origin && matches(request.profile):
            reply = prepare(request)
        case let request as VaultCommitLoginWrite where conditionalLoginWrites:
            reply = commit(request)
        case let request as VaultPasskeys where request.rpId == "localhost" && matches(request.profile):
            if let assertionKey, request.allowCredentials.isEmpty || request.allowCredentials.contains(Self.credentialID) {
                // The verifier obtains the enrolled public key outside the website's response.
                Self.record("Bark verification vault: assertion public key " + Base64URL.encode(assertionKey.publicKey.x963Representation))
                reply = VaultPasskeys.Reply(passkeys: [.init(credentialId: Self.credentialID, userName: "synthetic-passkey", title: "Synthetic local vault")])
            } else {
                reply = VaultPasskeys.Reply(passkeys: [])
            }
        case let request as VaultRegister where request.origin == origin && matches(request.profile):
            Self.record("Bark verification vault: register")
            throw VaultClientError.server(.denied, "")
        case let request as VaultAssert where request.origin == origin && matches(request.profile):
            guard let assertionKey, request.rpId == "localhost", request.credentialId == Self.credentialID,
                  request.userVerification == "required", let hash = Base64URL.decode(request.clientDataHash),
                  hash.count == 32, Base64URL.encode(hash) == request.clientDataHash
            else { throw VaultClientError.server(.denied, "") }
            var authData = Data(SHA256.hash(data: Data(request.rpId.utf8)))
            // The fixture simulates presence and verification, with no signature counter.
            authData.append(contentsOf: [0x05, 0, 0, 0, 0])
            let signature = try assertionKey.signature(for: authData + hash)
            Self.record("Bark verification vault: assert")
            reply = VaultAssert.Reply(credentialId: Self.credentialID, authenticatorData: Base64URL.encode(authData),
                                      signature: Base64URL.encode(signature.derRepresentation), userHandle: Self.userHandle)
        default:
            throw VaultClientError.server(.denied, "")
        }
        guard let typed = reply as? C.Reply else { throw VaultClientError.malformedResponse }
        return typed
    }

    private func loginMatch(_ username: String) -> WriteTicket.Match? {
        let matching = entries.filter { $0.login.username.utf8.elementsEqual(username.utf8) }
        switch matching.count {
        case 0: return .absent
        case 1: return .entry(id: matching[0].login.id, revision: matching[0].revision)
        default: return nil
        }
    }

    private func prepare(_ request: VaultPrepareLoginWrite) -> VaultPrepareLoginWrite.Reply {
        guard let match = loginMatch(request.username) else {
            return .init(disposition: .ambiguous, ticket: nil)
        }
        let now = ContinuousClock.now
        tickets.removeAll { $0.expires <= now }
        if tickets.count == Self.ticketLimit { tickets.removeFirst() }
        let id = UUID().uuidString
        tickets.append(.init(id: id, origin: request.origin, username: request.username,
                             profile: request.profile, match: match, expires: now + ticketLifetime))
        return .init(disposition: match == .absent ? .create : .update, ticket: id)
    }

    private func commit(_ request: VaultCommitLoginWrite) -> VaultCommitLoginWrite.Reply {
        guard let index = tickets.firstIndex(where: { $0.id == request.ticket }) else {
            return .init(outcome: .conflict)
        }
        // Spend the ticket before testing the tuple or the revision. Every
        // valid write updates its revision in this synchronous actor turn.
        let ticket = tickets.remove(at: index)
        guard ticket.expires > ContinuousClock.now, ticket.origin == request.origin,
              ticket.profile == request.profile, ticket.username.utf8.elementsEqual(request.username.utf8),
              loginMatch(request.username) == ticket.match else {
            return .init(outcome: .conflict)
        }
        switch ticket.match {
        case .absent:
            _ = write(username: request.username, password: request.password, index: nil)
            Self.record("Bark verification vault: checked create")
        case .entry(let id, let revision):
            guard let target = entries.firstIndex(where: { $0.login.id == id && $0.revision == revision }) else {
                return .init(outcome: .conflict)
            }
            _ = write(username: request.username, password: request.password, index: target)
            Self.record("Bark verification vault: checked update")
        }
        return .init(outcome: .saved)
    }

    private func write(username: String, password: String, index: Int?) -> String {
        if let index {
            entries[index].password = password
            entries[index].revision = UUID()
            return entries[index].login.id
        }
        let id = UUID().uuidString
        entries.append(.init(login: .init(id: id, username: username, title: "Synthetic local vault"),
                             password: password))
        return id
    }

    private func matches(_ requestProfile: String?) -> Bool {
        requestProfile.flatMap(UUID.init(uuidString:)) == profile
    }
}
#endif
