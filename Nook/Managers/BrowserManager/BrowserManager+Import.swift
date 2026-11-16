// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Import.swift
//  Nook
//

import Foundation
import OSLog
import NookTabsCore
import NookWeb
import SwiftUI

extension BrowserManager {
    /// Arc's or Chrome's profiles as new spaces and Bark profiles: Arc's sidebar or Chrome's
    /// bookmarks, each profile's history, and the extensions it had enabled, listed for the person
    /// to add from the Web Store. Arc's member card is kept beside the tabs.
    func importBrowser(_ browser: ImportBrowser, progress: BrowserImportProgress) async -> BrowserImportSummary {
        if browser == .arc { importManager.saveArcMembershipCard(nextTo: tabs.directory) }
        return await browserImporter(progress: progress).run(browser)
    }

    /// Starts an import in the app's one import session; refused while another runs or its result is shown.
    @discardableResult
    func startImport(_ browser: ImportBrowser) -> Bool {
        importSession.start(browser) { [self] progress in await importBrowser(browser, progress: progress) }
    }

    func browserImporter(progress: BrowserImportProgress) -> BrowserImporter {
        BrowserImporter(source: importManager, tabs: tabs, history: historyManager, window: importWindow, lastImports: lastImportsFile,
                        replacesStarterSpaces: nookSettings?.didFinishOnboarding == false, progress: progress)
    }

    var lastImportsFile: URL {
        tabs.directory.deletingLastPathComponent().appendingPathComponent("LastImports.json")
    }

    func showImportDialog() {
        dialogManager.showDialog(BrowserImportDialog { [weak self] in self?.dialogManager.closeDialog() })
    }

    func importDiaData() async {
        let result = await importManager.importDiaData()
        let window = importWindow
        guard let spaceID = importSpaceID(window) else { return }

        importTabs(result.favoriteTabs.map(\.url), into: .favorites(spaceID: spaceID), window: window)
        importTabs(result.windowTabs.map(\.url), into: .tabs(spaceID: spaceID), window: window)
    }

    func importSafariData(from directoryURL: URL, importBookmarks: Bool, importHistory: Bool) async {
        let result = await importManager.importSafariData(
            from: directoryURL,
            importBookmarks: importBookmarks,
            importHistory: importHistory
        )

        if !result.bookmarks.isEmpty, let spaceID = importSpaceID(importWindow) {
            let window = importWindow
            let favoritesBookmarks = result.bookmarks.filter { $0.folder == "Favorites" }
            let otherBookmarks = result.bookmarks.filter { $0.folder != "Favorites" }

            importTabs(favoritesBookmarks.map(\.url), into: .favorites(spaceID: spaceID), window: window)

            var folderGroups: [String: [SafariBookmark]] = [:]
            var unfolderedBookmarks: [SafariBookmark] = []
            for bookmark in otherBookmarks {
                if let folder = bookmark.folder, !folder.isEmpty {
                    folderGroups[folder, default: []].append(bookmark)
                } else {
                    unfolderedBookmarks.append(bookmark)
                }
            }

            importTabs(unfolderedBookmarks.map(\.url), into: .tabs(spaceID: spaceID), window: window)
            for (folderName, bookmarks) in folderGroups.sorted(by: { $0.key > $1.key }) {
                guard let folderID = tabs.createFolder(title: folderName, in: .pinned(spaceID: spaceID), after: nil) else { continue }
                importTabs(bookmarks.map(\.url), into: .folder(itemID: folderID), window: window)
            }
        }

        if !result.history.isEmpty {
            let profileId = historyManager.currentProfileId
            historyManager.importVisits(result.history.compactMap { entry in
                guard let url = URL(string: entry.url) else { return nil }
                return HistoryVisit(url: url, title: entry.title, timestamp: entry.visitDate,
                                    tabId: nil, profileId: profileId)
            })
        }
    }

    /// Installs imported extensions from the Chrome Web Store one at a time, each through its
    /// permission sheet. Onboarding has no browser window to show one, so it waits for the first.
    func installPendingExtensionImports() {
        guard !pendingExtensionImports.isEmpty, !tabs.regularWindows.isEmpty, let manager = extensionManager else { return }
        let ids = pendingExtensionImports
        pendingExtensionImports = []
        Task { @MainActor in
            for id in ids where !manager.installedExtensions.contains(where: { $0.id == id }) {
                let result = await withCheckedContinuation { continuation in
                    manager.installFromWebStore(extensionId: id) { continuation.resume(returning: $0) }
                }
                if case .failure(let error) = result {
                    Self.importLog.error("Extension \(id, privacy: .public) not imported: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private static let importLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Import")

    // MARK: - Helpers

    /// A regular window: intents need one to pick the main tree. Imports never go to a private
    /// window. Onboarding imports run before any browser window registers; an unregistered window
    /// state still targets the main tree, and background opens never select in it.
    private var importWindow: BrowserWindowState {
        if let active = windowRegistry?.activeWindow, !active.isIncognito { return active }
        return tabs.regularWindows.first ?? BrowserWindowState()
    }

    private func importSpaceID(_ window: BrowserWindowState) -> UUID? {
        window.spaceID ?? tabs.orderedSpaces.first?.id
    }

    /// Adds tabs under `parent` in source order without loading pages or changing selection.
    /// `open` inserts at the top, so the list goes in reversed.
    private func importTabs(_ urls: [String], into parent: Parent, window: BrowserWindowState) {
        for string in urls.reversed() {
            guard let url = URL(string: string), url.scheme != nil else { continue }
            tabs.open(url: url, in: window, placement: .background, parent: parent)
        }
    }
}
