import Foundation

struct NSImage {
    let bytes: Data
    init?(data: Data) {
        guard data == Data([1, 2, 3]) else { return nil }
        bytes = data
    }
}
@MainActor final class NativeWindow {}
@MainActor enum NSApp { static var keyWindow: NativeWindow? }
@MainActor final class NSPasteboard {
    static var general = NSPasteboard()
    var changeCount = 7
    var clears = 0
    var images: [NSImage] = []
    var acceptsWrite = true
    func clearContents() { changeCount += 1; clears += 1 }
    func writeObjects(_ objects: [NSImage]) -> Bool {
        if acceptsWrite { images = objects }
        return acceptsWrite
    }
}
enum ChromiumNavigationError: Error { case screenshotUnavailable }
@MainActor final class ChromiumPageNavigation {
    var nativeWindowID: Int32 = 10
    var nativeTabID: Int32 = 20
    var profileID = UUID()
    var isClosed = false
    var continuation: CheckedContinuation<Data, Error>?
    var widths: [Double] = []
    func captureScreenshot(maxWidth: Double) async throws -> Data {
        widths.append(maxWidth)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<Data, Error> = .success(Data([1, 2, 3]))) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
@MainActor final class PageSession {
    var navigation: AnyObject?
    var nativeNavigationSerial: UInt64 = 1
}
@MainActor final class BrowserWindowState {
    let id = UUID()
    var window: NativeWindow? = NativeWindow()
}
@MainActor final class WindowRegistry {
    var windows: [UUID: BrowserWindowState] = [:]
    var activeWindow: BrowserWindowState?
}
@MainActor final class NativeHost {
    var selected = true
    func isNativeSelection(_ page: ChromiumPageNavigation, in window: BrowserWindowState) -> Bool { selected }
}
enum ProfileEngine { case chromium, webKit }
@MainActor final class Tabs {
    var profileEngine: ProfileEngine = .chromium
    var nativePageHost: NativeHost? = NativeHost()
}
@MainActor final class BrowserManager {
    var windowRegistry: WindowRegistry? = WindowRegistry()
    let tabs = Tabs()
    var front: PageSession?
    var toasts: [String] = []
    func frontPage(in window: BrowserWindowState) -> PageSession? { front }
    func showWindowToast(_ text: String, in window: BrowserWindowState) { toasts.append(text) }
}

@MainActor struct Fixture {
    let manager = BrowserManager()
    let window = BrowserWindowState()
    let page = PageSession()
    let native = ChromiumPageNavigation()
    init() {
        NSPasteboard.general = NSPasteboard()
        NSApp.keyWindow = window.window
        manager.windowRegistry?.windows[window.id] = window
        manager.windowRegistry?.activeWindow = window
        manager.front = page
        page.navigation = native
    }
    func begin() async -> Task<Bool, Never> {
        let task = Task { await manager.copyNativeScreenshot(of: page, in: window) }
        for _ in 0..<1000 {
            if native.continuation != nil { break }
            await Task.yield()
        }
        precondition(native.continuation != nil)
        return task
    }
    func expectUntouched() {
        precondition(NSPasteboard.general.clears == 0 && NSPasteboard.general.images.isEmpty)
        precondition(manager.toasts.isEmpty)
    }
}

@main struct Check {
    @MainActor static func main() async {
        let normal = Fixture()
        let successful = await normal.begin()
        normal.native.finish()
        let copied = await successful.value
        precondition(copied && normal.native.widths == [4096])
        precondition(NSPasteboard.general.images.count == 1 && NSPasteboard.general.clears == 1)
        precondition(normal.manager.toasts == ["Screenshot copied"])

        let changes: [(Fixture) -> Void] = [
            { $0.page.nativeNavigationSerial += 1 },
            { $0.page.navigation = ChromiumPageNavigation() },
            { $0.native.nativeWindowID += 1 },
            { $0.native.nativeTabID += 1 },
            { $0.native.profileID = UUID() },
            { $0.native.isClosed = true },
            { $0.manager.front = PageSession() },
            { $0.manager.windowRegistry?.windows.removeValue(forKey: $0.window.id) },
            { $0.manager.windowRegistry?.activeWindow = BrowserWindowState() },
            { $0.manager.tabs.nativePageHost?.selected = false },
            { _ in NSApp.keyWindow = NativeWindow() },
            { $0.window.window = nil },
            { $0.manager.tabs.profileEngine = .webKit },
            { _ in NSPasteboard.general.changeCount += 1 }
        ]
        for change in changes {
            let f = Fixture(), pending = await f.begin()
            change(f)
            f.native.finish()
            let result = await pending.value
            precondition(!result)
            f.expectUntouched()
        }
        let cancelled = Fixture(), pending = await cancelled.begin()
        pending.cancel()
        cancelled.native.finish()
        let cancellationResult = await pending.value
        precondition(!cancellationResult)
        cancelled.expectUntouched()

        for failure in [Result<Data, Error>.failure(ChromiumNavigationError.screenshotUnavailable), .success(Data())] {
            let f = Fixture(), pending = await f.begin()
            f.native.finish(failure)
            let result = await pending.value
            precondition(!result && NSPasteboard.general.clears == 0)
            precondition(f.manager.toasts == ["Screenshot unavailable"])
        }
        let refused = Fixture()
        refused.manager.tabs.nativePageHost?.selected = false
        let refusal = await refused.manager.copyNativeScreenshot(of: refused.page, in: refused.window)
        precondition(!refusal && refused.native.widths.isEmpty)
        refused.expectUntouched()

        let unwritable = Fixture(), last = await unwritable.begin()
        NSPasteboard.general.acceptsWrite = false
        unwritable.native.finish()
        let written = await last.value
        precondition(!written && unwritable.manager.toasts == ["Could not copy screenshot"])
        // Portrait retains the captured image while composing; its lease must
        // still reject ownership changes after the asynchronous capture finished.
        let portrait = Fixture()
        let preview = Task { await portrait.manager.captureNativeScreenshot(of: portrait.page, in: portrait.window) }
        while portrait.native.continuation == nil { await Task.yield() }
        // An unrelated clipboard operation while generating a preview must not
        // invalidate the later explicit Portrait capture.
        NSPasteboard.general.changeCount += 1
        portrait.native.finish()
        guard let lease = await preview.value else { preconditionFailure() }
        precondition(lease.isCurrent() && NSPasteboard.general.clears == 0)
        NSPasteboard.general.acceptsWrite = false
        precondition(!PortraitComposition.copyImage(lease.image, to: .general, expectedVersion: NSPasteboard.general.changeCount))
        let afterRefusal = NSPasteboard.general.clears
        precondition(!PortraitComposition.copyImage(lease.image, to: .general, expectedVersion: -1))
        precondition(NSPasteboard.general.clears == afterRefusal)
        portrait.page.nativeNavigationSerial += 1
        precondition(!lease.isCurrent())
        precondition(NSPasteboard.general.images.isEmpty)
        let deniedPortrait = Fixture()
        deniedPortrait.manager.tabs.nativePageHost?.selected = false
        let denied = await deniedPortrait.manager.captureNativeScreenshot(of: deniedPortrait.page, in: deniedPortrait.window)
        precondition(denied == nil && deniedPortrait.native.widths.isEmpty)
        print("Chromium clipboard: capture, 14 ownership/clipboard changes, cancellation, refusals and write failure PASS")
    }
}
