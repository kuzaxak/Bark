// Licensed under GPL-3.0. See LICENSE.
//
//  ImportManager.swift
//  Nook
//
//  Created by Maciek Bagiński on 29/09/2025.
//

import Foundation
import Combine
import SwiftUI

/// The browsers Bark imports from itself.
enum ImportBrowser: String, CaseIterable {
    case arc, chrome

    var name: String {
        switch self {
        case .arc: "Arc"
        case .chrome: "Chrome"
        }
    }
}

class ImportManager: ObservableObject {
    /// Where Arc, Chrome and Dia keep the data an import reads.
    struct Sources {
        /// Arc's Application Support folder.
        let arc: URL
        /// Chrome's user data folder: its `Local State` and one folder per profile.
        let chrome: URL
        /// Dia's `StorableProfileContainers.json`.
        let dia: URL

        static let installed = Sources(
            arc: URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Arc").expandingTildeInPath),
            chrome: URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Google/Chrome").expandingTildeInPath),
            dia: URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Dia/StorableProfileContainers.json").expandingTildeInPath))

        /// Copies laid out under a verification run's data directory, in place of the person's own.
        static func fixtures(in root: URL) -> Sources {
            let imports = root.appendingPathComponent("Import", isDirectory: true)
            return Sources(arc: imports.appendingPathComponent("Arc", isDirectory: true),
                           chrome: imports.appendingPathComponent("Chrome", isDirectory: true),
                           dia: imports.appendingPathComponent("Dia/StorableProfileContainers.json"))
        }
    }

    let sources: Sources
    /// Where a browser's locked files are copied to be read. A copy left by a run that quit
    /// mid-import goes when the next ImportManager starts.
    let workDirectory: URL

    init(sources: Sources, workDirectory: URL) {
        self.sources = sources
        self.workDirectory = workDirectory
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// A verification run reads only the copies laid out under its own data directory.
    convenience init(configuration: ChromiumStartupConfiguration) {
        self.init(sources: configuration.isVerification ? .fixtures(in: configuration.root) : .installed,
                  workDirectory: configuration.root.appendingPathComponent("App/ImportCopies", isDirectory: true))
    }

    func importArcSidebarData() async -> ArcImportResult {
        guard let data = try? Data(contentsOf: arcDirectory.appendingPathComponent("StorableSidebar.json")),
              var result = try? parseArcSidebarData(data) else { return ArcImportResult() }
        for profile in chromiumProfiles(.arc).found {
            result.profileNames[Self.arcProfileKey(profile.directory)] = profile.name
        }
        return result
    }

    /// Arc's sidebar names its first profile "default" and the others by folder.
    static func arcProfileKey(_ directory: String) -> String { directory == "Default" ? "default" : directory }
    static func arcProfileDirectory(_ key: String) -> String { key == "default" ? "Default" : key }

    /// The folder holding a Chromium browser's `Local State` and profile folders.
    func userDataDirectory(_ browser: ImportBrowser) -> URL {
        switch browser {
        case .arc: arcDirectory.appendingPathComponent("User Data", isDirectory: true)
        case .chrome: sources.chrome
        }
    }

    /// A profile's folder; nil for a name that is not one folder inside the user data folder.
    func profileDirectory(_ browser: ImportBrowser, _ directory: String) -> URL? {
        isFolderName(directory) ? userDataDirectory(browser).appendingPathComponent(directory, isDirectory: true) : nil
    }

    /// Whether the browser is on this Mac: Chromium writes `Local State` on its first launch.
    func isInstalled(_ browser: ImportBrowser) -> Bool {
        FileManager.default.fileExists(atPath: userDataDirectory(browser).appendingPathComponent("Local State").path)
    }

    func chromiumProfiles(_ browser: ImportBrowser) -> ChromiumProfiles {
        let state = (try? Data(contentsOf: userDataDirectory(browser).appendingPathComponent("Local State"))).map(parseChromiumProfiles) ?? []
        var profiles = ChromiumProfiles(found: [], missing: [])
        for profile in state {
            var isDirectory: ObjCBool = false
            if let folder = profileDirectory(browser, profile.directory),
               FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                profiles.found.append(profile)
            } else {
                profiles.missing.append(profile)
            }
        }
        return profiles
    }

    /// What goes in a Chrome profile's imported folder: its local bookmarks, then a signed-in
    /// account's, which Chromium keeps in a file of their own.
    func chromeBookmarks(_ profile: ChromiumProfile) -> [ArcNode] {
        guard let folder = profileDirectory(.chrome, profile.directory) else { return [] }
        return ["Bookmarks", "AccountBookmarks"].compactMap { name in
            (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? parseChromiumBookmarks($0) }
        }.reduce(ChromiumBookmarks(), +).folderContents
    }

    /// Web Store ids of the extensions enabled in one profile.
    func extensionIDs(_ browser: ImportBrowser, _ directory: String) -> [String] {
        guard let folder = profileDirectory(browser, directory) else { return [] }
        return parseChromiumExtensionIDs(["Secure Preferences", "Preferences"].compactMap {
            try? Data(contentsOf: folder.appendingPathComponent($0))
        })
    }

    /// Arc's member card, with the person's Arc name added, as a JSON object.
    func arcMembershipCard() -> Data? {
        guard let data = try? Data(contentsOf: arcDirectory.appendingPathComponent("StorableMembershipCard.json")),
              var card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let auth = (try? Data(contentsOf: arcDirectory.appendingPathComponent("StorableAuthState.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let user = (auth?["session"] as? [String: Any])?["user"] as? [String: Any]
        if let name = user?["name"] as? String { card["name"] = name }
        return try? JSONSerialization.data(withJSONObject: card, options: [.prettyPrinted, .sortedKeys])
    }

    /// Keeps Arc's member card beside the tabs in `tabsDirectory`.
    func saveArcMembershipCard(nextTo tabsDirectory: URL) {
        guard let card = arcMembershipCard() else { return }
        try? card.write(to: tabsDirectory.deletingLastPathComponent().appendingPathComponent("ArcMembershipCard.json"), options: .atomic)
    }

    func importDiaData() async -> DiaImportResult {
        let fileURL = sources.dia

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return DiaImportResult(favoriteTabs: [], windowTabs: [])
        }

        do {
            let result = try parseDiaData(from: fileURL)
            return result
        } catch {
            return DiaImportResult(favoriteTabs: [], windowTabs: [])
        }
    }

    func checkSafariExport(at directoryURL: URL) -> SafariExportContents? {
        return validateSafariExport(at: directoryURL)
    }

    func importSafariData(from directoryURL: URL, importBookmarks: Bool, importHistory: Bool) async -> SafariImportResult {
        do {
            let result = try parseSafariExport(from: directoryURL, importBookmarks: importBookmarks, importHistory: importHistory)
            return result
        } catch {
            return SafariImportResult(bookmarks: [], history: [])
        }
    }

    private var arcDirectory: URL { sources.arc }
}
