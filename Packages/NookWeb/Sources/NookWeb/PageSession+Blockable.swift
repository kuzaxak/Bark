// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+Blockable.swift
//  Nook
//
//  PageSession satisfies NookBlocker's page seam as-is: itemID, isOAuthFlow and
//  webView are already its own stored properties. Task 6 moves this into NookWeb.
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
        usesNativePageHost ? navigation?.state.url ?? url : primaryWebView?.url
    }

    @discardableResult public func reloadForBlocking() -> Bool {
        if usesNativePageHost { return navigation?.reload() ?? false }
        guard let primaryWebView else { return false }
        primaryWebView.reloadFromOrigin()
        return true
    }
}
