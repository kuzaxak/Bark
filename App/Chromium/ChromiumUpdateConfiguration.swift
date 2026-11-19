// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// The signed bundle opt-in that survives Sparkle's argument-free relaunch.
struct ChromiumUpdateRehearsal {
    private static let prefix = "ee.qdo.bark.test."
    let root: String
    let profile: UUID

    static func read(identifier: String?, info: [String: Any]) throws -> Self? {
        let identifier = identifier ?? ""
        let metadata = info["BarkUpdateRehearsal"]
        guard metadata != nil || identifier.hasPrefix(prefix) else { return nil }
        guard identifier.hasPrefix(prefix), UUID(uuidString: String(identifier.dropFirst(prefix.count))) != nil,
              let values = metadata as? [String: Any], let root = values["DataRoot"] as? String,
              root.hasPrefix("/private/tmp/"),
              let profile = (values["Profile"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw ChromiumStartupConfiguration.StartupError.invalidConfiguration
        }
        return Self(root: root, profile: profile)
    }
}

struct ChromiumUpdateConfiguration {
    #if arch(arm64)
    static let rehearsalFeedPath = "/bark-macos-arm64.xml"
    private static let otherArchitectureFeed = "bark-macos-x86_64.xml"
    #else
    static let rehearsalFeedPath = "/bark-macos-x86_64.xml"
    private static let otherArchitectureFeed = "bark-macos-arm64.xml"
    #endif

    let feed: URL
    let isRehearsal: Bool

    init?(info: [String: Any], isVerification: Bool, isRehearsal: Bool) {
        guard isVerification == isRehearsal,
              let rawFeed = info["SUFeedURL"] as? String,
              let components = URLComponents(string: rawFeed), let feed = components.url,
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        if isRehearsal {
            guard components.scheme == "http", host == "127.0.0.1",
                  let port = components.port, (1...65535).contains(port),
                  components.percentEncodedPath == Self.rehearsalFeedPath,
                  components.query == nil, info["SUEnableAutomaticChecks"] as? Bool == false else { return nil }
        } else {
            // Existing Nook installations own this feed and share Bark's update signing key.
            let isNookFeed = host.lowercased() == "github.com" &&
                feed.standardized.path.lowercased().hasPrefix("/kuzaxak/nook/releases/") &&
                feed.lastPathComponent == "appcast.xml"
            guard components.scheme == "https", !isNookFeed,
                  feed.lastPathComponent != Self.otherArchitectureFeed else { return nil }
        }
        self.feed = feed
        self.isRehearsal = isRehearsal
    }
}
