import CryptoKit
import Foundation
import NookSettings

/// Existing app stores with explicit verification destinations. Construct only
/// after Chromium readiness; this does not construct BrowserManager or pages.
@MainActor
final class ChromiumAppStorage {
    let persistence: Persistence
    let defaults: UserDefaults
    let settings: NookSettingsService
    let downloads: DownloadManager
    let tabsDirectory: URL

    init(configuration: ChromiumStartupConfiguration) throws {
        let app = configuration.root.appendingPathComponent("App", isDirectory: true)
        persistence = try Persistence(directory: app)
        // A separate stable preferences domain; never reset or merge the
        // installed app's domain. The root/profile select verification inputs.
        let digest = SHA256.hash(data: Data(configuration.root.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard let isolated = UserDefaults(suiteName: "ee.qdo.nook.chromium-verification." + digest) else {
            throw StorageError.preferencesUnavailable
        }
        defaults = isolated
        settings = NookSettingsService(kagiTokenStore: VerificationKagiTokenStore(), userDefaults: isolated)
        downloads = DownloadManager(historyFileURL: app.appendingPathComponent("Downloads.json"))
        tabsDirectory = app.appendingPathComponent("Tabs", isDirectory: true)
    }

    enum StorageError: Error { case preferencesUnavailable }
}

/// Synthetic credentials remain in memory and never access a Keychain item.
private final class VerificationKagiTokenStore: KagiTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func load() -> String? { lock.withLock { value } }
    func save(_ token: String?) { lock.withLock { value = token } }
}
