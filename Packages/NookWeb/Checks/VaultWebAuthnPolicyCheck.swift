// Licensed under GPL-3.0. See LICENSE.

@main
struct VaultWebAuthnPolicyCheck {
    static func main() {
        precondition(WebAuthnPolicy.isAllowedOrigin(scheme: "https", host: "example.com"))
        precondition(WebAuthnPolicy.isAllowedOrigin(scheme: "http", host: "localhost"))
        precondition(WebAuthnPolicy.isAllowedOrigin(scheme: "http", host: "127.0.0.1"))
        for (scheme, host) in [("http", "example.com"), ("http", "app.localhost"), ("http", "127.0.0.2"),
                               ("file", ""), ("ftp", "example.com"), ("https", ""), ("about", "")] {
            precondition(!WebAuthnPolicy.isAllowedOrigin(scheme: scheme, host: host), "\(scheme)://\(host)")
        }
    }
}
