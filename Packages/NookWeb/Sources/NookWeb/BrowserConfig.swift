// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserConfig.swift
//  Nook
//
//  Created by Maciek Bagiński on 31/07/2025.
//

import SwiftUI
import WebKit
import NookBlocker

public class BrowserConfiguration {
    /// Shared configuration for explicitly WebKit-owned adapters.
    public static let webKit = BrowserConfiguration()

    static func webKitAdapter(for engine: Profile.Engine) -> BrowserConfiguration? {
        guard engine == .webKit else { return nil }
        return webKit
    }
    
    private init() {}
    
    public lazy var webViewConfiguration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        #if os(macOS)
        BrowserConfiguration.applyProcessPool(to: config)
        #endif

        // Use default website data store for normal browsing
        // Extensions use their own separate persistent storage managed by Apple
        config.websiteDataStore = WKWebsiteDataStore.default()

        // Configure JavaScript preferences for extension support
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        // Core WebKit preferences for extensions
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Media settings — use macOS default (no restrictions, matching Safari behavior).
        // [.audio] blocks programmatic play() for media with audio tracks, which breaks
        // YouTube autoplay since SPA navigations call play() outside user-gesture context.
        config.mediaTypesRequiringUserActionForPlayback = []
        
        // "mediaDevicesEnabled" stays unset: it crashes WebContent (sandbox-denied AudioComponentRegistrar).
        // Pages still get mic and camera from the Info.plist usage strings and device entitlements.

        // CRITICAL: Enable HTML5 Fullscreen API
        config.preferences.isElementFullscreenEnabled = true

        // Enable background media playback
        config.allowsAirPlayForMediaPlayback = true
        
        // User agent for better compatibility with Client Hints support
        config.applicationNameForUserAgent = "Version/\(PlatformUserAgent.safariVersion) Safari/605.1.15"

        // Clipboard, picture-in-picture, inline playback and the inspector; see
        // BrowserConfig+macOS.swift.
        BrowserConfiguration.applyPlatformPreferences(to: config)

        // Note: webExtensionController will be set by ExtensionManager during initialization

        config.userContentController.addUserScript(Self.passkeySuppressionScript)
        config.userContentController.addUserScript(
            WKUserScript(source: MediaScript.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        return config
    }()

    // MARK: Passkey suppression
    // Pending Apple approval of com.apple.developer.web-browser.public-key-credential,
    // tell websites we don't support platform authenticators so they won't prompt for passkeys.
    // While Pawl Vault is connected, VaultBridge swaps this for its own passkey shim.
    public static var passkeySuppressionScript: WKUserScript {
        WKUserScript(source: passkeySuppressionSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static let passkeySuppressionSource = """
        // Nook Passkey Suppression
        (function() {
            if (window.PublicKeyCredential) {
                PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
                    return Promise.resolve(false);
                };
                if (PublicKeyCredential.isConditionalMediationAvailable) {
                    PublicKeyCredential.isConditionalMediationAvailable = function() {
                        return Promise.resolve(false);
                    };
                }
            }
        })();
        """

    /// Optional hook for ContentBlockerManager to apply rule lists to new controllers.
    public var contentRuleListApplicator: ((WKUserContentController) -> Void)?

    // MARK: - Fresh User Content Controller
    // Creates a fresh WKUserContentController but preserves Nook's own shared
    // user scripts. This avoids cross-tab handler conflicts while keeping
    // scripts that must be present on every tab.
    //
    // Only Nook-owned scripts are copied. WKWebExtensionController injects its
    // content scripts into every new controller itself, so copying them here as
    // well would hand each new tab two of each. See WKUserScript+NookOwned.
    public func freshUserContentController() -> WKUserContentController {
        let controller = WKUserContentController()
        for script in webViewConfiguration.userContentController.userScripts.nookOwned {
            controller.addUserScript(script)
        }
        // Apply content blocker rule lists if available
        contentRuleListApplicator?(controller)
        return controller
    }

    // MARK: - Cache-Optimized Configuration
    // Derives from shared config to preserve process pool + extension controller
    public func cacheOptimizedWebViewConfiguration() -> WKWebViewConfiguration {
        let config = webViewConfiguration.copy() as! WKWebViewConfiguration
        config.userContentController = freshUserContentController()
        return config
    }

    // MARK: - Profile-Aware Configurations
    /// Refuse native identities before instantiating shared WebKit configuration.
    @MainActor
    public static func webViewConfiguration(for profile: Profile) -> WKWebViewConfiguration? {
        guard let dataStore = profile.webKitDataStore else { return nil }
        let browser = webKit
        let config = browser.webViewConfiguration.copy() as! WKWebViewConfiguration
        config.userContentController = browser.freshUserContentController()
        config.websiteDataStore = dataStore

        // Extensions never run in private profiles.
        if profile.isEphemeral {
            config.webExtensionController = nil
        }
        return config
    }

    // MARK: - Chrome Web Store Integration
    
    /// Get the Web Store injector script
    public static func webStoreInjectorScript() -> WKUserScript? {
        guard let scriptPath = Bundle.main.path(forResource: "WebStoreInjector", ofType: "js"),
              let scriptSource = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            return nil
        }
        
        return WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }
}
