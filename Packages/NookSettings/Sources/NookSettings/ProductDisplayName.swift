// Licensed under GPL-3.0. See LICENSE.

import Foundation

/// The visible name of the app hosting the shell and shared packages.
public enum ProductDisplayName {
    public static var current: String { resolve(in: .main) }

    static func resolve(in bundle: Bundle) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle.object(forInfoDictionaryKey: key) as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        return "Nook"
    }
}
