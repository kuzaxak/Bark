// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Security
import Sparkle

@MainActor
final class ChromiumAppUpdater: NSObject, @preconcurrency SPUUpdaterDelegate {
    private let configuration: ChromiumUpdateConfiguration
    private let bundle: Bundle
    private var updater: SPUUpdater?

    init(configuration: ChromiumUpdateConfiguration, bundle: Bundle) {
        self.configuration = configuration
        self.bundle = bundle
    }

    static func isSigned(_ bundle: Bundle) -> Bool {
        let flags = SecCSFlags(rawValue: kSecCSBasicValidateOnly).union(.noNetworkAccess)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    func start() {
        guard updater == nil else { return }
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        do {
            try updater.start()
            if configuration.isRehearsal { updater.automaticallyChecksForUpdates = false }
            self.updater = updater
        } catch {
            NSLog("Bark could not start its configured updater.")
        }
    }

    var canCheckForUpdates: Bool {
        guard let updater else { return false }
        return updater.canCheckForUpdates && updater.feedURL == configuration.feed
    }

    func checkForUpdates() {
        guard canCheckForUpdates, let updater else { return }
        updater.checkForUpdates()
    }

    // Choose only the feed sealed in the bundle. Sparkle otherwise prefers
    // deprecated SUFeedURL values in the host's defaults over its Info.plist.
    func feedURLString(for updater: SPUUpdater) -> String? {
        configuration.feed.absoluteString
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updater.feedURL == configuration.feed,
              !configuration.isRehearsal || updateCheck == .updates else {
            throw CocoaError(.userCancelled)
        }
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        configuration.isRehearsal ? [] : nil
    }
}
