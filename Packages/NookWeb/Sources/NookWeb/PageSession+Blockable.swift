// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+Blockable.swift
//  Nook
//
//  Implement blocking operations for the page's current engine.
//

import Foundation
import NookBlocker

extension PageSession: BlockablePage {
    @discardableResult public func applyNetworkBlockingPolicy(_ policy: ContentBlockerManager.NetworkPagePolicy) -> Bool {
        guard usesNativePageHost, !nativeIsEnding, let controller, !controller.isTerminating,
              let navigation, navigation.profileID == profile?.id,
              controller.session(for: itemID) === self || (isDetached && nativeResourceHost != nil) else { return false }
        return navigation.applyBlockingPolicy(policy)
    }

    public var blockingURL: URL? {
        usesNativePageHost ? navigation?.state.url ?? url : nil
    }

    @discardableResult public func reloadForBlocking() -> Bool {
        guard usesNativePageHost else { return false }
        return navigation?.reload() ?? false
    }
}
