// Licensed under GPL-3.0. See LICENSE.
//
//  KagiSession.swift
//  Nook
//
//  Kagi's Session Link token, kept in the Keychain and added to Kagi searches so every space is
//  signed in without its own Kagi cookie.
//

import Foundation
import Security

public protocol KagiTokenStore: Sendable {
    func load() -> String?
    func save(_ token: String?)
}

public struct KeychainKagiTokenStore: KagiTokenStore {
    private let service: String?
    /// Uses Bark’s existing service unless a caller supplies its own service.
    public init(service: String? = nil) { self.service = service }
    public func load() -> String? { KagiSession.loadToken(service: service) }
    public func save(_ token: String?) { KagiSession.saveToken(token, service: service) }
}

public enum KagiSession {
    private static let service = "NookChromium Kagi Session Link"
    private static let account = "token"

    /// The token from a pasted Session Link (`https://kagi.com/search?token=…&q=%s`) or a bare token.
    public static func token(fromPasted text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains("://") else { return trimmed.contains(" ") ? nil : trimmed }
        let token = URLComponents(string: trimmed)?.queryItems?.first { $0.name == "token" }?.value
        return token?.isEmpty == false ? token : nil
    }

    /// Kagi's search address carrying `token`, with `%@` for the query.
    public static func searchTemplate(token: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/?")
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        return "https://kagi.com/search?token=\(encoded)&q=%@"
    }

    /// `url` without a Kagi token, for anything that stores or shows an address.
    public static func withoutToken(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host == "kagi.com" || host.hasSuffix(".kagi.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, items.contains(where: { $0.name == "token" }) else { return url }
        let kept = items.filter { $0.name != "token" }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    // MARK: - Keychain

    public static func loadToken(service: String? = nil) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `token`, or removes it when nil.
    public static func saveToken(_ token: String?, service: String? = nil) {
        SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return }
        var item = baseQuery(service: service)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func baseQuery(service override: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: override ?? service, kSecAttrAccount as String: account]
    }
}
