import Foundation
import NookSettings
import NookWeb

/// App-owned native stores with explicit isolated verification destinations. Construct only
/// after Chromium readiness; this does not construct BrowserManager or pages.
@MainActor
final class ChromiumAppStorage {
    let persistence: Persistence
    let defaults: UserDefaults
    let settings: NookSettingsService
    let downloads: DownloadManager
    let devMCP: DevMCPConfiguration
    let tabsDirectory: URL
    let aiConfig: AIConfigService
    let vault: VaultService?

    init(configuration: ChromiumStartupConfiguration) throws {
        let app = configuration.root.appendingPathComponent("App", isDirectory: true)
        persistence = try Persistence(directory: app)
        // A separate stable preferences domain; never reset or merge the
        // installed app's domain. The root/profile select verification inputs.
        guard let isolated = UserDefaults(suiteName: configuration.preferencesDomain) else {
            throw StorageError.preferencesUnavailable
        }
        defaults = isolated
        let port = configuration.isVerification ? isolated.string(forKey: "NookDevMCPPort").flatMap(UInt16.init) : nil
        devMCP = try DevMCPConfiguration.native(appRoot: app, port: port ?? 47823)
        let tokens: any KagiTokenStore = configuration.isVerification
            ? VerificationKagiTokenStore() : KeychainKagiTokenStore(service: "NookChromium Kagi Session Link")
        settings = NookSettingsService(kagiTokenStore: tokens, userDefaults: isolated,
                                       boostStore: BoostStore(fileURL: app.appendingPathComponent("Boosts.json")),
                                       keepsSidebarLeft: true)
        if configuration.isVerification {
            guard let profile = configuration.profileID else { throw StorageError.missingVerificationProfile }
            vault = try VaultService(verificationSettings: settings, root: configuration.root, profile: profile)
        } else {
            vault = nil
        }
        downloads = DownloadManager(historyFileURL: app.appendingPathComponent("Downloads.json"), usesNativeDownloads: true)
        tabsDirectory = app.appendingPathComponent("Tabs", isDirectory: true)
        aiConfig = AIConfigService(configURL: configuration.aiConfigURL,
                                   keychainService: configuration.aiKeychainService,
                                   migratesLegacySettings: false)
    }

    enum StorageError: Error { case preferencesUnavailable, missingVerificationProfile }
}

/// Synthetic credentials remain in memory and never access a Keychain item.
private final class VerificationKagiTokenStore: KagiTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func load() -> String? { lock.withLock { value } }
    func save(_ token: String?) { lock.withLock { value = token } }
}
