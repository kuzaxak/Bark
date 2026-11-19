// Licensed under GPL-3.0. See LICENSE.
import AppKit
import SwiftUI

@main
struct UpdateControlsFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let bundle = Bundle.main
        let info = bundle.infoDictionary!
        let rehearsal = info["BarkUpdateRehearsal"] != nil
        let configuration = ChromiumUpdateConfiguration(
            info: info, isVerification: rehearsal, isRehearsal: rehearsal)!
        precondition(ChromiumAppUpdater.isSigned(bundle))
        let updater = ChromiumAppUpdater(configuration: configuration, bundle: bundle)
        if !CommandLine.arguments.contains("--without-start") {
            updater.start()
            // Rehearsal still has a real manual updater; hidden controls alone
            // could also result from Sparkle failing to start.
            precondition(updater.canCheckForUpdates)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sparkle Settings Fixture"
        window.contentView = NSHostingView(rootView:
            Form {
                Section("Automatic Updates") {
                    AnyView(updater.automaticUpdateControls)
                }
                Button("Finish") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { app.terminate(nil) } }
            }
            .formStyle(.grouped)
            .frame(width: 520, height: 240)
        )
        window.center()
        window.orderFrontRegardless()
        withExtendedLifetime((window, updater)) { app.run() }
    }
}
