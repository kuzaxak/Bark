// Licensed under GPL-3.0. See LICENSE.
// A stand-in for NookNativeShell that runs the real engine in host mode with only ChromiumWindowRoot: host windows whose
// pages are placed by plain AppKit. Staged in place of the shell's executable for the window-host walk; never shipped.
// Keys: Cmd+T new tab, Cmd+W close the shown tab, Cmd+Shift+M move the shown tab to a new window, Ctrl+Cmd+F window
// full screen, Cmd+Q quit. Every action and host event is logged to stderr with a "walk-shell:" prefix.
import AppKit
import BarcChromium

@MainActor
private final class WalkHost {
    static var shared: WalkHost?
    let bridge: BarcBridge
    let profile: String
    let url: String
    private var roots: [Int32: ChromiumWindowRoot] = [:]
    private var opened = 1
    private var keys: Any?

    init(bridge: BarcBridge, profile: String, url: String) {
        self.bridge = bridge; self.profile = profile; self.url = url
    }

    func ready() {
        profile.withCString { uuid in
            bridge.profile_open_window(uuid, BARC_PROFILE_BLANK, { status, window, _ in
                MainActor.assumeIsolated { WalkHost.shared?.opened(status, window) }
            }, nil)
        }
    }

    private func opened(_ status: barc_profile_status, _ window: Int32) {
        guard status == BARC_PROFILE_OK, window > 0, bridge.window_set_app_lifetime(window) == 1 else {
            fail("no host window: status \(status.rawValue), window \(window)"); return
        }
        let tab = bridge.window_tab_at(window, 0)
        guard let root = attach(window), tab != 0, url.withCString({ bridge.tab_navigate(window, tab, $0) }) == 1,
              root.show(tab: tab) else {
            fail("the root or its page was refused"); return
        }
        guard bridge.window_show(window) == 1 else { fail("the window would not show"); return }
        bridge.runtime_complete_startup(window)
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let number = event.windowNumber, key = event.charactersIgnoringModifiers?.lowercased()
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option]).rawValue
            let handled = MainActor.assumeIsolated {
                WalkHost.shared?.handle(window: number, modifiers: NSEvent.ModifierFlags(rawValue: modifiers), key: key) == true
            }
            return handled ? nil : event
        }
        log("window \(window) tab \(tab)")
    }

    private func attach(_ window: Int32) -> ChromiumWindowRoot? {
        let root = ChromiumWindowRoot(bridge: bridge, nativeWindow: window)
        guard root.attach(), bridge.window_host_observe(window, { event, _ in
            guard let event else { return }
            let row = event.pointee
            MainActor.assumeIsolated { WalkHost.shared?.hostEvent(kind: row.kind, window: row.window, fullscreen: row.fullscreen) }
        }, nil) != 0 else { return nil }
        roots[window] = root
        return root
    }

    private func hostEvent(kind: Int32, window: Int32, fullscreen: Int32) {
        if kind == Int32(BARC_WINDOW_HOST_FULLSCREEN_CHANGED.rawValue) {
            log("fullscreen \(fullscreen) window \(window)")
        } else if kind == Int32(BARC_WINDOW_HOST_PAGE_VIEW_RETIRED.rawValue) {
            DispatchQueue.main.async { WalkHost.shared?.showRemaining(window) }
        }
    }

    private func showRemaining(_ window: Int32) {
        guard let root = roots[window], root.shownTab == 0, bridge.window_tab_count(window) > 0 else { return }
        let tab = bridge.window_tab_at(window, 0)
        log("show tab \(tab) window \(window) \(root.show(tab: tab))")
    }

    private func handle(window number: Int, modifiers: NSEvent.ModifierFlags, key: String?) -> Bool {
        guard let (window, root) = roots.first(where: { $0.value.window?.windowNumber == number }) else { return false }
        switch (modifiers, key) {
        case ([.command], "q"):
            log("quit")
            NSApp.terminate(nil)
        case ([.command], "t"):
            opened += 1
            let tab = "\(url)?tab=\(opened)".withCString { bridge.tab_create(window, $0, 1) }
            log("new tab \(tab) window \(window) \(tab != 0 && root.show(tab: tab))")
        case ([.command], "w"):
            log("close tab \(root.shownTab) window \(window) \(bridge.tab_close(window, root.shownTab))")
        case ([.command, .shift], "m"):
            move(root.shownTab, from: window)
        case ([.command, .control], "f"):
            log("window full screen window \(window)")
            root.window?.toggleFullScreen(nil)
        default:
            return false
        }
        return true
    }

    private func move(_ tab: Int32, from source: Int32) {
        let destination = bridge.window_new_peer(source)
        guard tab != 0, destination > 0, bridge.window_set_app_lifetime(destination) == 1,
              let target = attach(destination), bridge.tab_transfer(source, tab, destination) == 1,
              target.show(tab: tab), bridge.window_show(destination) == 1 else {
            log("move refused: tab \(tab) from \(source) to \(destination)"); return
        }
        log("moved tab \(tab) from \(source) to \(destination)")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("walk-shell: \(message)\n".utf8))
    }

    private func fail(_ message: String) {
        log(message)
        bridge.runtime_complete_startup(0)
    }
}

@MainActor
@_cdecl("barc_native_main")
public func barcNativeMain(
    _ bridge: UnsafePointer<BarcBridge>?, _ engineMain: BarcEngineMain?, _ argc: Int32,
    _ argv: UnsafePointer<UnsafePointer<CChar>?>?
) -> Int32 {
    guard let bridge, let engineMain, argc > 0, let argv else { return EXIT_FAILURE }
    let arguments = (0..<Int(argc)).compactMap { argv[$0].map { String(cString: $0) } }
    func value(_ name: String) -> String? {
        arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }
    guard let data = value("--barc-app-data-dir"), data.hasPrefix("/private/tmp/"),
          let profile = value("--barc-app-profile"), UUID(uuidString: profile) != nil else {
        FileHandle.standardError.write(Data("walk-shell: needs --barc-app-data-dir=/private/tmp/... and --barc-app-profile=UUID\n".utf8))
        return EXIT_FAILURE
    }
    let engineData = URL(fileURLWithPath: data).appendingPathComponent("Engine")
    try? FileManager.default.createDirectory(at: engineData, withIntermediateDirectories: true)
    WalkHost.shared = WalkHost(bridge: bridge.pointee, profile: profile, url: value("--walk-url") ?? "about:blank")
    bridge.pointee.set_runtime_ready_callback({ _ in MainActor.assumeIsolated { WalkHost.shared?.ready() } }, nil)
    bridge.pointee.set_runtime_close_callback({ _, _ in }, nil)
    bridge.pointee.set_runtime_window_request_callback({ _, _ in }, nil)
    bridge.pointee.set_runtime_browser_target_callback({ _, _, _, _, _, _ in 0 }, nil)
    let engine = [arguments[0], "--no-startup-window", "--no-first-run", "--no-default-browser-check", "--disable-sync",
                  "--barc-shared-native-window", "--barc-native-shell", "--bark-window=host",
                  "--user-data-dir=" + engineData.path, "--use-mock-keychain"]
    var pointers = engine.map { UnsafePointer(strdup($0)) }
    return pointers.withUnsafeMutableBufferPointer { engineMain(Int32($0.count), $0.baseAddress) }
}
