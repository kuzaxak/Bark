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
import OSLog

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
    @ObservationIgnored private let storedWebKitDataStore: WKWebsiteDataStore?
    /// Capability access for WebKit-only services. Chromium owns its website
    /// data through the native ProfileManager and never creates a WK store.
    public var webKitDataStore: WKWebsiteDataStore? { storedWebKitDataStore }
    /// Legacy WebKit features must explicitly check the capability before use.
    public var dataStore: WKWebsiteDataStore {
        guard let store = storedWebKitDataStore else {
            preconditionFailure("WebKit storage is unavailable for a Chromium profile")
        }
        return store
    }
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

    @ObservationIgnored private var sessionCookieSave: Task<Void, Never>?
    @ObservationIgnored private var savedSessionCookies: Data?

    public init(
        id: UUID = UUID(),
        name: String = "Default Profile",
        icon: String = "person.crop.circle",
        engine: Engine = .webKit
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.engine = engine
        // Only WebKit opens a data store or reads the saved session cookies.
        self.storedWebKitDataStore = engine == .webKit
            ? WKWebsiteDataStore(forIdentifier: id) : nil
        super.init()
        if let dataStore = storedWebKitDataStore {
            restoreSessionCookies()
            dataStore.httpCookieStore.add(self)
        }
    }

    /// Initialize with a custom data store (used for ephemeral profiles)
    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        dataStore: WKWebsiteDataStore
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.engine = .webKit
        self.storedWebKitDataStore = dataStore
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

    @MainActor
    public func refreshDataStoreStats() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            dataStore.httpCookieStore.getAllCookies { cookies in
                self.cachedCookieCount = cookies.count
                cont.resume()
            }
        }
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeFetchCache,
            WKWebsiteDataTypeServiceWorkerRegistrations
        ]
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.dataStore.fetchDataRecords(ofTypes: types) { records in
                self.cachedRecordCount = records.count
                cont.resume()
            }
        }
    }

    // MARK: - Cleanup
    public func clearAllData() async {
        // Everything WebKit supports, not a hand-written list: the old one missed session
        // storage, WebSQL and the origin-private filesystem, which survived "clear all data".
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) {
                cont.resume()
            }
        }
        await refreshDataStoreStats()
    }
    
    /// Destroys the ephemeral data store by clearing all data.
    /// This should be called before releasing an ephemeral profile to ensure
    /// all incognito data is wiped and the store can be properly deallocated.
    /// - Parameter completion: Optional completion handler called when destruction is complete
    public func destroyEphemeralDataStore(completion: (() -> Void)? = nil) {
        guard isEphemeral else {
            completion?()
            return
        }
        
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        
        // Clear all data from the store
        dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            
            // Also clear cookies specifically
            self.dataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies {
                    self.dataStore.httpCookieStore.delete(cookie)
                }
                
                completion?()
            }
        }
    }
}

// MARK: - Session Cookies

/// WebKit keeps cookies without an expiry in memory only, so a relaunch signed people out of
/// sites like App Store Connect. Each space saves its session cookies on change and restores them
/// before its first page loads, as Chrome does with session restore.
extension Profile: WKHTTPCookieStoreObserver {
    private var sessionCookiesURL: URL {
        TabsController.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("SessionCookies", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).plist")
    }

    /// Queued on the store's connection ahead of any load, so the first page already sends them.
    fileprivate func restoreSessionCookies() {
        guard let dataStore = webKitDataStore else { return }
        guard let data = try? Data(contentsOf: sessionCookiesURL),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return }
        savedSessionCookies = data
        for properties in list {
            let keyed = Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            if let cookie = HTTPCookie(properties: keyed) {
                dataStore.httpCookieStore.setCookie(cookie)
            }
        }
    }

    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard webKitDataStore != nil else { return }
        sessionCookieSave?.cancel()
        sessionCookieSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let cookies = await self.dataStore.httpCookieStore.allCookies()
            guard !Task.isCancelled else { return }
            self.writeSessionCookies(cookies.filter(\.isSessionOnly))
        }
    }

    private func writeSessionCookies(_ cookies: [HTTPCookie]) {
        let url = sessionCookiesURL
        guard !cookies.isEmpty else {
            if savedSessionCookies != nil { try? FileManager.default.removeItem(at: url) }
            savedSessionCookies = nil
            return
        }
        let list = cookies.compactMap { cookie in
            cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0),
              data != savedSessionCookies
        else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            // Login tokens: owner only.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            savedSessionCookies = data
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Tabs")
                .error("Saving session cookies failed: \(String(describing: error), privacy: .public)")
        }
    }
}
