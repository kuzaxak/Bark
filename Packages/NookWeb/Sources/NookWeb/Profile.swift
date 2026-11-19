// Licensed under GPL-3.0. See LICENSE.
//
//  Profile.swift
//  Nook
//
//  The login-context identity shared by spaces using the same profile UUID.
//  Chromium owns each native profile and the browser owns private-session lifetime.
//

import Foundation
import Observation

@MainActor
@Observable
public final class Profile: NSObject, Identifiable {
    public let id: UUID
    public var name: String
    public var icon: String
    // Metadata (not yet persisted)
    public var createdDate: Date = Date()
    public var lastUsed: Date = Date()
    public var isDefault: Bool { name.lowercased() == "default" }
    
    /// Whether this is an ephemeral/incognito profile (no disk persistence)
    public var isEphemeral: Bool = false
    
    public init(
        id: UUID = UUID(),
        name: String = "Default Profile",
        icon: String = "person.crop.circle"
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        super.init()
    }

    // MARK: - Ephemeral Profile Factory
    /// Create a private profile identity. The Chromium host opens the private session.
    public static func createEphemeral(id: UUID = UUID()) -> Profile {
        let profile = Profile(id: id, name: "Incognito", icon: "eye.slash")
        profile.isEphemeral = true
        return profile
    }
}
