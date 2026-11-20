// Licensed under GPL-3.0. See LICENSE.
import Darwin

enum BarkTransitionFeed {
    private static let base = "https://github.com/kuzaxak/Nook/releases/latest/download"

    static func url(arm64Capability: Int32?, unavailableOnIntel: Bool = false) -> String? {
        switch arm64Capability {
        case 1: return "\(base)/bark-macos-arm64.xml"
        case 0: return "\(base)/bark-macos-x86_64.xml"
        case nil where unavailableOnIntel: return "\(base)/bark-macos-x86_64.xml"
        default: return nil
        }
    }

    /// A translated Intel process still needs the Apple Silicon Bark build.
    static var nativeURL: String? {
        #if arch(arm64)
        url(arm64Capability: 1)
        #elseif arch(x86_64)
        var capability: Int32 = 0
        var size = MemoryLayout.size(ofValue: capability)
        if sysctlbyname("hw.optional.arm64", &capability, &size, nil, 0) == 0 {
            return size == MemoryLayout<Int32>.size ? url(arm64Capability: capability) : nil
        }
        // Intel Macs do not expose this capability. Unexpected lookup
        // failures leave the original feed selected.
        return url(arm64Capability: nil, unavailableOnIntel: errno == ENOENT)
        #else
        nil
        #endif
    }
}
