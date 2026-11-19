// Licensed under GPL-3.0. See LICENSE.
//
//  NavigationHistoryMenu.swift
//  Nook
//
//  Created by Jonathan Caudill on 01/10/2025.
//

import AppKit
import SwiftUI
import NookDesign
import NookWeb

/// Back's or Forward's history behind its button: a right-click, Control-click or held press lists
/// the pages that way, nearest first, by title and favicon. Choosing one goes there in this
/// window's view of the tab.
struct NavigationHistoryMenu: View {
    enum Direction {
        case back
        case forward
    }

    let direction: Direction
    let windowState: BrowserWindowState
    @EnvironmentObject var browserManager: BrowserManager

    var body: some View {
        HoldMenuRegion(holdDelay: NookDesign.Motion.historyMenuHold, makeMenu: makeMenu)
    }

    private func makeMenu() -> NSMenu? {
        guard let page = browserManager.frontPage(in: windowState),
              let navigation = page.navigation,
              browserManager.tabs.nativePageHost?.isNativeSelection(navigation, in: windowState) == true else { return nil }
        let profile = navigation.profileID
        let entries = navigation.historyEntries(forward: direction == .forward)
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in entries {
            let title = entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title
            let item = HandlerMenuItem(title: title) { [weak page, weak navigation] _ in
                guard let page, let navigation,
                      browserManager.windowRegistry?.windows[windowState.id] === windowState,
                      browserManager.windowRegistry?.activeWindow === windowState,
                      let keyWindow = NSApp.keyWindow, windowState.window === keyWindow,
                      browserManager.frontPage(in: windowState) === page,
                      page.navigation === navigation,
                      navigation.profileID == profile,
                      browserManager.tabs.nativePageHost?.isNativeSelection(navigation, in: windowState) == true else { return }
                _ = navigation.goToHistoryEntry(entry.id)
            }
            if let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.copy() as? NSImage {
                image.size = NSSize(width: NookDesign.Size.favicon, height: NookDesign.Size.favicon)
                item.image = image
            }
            menu.addItem(item)
        }
        return menu
    }

}
