// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped decision verbatim; the views stand in for Chromium's page views by their class names.
import AppKit

@objc(RenderWidgetHostViewCocoa) final class FakePage: NSView {}
@objc(WebContentsViewCocoa) final class FakeContents: NSView {}

@main @MainActor enum Check {
    static func main() {
        let pinned = UUID(), row = UUID()
        typealias A = ChromiumMouseButton
        func act(_ button: Int, page: Bool = false, pinned: UUID? = nil, row: UUID? = nil, sidebar: Bool = false) -> A? {
            A.action(button: button, overPage: page, hoveredPinned: pinned, hoveredRow: row, overSidebar: sidebar)
        }
        precondition(act(2, pinned: pinned, row: row, sidebar: true) == .resetToHome(pinned), "middle-click on a favorite or pinned tab resets it")
        precondition(act(2, row: row, sidebar: true) == .close(row), "middle-click on a tab row closes it")
        precondition(act(2, sidebar: true) == .openCommandBar, "middle-click elsewhere on the app's own views opens the command bar")
        precondition(act(3, sidebar: true) == .previousSpace && act(4, sidebar: true) == .nextSpace, "side buttons over the sidebar switch spaces")
        precondition(act(3) == .goBack && act(4) == .goForward, "side buttons over the app's other views go back and forward")
        for button in 2...4 {
            precondition(act(button, page: true, pinned: pinned, row: row, sidebar: true) == nil, "over the page Chromium keeps button \(button)")
        }
        precondition(act(5, sidebar: true) == nil && act(0) == nil, "other buttons are not the app's")

        let root = NSView(), contents = FakeContents(), page = FakePage(), inner = NSView(), sidebar = NSView()
        root.addSubview(contents); contents.addSubview(page); page.addSubview(inner); root.addSubview(sidebar)
        precondition(ChromiumMouseButton.isPage(inner) && ChromiumMouseButton.isPage(page) && ChromiumMouseButton.isPage(contents), "Chromium's page views are the page")
        precondition(ChromiumMouseButton.isPage(FakePage()), "a render view outside web contents, as a popup's, is the page too")
        precondition(!ChromiumMouseButton.isPage(sidebar) && !ChromiumMouseButton.isPage(root) && !ChromiumMouseButton.isPage(nil), "the rest of the window is the app's")
        print("Mouse buttons: the app's views reset, close, open the command bar and switch spaces; the page keeps its buttons")
    }
}
