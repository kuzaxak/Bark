// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Observation
import Security
import Sparkle
import SwiftUI

@MainActor
@Observable
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

    @ViewBuilder var automaticUpdateControls: some View {
        if !configuration.isRehearsal, let updater {
            ChromiumAutomaticUpdateControls(updater: updater,
                allowsDownloads: (bundle.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? NSNumber)?.boolValue ?? true)
        }
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

@MainActor
private struct ChromiumAutomaticUpdateControls: View {
    let updater: SPUUpdater
    let allowsDownloads: Bool
    @State private var checks: Bool
    @State private var downloads: Bool

    init(updater: SPUUpdater, allowsDownloads: Bool) {
        self.updater = updater
        self.allowsDownloads = allowsDownloads
        _checks = State(initialValue: updater.automaticallyChecksForUpdates)
        _downloads = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        Toggle("Check for updates automatically", isOn: Binding(
            get: { checks }, set: { updater.automaticallyChecksForUpdates = $0 }))
            .onReceive(updater.publisher(for: \.automaticallyChecksForUpdates)) { checks = $0 }
        if allowsDownloads {
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { downloads }, set: { updater.automaticallyDownloadsUpdates = $0 }))
                .disabled(!checks)
                .onReceive(updater.publisher(for: \.automaticallyDownloadsUpdates)) { downloads = $0 }
        }
    }
}
