// Licensed under GPL-3.0. See LICENSE.

#if os(macOS)
import Foundation
import Testing
@testable import NookWeb

struct VerificationVaultTests {
    private let origin = "http://localhost:12345"
    private let profile = UUID()

    @Test func fixtureAllowsOnlyCanonicalLoopbackOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("VaultFixture.json")
        #expect(try VerificationVault.origin(in: root) == nil)

        func write(_ value: String, to file: URL) throws {
            try JSONEncoder().encode(["origin": value]).write(to: file)
        }
        try write(origin, to: fixture)
        #expect(try VerificationVault.origin(in: root) == origin)
        for invalid in ["https://localhost:12345", "http://example.com:12345", origin + "/",
                        origin + "?key=value", "http://localhost:0", "http://localhost:012345"] {
            try write(invalid, to: fixture)
            #expect(throws: VerificationVault.ConfigurationError.self) {
                try VerificationVault.origin(in: root)
            }
        }
        try FileManager.default.removeItem(at: fixture)
        let other = root.appendingPathComponent("target.json")
        try write(origin, to: other)
        try FileManager.default.createSymbolicLink(at: fixture, withDestinationURL: other)
        #expect(throws: VerificationVault.ConfigurationError.self) {
            try VerificationVault.origin(in: root)
        }
    }

    @Test func checkedWriteWireIsOptionalAndUsesDistinctMethods() async throws {
        let old = try JSONDecoder().decode(VaultHello.Reply.self, from: Data(
            #"{"vault":"Synthetic","version":1,"paired":true,"unlocked":true}"#.utf8))
        #expect(old.capabilities == nil)
        let legacy = VerificationVault(origin: origin, profile: profile, conditionalLoginWrites: false)
        let checked = VerificationVault(origin: origin, profile: profile)
        #expect(try await legacy.send(VaultHello(profile: profile.uuidString)).capabilities == nil)
        #expect(try await checked.send(VaultHello(profile: profile.uuidString)).capabilities ==
                [VaultPrepareLoginWrite.capability])
        #expect(VaultPrepareLoginWrite.method == "prepareLoginWrite")
        #expect(VaultCommitLoginWrite.method == "commitLoginWrite")
        let prepare = VaultPrepareLoginWrite(origin: origin, username: "synthetic", profile: profile.uuidString)
        let commit = VaultCommitLoginWrite(origin: origin, username: prepare.username,
                                           profile: prepare.profile, password: "synthetic", ticket: "ticket")
        func keys(_ value: some Encodable) throws -> Set<String> {
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            return Set(object.keys)
        }
        #expect(try keys(prepare) == ["origin", "username", "profile"])
        #expect(try keys(commit) == ["origin", "username", "profile", "password", "ticket"])
        let reply = try JSONDecoder().decode(VaultPrepareLoginWrite.Reply.self, from: Data(
            #"{"disposition":"ambiguous"}"#.utf8))
        #expect(reply.disposition == .ambiguous && reply.ticket == nil)
        await #expect(throws: VaultClientError.server(.denied, "")) {
            try await legacy.send(prepare)
        }
        await #expect(throws: VaultClientError.server(.denied, "")) {
            try await checked.send(VaultSave(origin: origin, username: "synthetic",
                                             password: "fixture", profile: profile.uuidString))
        }
    }

    @Test func fixtureCanOptIntoLegacyWireBehavior() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("VaultFixture.json")
        try Data(#"{"origin":"http://localhost:12345"}"#.utf8).write(to: fixture)
        #expect(try VerificationVault.configuration(in: root)?.conditionalLoginWrites == nil)
        try Data(#"{"origin":"http://localhost:12345","conditionalLoginWrites":false}"#.utf8).write(to: fixture)
        #expect(try VerificationVault.configuration(in: root)?.conditionalLoginWrites == false)
        try Data(#"{"origin":"http://localhost:12345","conditionalLoginWrites":"false"}"#.utf8).write(to: fixture)
        #expect(throws: DecodingError.self) { try VerificationVault.configuration(in: root) }
    }

    @Test func checkedCreateAndUpdateRejectInterveningChanges() async throws {
        let fixture = VerificationVault(origin: origin, profile: profile, conditionalLoginWrites: true)
        let username = "synthetic-new"
        let profileID = profile.uuidString
        let request = VaultPrepareLoginWrite(origin: origin, username: username, profile: profileID)
        func prepare(_ disposition: VaultPrepareLoginWrite.Disposition) async throws -> String {
            let reply = try await fixture.send(request)
            #expect(reply.disposition == disposition)
            return try #require(reply.ticket?.isEmpty == false ? reply.ticket : nil)
        }
        func commit(_ ticket: String, _ password: String) async throws -> VaultCommitLoginWrite.Outcome {
            try await fixture.send(VaultCommitLoginWrite(origin: origin, username: username, profile: profileID,
                                                         password: password, ticket: ticket)).outcome
        }

        let abandonedCreate = try await prepare(.create)
        let acceptedCreate = try await prepare(.create)
        #expect(try await commit(acceptedCreate, "first") == .saved)
        #expect(try await commit(abandonedCreate, "stale") == .conflict)
        #expect(try await commit(acceptedCreate, "replay") == .conflict)
        let created = try await fixture.send(VaultLogins(origin: origin, profile: profileID))
        let entry = try #require(created.logins.first { $0.username == username })
        #expect(created.logins.filter { $0.username == username }.count == 1)

        let abandonedUpdate = try await prepare(.update)
        let acceptedUpdate = try await prepare(.update)
        #expect(try await commit(acceptedUpdate, "newer") == .saved)
        #expect(try await commit(abandonedUpdate, "stale") == .conflict)
        #expect(try await commit(acceptedUpdate, "replay") == .conflict)
        let updated = try await fixture.send(VaultLogins(origin: origin, profile: profileID))
        #expect(updated.logins == created.logins)
        #expect(try await fixture.send(VaultPassword(id: entry.id, origin: origin,
                                                     profile: profileID)).password == "newer")
    }

    @Test func checkedTicketsAreScopedAndInvalidateOnMisuse() async throws {
        let fixture = VerificationVault(origin: origin, profile: profile, conditionalLoginWrites: true)
        let other = VerificationVault(origin: origin, profile: profile, conditionalLoginWrites: true)
        let username = "synthetic-existing"
        let profileID = profile.uuidString
        let prepare = VaultPrepareLoginWrite(origin: origin, username: username, profile: profileID)
        let issued = try await fixture.send(prepare)
        let ticket = try #require(issued.ticket)
        let original = VaultCommitLoginWrite(origin: origin, username: username, profile: profileID,
                                              password: "modified", ticket: ticket)
        #expect(try await other.send(original).outcome == .conflict)

        for (wrongOrigin, wrongUsername, wrongProfile) in [
            (origin + "/", username, profileID), (origin, "different", profileID),
            (origin, username, UUID().uuidString),
        ] {
            let issued = try await fixture.send(prepare)
            let ticket = try #require(issued.ticket)
            #expect(try await fixture.send(VaultCommitLoginWrite(origin: wrongOrigin, username: wrongUsername,
                                                                profile: wrongProfile, password: "modified",
                                                                ticket: ticket)).outcome == .conflict)
            #expect(try await fixture.send(VaultCommitLoginWrite(origin: origin, username: username, profile: profileID,
                                                                password: "modified", ticket: ticket)).outcome == .conflict)
        }
        #expect(try await fixture.send(VaultPassword(id: "fixture-existing", origin: origin,
                                                     profile: profileID)).password == "fixture-password")
        await fixture.disconnect()
        #expect(try await fixture.send(original).outcome == .conflict)
    }

    @Test func checkedPreparationRefusesAmbiguityAndExpiresAbandonedTickets() async throws {
        let username = "synthetic-duplicate"
        let logins = ["first", "second"].map { VaultLogin(id: $0, username: username, title: "Synthetic") }
        let ambiguous = VerificationVault(origin: origin, profile: profile,
                                          conditionalLoginWrites: true, logins: logins)
        let profileID = profile.uuidString
        let request = VaultPrepareLoginWrite(origin: origin, username: username, profile: profileID)
        let answer = try await ambiguous.send(request)
        #expect(answer.disposition == .ambiguous && answer.ticket == nil)

        let expiring = VerificationVault(origin: origin, profile: profile,
                                         conditionalLoginWrites: true, ticketLifetime: .zero)
        let expired = try await expiring.send(request)
        let ticket = try #require(expired.ticket)
        #expect(try await expiring.send(VaultCommitLoginWrite(origin: origin, username: username,
                                                             profile: profileID, password: "fixture",
                                                             ticket: ticket)).outcome == .conflict)

        let bounded = VerificationVault(origin: origin, profile: profile)
        let oldest = try await bounded.send(request)
        let oldestTicket = try #require(oldest.ticket)
        for _ in 0..<32 { _ = try await bounded.send(request) }
        #expect(try await bounded.send(VaultCommitLoginWrite(origin: origin, username: username,
                                                             profile: profileID, password: "fixture",
                                                             ticket: oldestTicket)).outcome == .conflict)
    }

    @Test func saveAndReadBackRequireExactOriginAndProfile() async throws {
        let fixture = VerificationVault(origin: origin, profile: profile, conditionalLoginWrites: false)
        let profileID = profile.uuidString
        let save = VaultSave(origin: origin, username: "synthetic-new", password: "disposable",
                             profile: profileID)
        let saved = try await fixture.send(save)
        #expect(saved.saved)
        let matches = try await fixture.send(VaultLogins(origin: origin, profile: profileID))
        #expect(matches.logins.map(\.username) == ["synthetic-existing", "synthetic-new"])
        let retrieved = try await fixture.send(VaultPassword(id: saved.id, origin: origin,
                                                             profile: profileID))
        #expect(retrieved.password == "disposable")
        for request in [
            VaultPassword(id: saved.id, origin: origin, profile: nil),
            VaultPassword(id: saved.id, origin: origin, profile: UUID().uuidString),
            VaultPassword(id: saved.id, origin: "http://localhost:12346", profile: profileID),
        ] {
            await #expect(throws: VaultClientError.server(.denied, "")) {
                try await fixture.send(request)
            }
        }
        let nextSession = VerificationVault(origin: origin, profile: profile)
        let nextMatches = try await nextSession.send(VaultLogins(origin: origin, profile: profileID))
        #expect(nextMatches.logins.map(\.username) == ["synthetic-existing"])
    }

    @Test func onlyTheCodeEntryInTheFixtureProfileAndOriginCanReturnACode() async throws {
        let fixture = VerificationVault(origin: origin, profile: profile, conditionalLoginWrites: false)
        let profileID = profile.uuidString
        let saved = try await fixture.send(VaultSave(origin: origin, username: "no-code", password: "fixture",
                                                     profile: profileID))
        let logins = try await fixture.send(VaultLogins(origin: origin, profile: profileID)).logins
        #expect(logins.filter(\.hasCode).map(\.id) == ["fixture-existing"])
        let call = VaultCode(id: "fixture-existing", origin: origin, profile: profileID)
        let reply = try await fixture.send(call)
        #expect(reply.code == "246810" && reply.remaining > 0)
        for id in [saved.id, "missing"] {
            await #expect(throws: VaultClientError.server(.notFound, "")) {
                try await fixture.send(VaultCode(id: id, origin: origin, profile: profileID))
            }
        }
        for denied in [VaultCode(id: call.id, origin: origin, profile: nil),
                       VaultCode(id: call.id, origin: origin, profile: UUID().uuidString),
                       VaultCode(id: call.id, origin: "http://localhost:12346", profile: profileID)] {
            await #expect(throws: VaultClientError.server(.denied, "")) { try await fixture.send(denied) }
        }
    }

    @Test func fixtureCannotPerformPasskeyRegistration() async {
        let fixture = VerificationVault(origin: origin, profile: profile)
        let request = VaultRegister(rpId: "localhost", rpName: "Fixture",
                                    user: .init(id: "test", name: "test", displayName: "Test"),
                                    clientDataHash: "", pubKeyCredParams: [-7], excludeCredentials: [],
                                    origin: origin, profile: profile.uuidString)
        await #expect(throws: VaultClientError.server(.denied, "")) {
            try await fixture.send(request)
        }
    }

    @Test func disposableProfileWithoutFixtureHasNoVault() async {
        let fixture = VerificationVault(origin: nil, profile: profile)
        await #expect(throws: VaultClientError.notRunning) {
            try await fixture.send(VaultHello(profile: profile.uuidString))
        }
    }
}
#endif
