import AppKit
import NookSettings

/// Keeps NSApp on the Appearance setting. Chromium's frames, its own pages and web
/// `prefers-color-scheme` follow `NSApp.effectiveAppearance`, so this is the only place it must reach.
@MainActor
final class ChromiumAppearance {
    private let observer: NSObjectProtocol
    private var effective: NSKeyValueObservation?
    var onEffectiveChange: (@MainActor () -> Void)?

    init(settings: NookSettingsService) {
        applyAppearanceMode(settings.appearanceMode)
        observer = NotificationCenter.default.addObserver(forName: .appearanceModeChanged, object: nil, queue: .main) { [weak settings] _ in
            MainActor.assumeIsolated {
                if let settings { applyAppearanceMode(settings.appearanceMode) }
            }
        }
        effective = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onEffectiveChange?() }
        }
    }

    isolated deinit { NotificationCenter.default.removeObserver(observer) }
}

@MainActor
private func applyAppearanceMode(_ mode: AppearanceMode) {
    switch mode {
    case .system:
        NSApp.appearance = nil  // Follow system
    case .light:
        NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
