import AppKit
import NookSettings

/// Keeps NSApp on the Appearance setting. Chromium's frames, its own pages and web
/// `prefers-color-scheme` follow `NSApp.effectiveAppearance`, so this is the only place it must reach.
@MainActor
final class ChromiumAppearance {
    private let observer: NSObjectProtocol

    init(settings: NookSettingsService) {
        applyAppearanceMode(settings.appearanceMode)
        observer = NotificationCenter.default.addObserver(forName: .appearanceModeChanged, object: nil, queue: .main) { [weak settings] _ in
            MainActor.assumeIsolated {
                if let settings { applyAppearanceMode(settings.appearanceMode) }
            }
        }
    }

    isolated deinit { NotificationCenter.default.removeObserver(observer) }
}
