// Licensed under GPL-3.0. See LICENSE.
//
//  ExternalMiniWindowManager.swift
//  Nook
//
//  Created by Jonathan Caudill on 26/08/2025.
//

import Foundation
import NookWeb

/// Retains native compact window controllers until their detached pages close or move to a tab.
@MainActor
final class ExternalMiniWindowManager {
    private var controllers: [UUID: any DetachedPageWindowController] = [:]

    /// Registration never creates a page or another browser window.
    func retainNative(_ controller: any DetachedPageWindowController) -> Bool {
        guard controller.nativeWindowID != nil, controller.nativeTabID != nil,
              controller.page.isDetached, controllers[controller.page.itemID] == nil else { return false }
        controllers[controller.page.itemID] = controller
        return true
    }

    func releaseNative(_ controller: any DetachedPageWindowController) {
        let id = controller.page.itemID
        if controllers[id] === controller { controllers[id] = nil }
    }

    func nativeController(tab: Int32) -> (any DetachedPageWindowController)? {
        controllers.values.first { $0.nativeTabID == tab }
    }

    func relinquishNativeHeader(window: Int32, except tab: Int32) {
        for controller in Array(controllers.values) where controller.nativeWindowID == window && controller.nativeTabID != tab {
            controller.relinquishNativeHeader()
        }
    }

    func nativePage(tab: Int32) -> PageSession? {
        controllers.values.first { $0.nativeTabID == tab }?.page
    }

    func completeNativeAdoption(tab: Int32) {
        guard let controller = controllers.values.first(where: { $0.nativeTabID == tab }),
              !controller.page.isDetached else { return }
        controller.releaseAfterAdoption()
    }

    func ownsNativeWindow(_ window: Int32) -> Bool {
        controllers.values.contains { $0.nativeWindowID == window }
    }
}
