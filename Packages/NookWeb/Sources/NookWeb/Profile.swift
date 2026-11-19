// Licensed under GPL-3.0. See LICENSE.
//
//  Profile.swift
//  Nook
//
//  The login-context identity shared by spaces using the same profile UUID.
//  WebKit profiles own their website data store; Chromium resolves the identity
//  through its native ProfileManager. Private metadata does not create a runtime
//  session: the owning browser must open and dispose that engine's private session.
//

import Foundation
import Observation

@MainActor
@Observable
public final class Profile: NSObject, Identifiable {
    public let id: UUID
    public var name: String
    public var icon: String
    public enum Engine: Sendable {
        case webKit
        case chromium
    }

    public let engine: Engine
    /// The WebKit adapter, available only for profiles backed by a WebKit store.
    @ObservationIgnored public let webKitStorage: WebKitProfileStorage?
    // Metadata (not yet persisted)
    public var createdDate: Date = Date()
    public var lastUsed: Date = Date()
    public var isDefault: Bool { name.lowercased() == "default" }
    
    /// Whether this is an ephemeral/incognito profile (no disk persistence)
    public var isEphemeral: Bool = false
    
    public convenience init(
        id: UUID = UUID(),
        name: String = "Default Profile",
        icon: String = "person.crop.circle",
        engine: Engine = .chromium
    ) {
        // Only WebKit opens a data store or reads the saved session cookies.
        self.init(id: id, name: name, icon: icon, engine: engine,
                  storage: engine == .webKit ? WebKitProfileStorage(persistentID: id) : nil)
    }

    init(id: UUID, name: String, icon: String, engine: Engine, storage: WebKitProfileStorage?) {
        self.id = id
        self.name = name
        self.icon = icon
        self.engine = engine
        self.webKitStorage = storage
        super.init()
    }

    // MARK: - Ephemeral Profile Factory
    /// Create a private profile identity. The Chromium host opens the private session.
    public static func createEphemeral(id: UUID = UUID(), engine: Engine = .chromium) -> Profile {
        let profile: Profile
        switch engine {
        case .webKit:
            profile = Profile(id: id, name: "Incognito", icon: "eye.slash", engine: .webKit,
                              storage: WebKitProfileStorage.ephemeral())
        case .chromium:
            // Identity only. The caller must open/close the real native private
            // session; metadata creation never simulates runtime isolation.
            profile = Profile(id: id, name: "Incognito", icon: "eye.slash", engine: .chromium)
        }
        profile.isEphemeral = true
        return profile
    }

    /// Clears a WebKit private store. Native private sessions are ended by their owning browser.
    public func destroyEphemeralDataStore(completion: (() -> Void)? = nil) {
        guard isEphemeral, let webKitStorage else {
            completion?()
            return
        }
        webKitStorage.destroyEphemeralDataStore(completion: completion)
    }
}
