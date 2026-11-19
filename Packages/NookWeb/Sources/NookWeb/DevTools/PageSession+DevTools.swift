// Licensed under GPL-3.0. See LICENSE.
import Foundation

extension PageSession {
    var developerModeOn: Bool { controller?.settings.developerModeEnabled == true }

    /// Read the selected element in the isolated world owned by this Chromium page.
    public func nativeDevPickScript(_ selector: String) -> String? {
        guard developerModeOn, usesNativePageHost, navigation != nil, !nativeIsEnding else { return nil }
        return DevPickerScript.describeScript(selector: selector)
    }

    /// The same element's React, Vue or Svelte names and source, for a native page-world request.
    public func nativeDevHintsScript(_ selector: String) -> String? {
        guard developerModeOn, usesNativePageHost, navigation != nil, !nativeIsEnding else { return nil }
        return DevPickerScript.hintsScript(selector: selector)
    }

    /// The existing dormant snapshot controller for a native isolated-world
    /// request. This installs no picker listeners and exposes no native handler.
    public func nativeDevSnapshotScript(_ selector: String, maxDepth: Int, maxNodes: Int) -> String? {
        guard developerModeOn, usesNativePageHost, navigation != nil, !nativeIsEnding,
              let data = try? JSONSerialization.data(withJSONObject: selector, options: .fragmentsAllowed),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        let depth = min(max(maxDepth, 1), 40), nodes = min(max(maxNodes, 1), 2_000)
        return DevPickerScript.source + "\nreturn window.__nookDevPicker.snapshot(\(literal), \(depth), \(nodes));"
    }
}
