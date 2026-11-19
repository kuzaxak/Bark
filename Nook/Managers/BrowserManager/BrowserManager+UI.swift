// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+UI.swift
//  Nook
//
//  Created by Bain Gurley on 17/09/2026.
//
//  The app side of NookUI's seam: the split view, the floating dialogs, the tab-closure
//  toast, the window accent, and the two AppKit services the shared menus need.
//

import AppKit
import SwiftUI
import NookTabsCore
import NookUI
import NookWeb

extension BrowserManager: TabActions {
    var spaceSync: (any SpaceSyncControls)? {
        if engine == .chromium {
            guard nookSettings?.didFinishOnboarding == true,
                  spaceSyncManager.status.availability != .disabled else { return nil }
        }
        return spaceSyncManager
    }

    func enterSplit(with itemID: UUID, placeOnRight: Bool, in window: BrowserWindowState) {
        splitManager.enterSplit(with: itemID, placeOn: placeOnRight ? .trailing : .leading, in: window)
    }

    func offersSplit(in window: BrowserWindowState) -> Bool {
        splitManager.offersAddSplitView(in: window)
    }

    func separateSplit(in window: BrowserWindowState) {
        splitManager.separateAll(in: window)
    }

    func convertSplit(in window: BrowserWindowState) {
        splitManager.convert(in: window)
    }

    func editPinnedURL(url: URL, title: String, onSave: @escaping (URL) -> Void) {
        dialogManager.showDialog(
            EditPinnedURLDialog(
                url: url,
                title: title,
                onSave: { [weak self] newURL in
                    onSave(newURL)
                    self?.dialogManager.closeDialog()
                },
                onCancel: { [weak self] in self?.dialogManager.closeDialog() }
            )
        )
    }

    /// Asks for a feed URL and adds a live feed folder to the space's pinned section.
    func presentFeedFolderPrompt(in spaceID: UUID) {
        dialogManager.showDialog(
            FeedFolderDialog(
                onAdd: { [weak self] url in
                    self?.tabs.createLiveFolder(.feed(url), in: spaceID)
                    self?.dialogManager.closeDialog()
                },
                onCancel: { [weak self] in self?.dialogManager.closeDialog() }
            )
        )
    }

    func presentSpaceCreation(onCreate:@escaping (String, String) -> Void) {
        dialogManager.showDialog(
            SpaceCreationDialog(
                onCreate: { [weak self] name, accentHex in
                    onCreate(name, accentHex)
                    self?.dialogManager.closeDialog()
                },
                onCancel: { [weak self] in self?.dialogManager.closeDialog() }
            )
        )
    }

    func confirmSpaceDeletion(spaceName: String, tabCount: Int, isLastSpace: Bool, onDelete: @escaping () -> Void) {
        dialogManager.showDialog(
            SpaceDeleteConfirmationDialog(
                spaceName: spaceName,
                tabsCount: tabCount,
                isLastSpace: isLastSpace,
                onDelete: { [weak self] in
                    onDelete()
                    self?.dialogManager.closeDialog()
                },
                onCancel: { [weak self] in self?.dialogManager.closeDialog() }
            )
        )
    }

    private func ownsPasswordManagementCommand(_ window: BrowserWindowState) -> Bool {
        guard engine == .chromium, let nativeWindow = window.window, nativeWindow.isKeyWindow,
              let registry = windowRegistry, registry.activeWindow === window,
              registry.windows[window.id] === window, !window.isIncognito, window.privateTree == nil else { return false }
        return window.spaceID.flatMap(tabs.space)?.isAgent == false
    }

    func offersPasswordManagementCommand(_ text: String, in window: BrowserWindowState,
                                          hasSearchOrPlacementOverride: Bool) -> Bool {
        ChromiumPasswordManagementCommand.offersSettings(
            text, pawlEnabledAtLaunch: tabs.vault?.pawlEnabledAtLaunch,
            regularNativeOwner: nativeOpenSettings != nil && ownsPasswordManagementCommand(window),
            hasSearchOrPlacementOverride: hasSearchOrPlacementOverride
        )
    }

    func openPasswordManagementCommand(_ text: String, in window: BrowserWindowState,
                                       hasSearchOrPlacementOverride: Bool, dismissEditor: () -> Void) -> Bool {
        guard let open = nativeOpenSettings else { return false }
        let space = window.spaceID, item = window.selectedItemID, page = frontPage(in: window)
        return ChromiumPasswordManagementCommand.handle(
            text, pawlEnabledAtLaunch: tabs.vault?.pawlEnabledAtLaunch,
            hasSearchOrPlacementOverride: hasSearchOrPlacementOverride,
            ownerCurrent: {
                ownsPasswordManagementCommand(window) && window.spaceID == space
                    && window.selectedItemID == item && frontPage(in: window) === page
            },
            dismissEditor: dismissEditor,
            openPasswordSettings: { open(.privacy) }
        )
    }

    func showInactiveUnloadResult(_ result: InactiveUnloadResult, in window: BrowserWindowState?) {
        guard let window = window ?? windowRegistry?.activeWindow,
              windowRegistry?.windows[window.id] === window else { return }
        showWindowToast(result.presentationSummary, in: window)
    }

    func openSpaceSettings() {
        openSettings(tab: .spaces)
    }

    var accentColor: Color {
        gradientColorManager.accentColor
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func share(_ url: URL) {
        let picker = NSSharingServicePicker(items: [url as NSURL])
        guard let window = CommandWindow.key else { return }
        picker.show(relativeTo: .zero, of: window.contentView ?? NSView(), preferredEdge: .minY)
    }
}
