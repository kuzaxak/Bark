// Licensed under GPL-3.0. See LICENSE.
import WebKit

enum BrowserConfiguration {
    @MainActor
    static func webViewConfiguration(for profile: Profile) -> WKWebViewConfiguration? {
        guard let dataStore = profile.webKitStorage?.dataStore else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.applicationNameForUserAgent = "Version/\(PlatformUserAgent.safariVersion) Safari/605.1.15"
        config.userContentController.addUserScript(
            WKUserScript(source: MediaScript.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        return config
    }
}
