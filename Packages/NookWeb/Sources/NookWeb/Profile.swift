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
import WebKit
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
    @ObservationIgnored private let webKitStorage: WebKitProfileStorage?
    // Metadata (not yet persisted)
    public var createdDate: Date = Date()
    public var lastUsed: Date = Date()
    public var isDefault: Bool { name.lowercased() == "default" }
    
    /// Whether this is an ephemeral/incognito profile (no disk persistence)
    public var isEphemeral: Bool = false
    
    // Cached stats
    public private(set) var cachedCookieCount: Int = 0
    public private(set) var cachedRecordCount: Int = 0
    public var estimatedDataSize: String { "Cookies: \(cachedCookieCount), Records: \(cachedRecordCount)" }
    public var cookieCount: Int { cachedCookieCount }
    public var hasStoredData: Bool { cachedCookieCount > 0 || cachedRecordCount > 0 }

    public convenience init(
        id: UUID = UUID(),
        name: String = "Default Profile",
        icon: String = "person.crop.circle",
        engine: Engine = .webKit
    ) {
        // Only WebKit opens a data store or reads the saved session cookies.
        self.init(id: id, name: name, icon: icon, engine: engine,
                  storage: engine == .webKit ? WebKitProfileStorage(persistentID: id) : nil)
    }

    private init(id: UUID, name: String, icon: String, engine: Engine, storage: WebKitProfileStorage?) {
        self.id = id
        self.name = name
        self.icon = icon
        self.engine = engine
        self.webKitStorage = storage
        super.init()
    }

    // MARK: - Ephemeral Profile Factory
    /// Create a new ephemeral/incognito profile with non-persistent data store
    public static func createEphemeral(id: UUID = UUID(), engine: Engine = .webKit) -> Profile {
        let profile: Profile
        switch engine {
        case .webKit:
            profile = Profile(id: id, name: "Incognito", icon: "eye.slash", dataStore: .nonPersistent())
        case .chromium:
            // Identity only. The caller must open/close the real native private
            // session; metadata creation never simulates runtime isolation.
            profile = Profile(id: id, name: "Incognito", icon: "eye.slash", engine: .chromium)
        }
        profile.isEphemeral = true
        return profile
    }

    // MARK: - Validation & Stats
    public func validateDataStore() async -> Bool {
        // Basic check: store exists and is persistent
        guard let dataStore = webKitDataStore, dataStore.isPersistent else { return false }
        await refreshDataStoreStats()
        return true
    }

    /// Refreshes WebKit website-data stats when this profile has a WebKit store.
    public func refreshDataStoreStats() async {
        guard let webKitStorage else { return }
        let counts = await webKitStorage.dataCounts()
        cachedCookieCount = counts.cookies
        cachedRecordCount = counts.records
    }

    /// Clears WebKit data only. Chromium clearing is an engine operation.
    @discardableResult
    public func clearAllData() async -> Bool {
        guard let webKitStorage else { return false }
        await webKitStorage.clearAllData()
        await refreshDataStoreStats()
        return true
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

// MARK: - WebKit storage capability

extension Profile {
    /// Chromium owns its data through the native ProfileManager.
    public var webKitDataStore: WKWebsiteDataStore? { webKitStorage?.dataStore }

    /// Uses the caller's WebKit store without persistent session-cookie backup.
    public convenience init(id: UUID = UUID(), name: String, icon: String, dataStore: WKWebsiteDataStore) {
        self.init(id: id, name: name, icon: icon, engine: .webKit,
                  storage: WebKitProfileStorage(dataStore: dataStore))
    }
}
