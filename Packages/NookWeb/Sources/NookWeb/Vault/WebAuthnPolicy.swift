// Licensed under GPL-3.0. See LICENSE.

/// Origin admission for Pawl requests received through the Chromium SDK.
public enum WebAuthnPolicy {
    /// HTTPS, or HTTP on `localhost` and `127.0.0.1` only.
    public static func isAllowedOrigin(scheme: String, host: String) -> Bool {
        let host = host.lowercased()
        switch scheme.lowercased() {
        case "https": return !host.isEmpty
        case "http": return host == "localhost" || host == "127.0.0.1"
        default: return false
        }
    }
}
