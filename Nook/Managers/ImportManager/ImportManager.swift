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

class ImportManager: ObservableObject {
    /// Where Arc and Dia keep the data an import reads.
    struct Sources {
        /// Arc's Application Support folder.
        let arc: URL
        /// Dia's `StorableProfileContainers.json`.
        let dia: URL

        static let installed = Sources(
            arc: URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Arc").expandingTildeInPath),
            dia: URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Dia/StorableProfileContainers.json").expandingTildeInPath))

        /// Copies laid out under a verification run's data directory, in place of the person's own.
        static func fixtures(in root: URL) -> Sources {
            let imports = root.appendingPathComponent("Import", isDirectory: true)
            return Sources(arc: imports.appendingPathComponent("Arc", isDirectory: true),
                           dia: imports.appendingPathComponent("Dia/StorableProfileContainers.json"))
        }
    }

    let sources: Sources

    init(sources: Sources = .installed) {
        self.sources = sources
    }

    func importArcSidebarData() async -> ArcImportResult {
        guard let data = try? Data(contentsOf: arcDirectory.appendingPathComponent("StorableSidebar.json")),
              var result = try? parseArcSidebarData(data) else { return ArcImportResult() }
        // Chromium's Local State names each profile directory.
        let state = (try? Data(contentsOf: arcDirectory.appendingPathComponent("User Data/Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cache = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: Any] ?? [:]
        for (directory, info) in cache {
            guard let name = (info as? [String: Any])?["name"] as? String else { continue }
            result.profileNames[directory == "Default" ? "default" : directory] = name
        }
        return result
    }

    /// Web Store ids of the extensions enabled in any Arc profile.
    func arcExtensionIDs() -> [String] {
        let userData = arcDirectory.appendingPathComponent("User Data")
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: userData.path)) ?? []
        let files = profiles.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted().flatMap { profile in
            ["Secure Preferences", "Preferences"].compactMap {
                try? Data(contentsOf: userData.appendingPathComponent(profile).appendingPathComponent($0))
            }
        }
        return parseChromiumExtensionIDs(files)
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
