// Licensed under GPL-3.0. See LICENSE.
import Foundation
import OSLog
import WebKit

/// Owns a profile's WebKit website data and persistent session-cookie backup.
@MainActor
public final class WebKitProfileStorage: NSObject, WKHTTPCookieStoreObserver {
    public let dataStore: WKWebsiteDataStore

    /// Creates a WebKit profile with the caller's store and no session-cookie backup.
    public static func makeProfile(id: UUID = UUID(), name: String, icon: String,
                                   dataStore: WKWebsiteDataStore) -> Profile {
        Profile(id: id, name: name, icon: icon, engine: .webKit, storage: Self(dataStore: dataStore))
    }

    static func ephemeral() -> WebKitProfileStorage {
        Self(dataStore: .nonPersistent())
    }
    private let persistentID: UUID?
    private var sessionCookieSave: Task<Void, Never>?
    private var savedSessionCookies: Data?

    init(persistentID: UUID) {
        self.persistentID = persistentID
        dataStore = WKWebsiteDataStore(forIdentifier: persistentID)
        super.init()
        restoreSessionCookies()
        dataStore.httpCookieStore.add(self)
    }

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        self.persistentID = nil
        super.init()
    }

    func dataCounts() async -> (cookies: Int, records: Int) {
        let cookies = await dataStore.httpCookieStore.allCookies()
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeServiceWorkerRegistrations,
        ]
        let records = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0.count) }
        }
        return (cookies.count, records)
    }

    func clearAllData() async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }

    func destroyEphemeralDataStore(completion: (() -> Void)?) {
        let dataStore = dataStore
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            let cookieStore = dataStore.httpCookieStore
            cookieStore.getAllCookies { cookies in
                for cookie in cookies { cookieStore.delete(cookie) }
                completion?()
            }
        }
    }

    private var sessionCookiesURL: URL? {
        guard let persistentID else { return nil }
        return TabsController.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("SessionCookies", isDirectory: true)
            .appendingPathComponent("\(persistentID.uuidString).plist")
    }

    /// Queued on the store's connection ahead of any load, so the first page already sends them.
    private func restoreSessionCookies() {
        guard let url = sessionCookiesURL, let data = try? Data(contentsOf: url),
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
        guard let url = sessionCookiesURL else { return }
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
