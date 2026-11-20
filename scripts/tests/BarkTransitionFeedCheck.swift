// Licensed under GPL-3.0. See LICENSE.

@main
enum BarkTransitionFeedCheck {
    static func main() {
        let base = "https://github.com/kuzaxak/Bark/releases/latest/download"
        precondition(BarkTransitionFeed.url(arm64Capability: 1) == "\(base)/bark-macos-arm64.xml")
        precondition(BarkTransitionFeed.url(arm64Capability: 0) == "\(base)/bark-macos-x86_64.xml")
        precondition(BarkTransitionFeed.url(arm64Capability: nil, unavailableOnIntel: true) ==
                     "\(base)/bark-macos-x86_64.xml")
        precondition(BarkTransitionFeed.url(arm64Capability: nil) == nil)
        precondition(BarkTransitionFeed.url(arm64Capability: -1) == nil)
        precondition(BarkTransitionFeed.nativeURL != nil)
        print("Bark architecture feed checks passed.")
    }
}
