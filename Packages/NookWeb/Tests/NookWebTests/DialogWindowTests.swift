// Licensed under GPL-3.0. See LICENSE.
import Testing
@testable import NookWeb

/// The Quit dialog draws in a browser window. It must find one whenever one is open, including
/// right after launch, before any window has become active.
@MainActor
struct DialogWindowTests {
    final class Handle: WindowHandle {
        var frameString: String? { nil }
        func applyFrame(_ rectString: String) {}
        func bringToFront() {}
    }

    @Test func anOpenWindowHostsTheDialogBeforeAnyIsActive() {
        let registry = WindowRegistry()
        #expect(registry.dialogWindow == nil, "no window open: nothing to draw in")
        let handle = Handle()
        let opened = BrowserWindowState()
        opened.windowHandle = handle
        registry.register(opened)
        #expect(registry.activeWindow == nil)
        #expect(registry.dialogWindow === opened, "a window that has not become active yet still hosts the dialog")
    }

    @Test func theActiveWindowComesFirst() {
        let registry = WindowRegistry()
        let handles = [Handle(), Handle()]
        let first = BrowserWindowState(), second = BrowserWindowState()
        first.windowHandle = handles[0]
        second.windowHandle = handles[1]
        registry.register(first)
        registry.register(second)
        registry.setActive(second)
        #expect(registry.dialogWindow === second)
        registry.setActive(first)
        #expect(registry.dialogWindow === first)
    }

    @Test func aWindowWithoutItsPlatformWindowHostsNothing() {
        let registry = WindowRegistry()
        registry.register(BrowserWindowState())
        #expect(registry.dialogWindow == nil, "a registered state whose window is gone or not made yet cannot show it")
    }
}
