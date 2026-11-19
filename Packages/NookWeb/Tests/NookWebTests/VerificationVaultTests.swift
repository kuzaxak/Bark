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

    @Test func saveAndReadBackRequireExactOriginAndProfile() async throws {
        let fixture = VerificationVault(origin: origin, profile: profile)
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
        let fixture = VerificationVault(origin: origin, profile: profile)
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
