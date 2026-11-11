import AppKit
import NookSettings
import SwiftUI

/// Develop's onboarding, on the first launch of a data directory.
@MainActor enum ChromiumOnboarding {
    /// Whether this launch shows onboarding. A data directory that already holds tabs, from an
    /// earlier launch or a conversion, is a returning person's, so it counts as finished.
    static func isNeeded(didFinish: inout Bool, hadTabs: Bool) -> Bool {
        if hadTabs && !didFinish { didFinish = true }
        return !didFinish
    }

    static func hasTabs(in directory: URL) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty
    }

    // MARK: - Window

    private static var window: NSWindow?

    /// Shows onboarding in a window of its own, as develop's first window, and calls `finished`
    /// once the person is through it. The browser window opens after.
    static func present(manager: BrowserManager, settings: NookSettingsService, finished: @escaping @MainActor () -> Void) {
        let view = Root(settings: settings) {
            window?.close()
            window = nil
            finished()
        }
        .environment(\.nookSettings, settings)
        .environment(settings)
        .environmentObject(manager)
        .environment(manager.tabs)
        let onboarding = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
            styleMask: [.titled, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        onboarding.contentView = NSHostingView(rootView: view)
        onboarding.titlebarAppearsTransparent = true
        onboarding.titleVisibility = .hidden
        onboarding.isReleasedWhenClosed = false
        onboarding.center()
        window = onboarding
        NSApp.activate()
        onboarding.makeKeyAndOrderFront(nil)
    }
}

private struct Root: View {
    let settings: NookSettingsService
    let finished: () -> Void

    var body: some View {
        OnboardingView()
            .onChange(of: settings.didFinishOnboarding) { _, done in
                if done { finished() }
            }
    }
}
