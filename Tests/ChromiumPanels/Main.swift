import AppKit
import SwiftUI

private struct PanelFixture: View {
    var body: some View { Text("Panel").frame(width: 264, height: 200) }
}
private final class FlippedRoot: NSView {
    override var isFlipped: Bool { true }
}
/// Stands in for the host-mode window root: it lays out the page frame itself.
private final class HostRoot: NSView, ChromiumPanelHost {
    let pageFrame = FlippedRoot(frame: NSRect(x: 247, y: 10, width: 743, height: 680))
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); addSubview(pageFrame) }
    required init?(coder: NSCoder) { nil }
    func panelContainer(for fill: ChromiumPanelFill) -> NSView { fill == .window ? self : pageFrame }
}

@main @MainActor
private enum Checks {
    static func main() {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        second.contentView = FlippedRoot(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        first.contentView = root
        let page = NSView(frame: root.bounds)
        root.addSubview(page)
        let shell = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        root.addSubview(shell)
        let anchor = ChromiumPagePanel<PanelFixture>.Anchor(frame: shell.bounds)
        anchor.content = PanelFixture()
        shell.addSubview(anchor)
        anchor.updatePanel()
        guard let panel = root.subviews.last, panel !== shell else { preconditionFailure("Panel not mounted") }
        precondition(panel.superview === root && panel.frame.width == 264 && panel.frame.height == 200)
        precondition(panel.frame.maxX == root.bounds.maxX - 12 && panel.frame.maxY == 588)
        // Real AppKit hit testing: transparent anchor never catches page input.
        precondition(root.hitTest(NSPoint(x: 400, y: 100)) === page)
        let hit = root.hitTest(NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        precondition(hit === panel || hit?.isDescendant(of: panel) == true)
        precondition(anchor.hitTest(.zero) == nil)
        first.setContentSize(NSSize(width: 900, height: 500))
        precondition(panel.frame.maxX == root.bounds.maxX - 12 && panel.frame.maxY == root.bounds.maxY - 12)
        shell.isHidden = true
        precondition(panel.superview == nil && root.subviews.count == 2)
        shell.isHidden = false
        anchor.updatePanel()
        precondition(root.subviews.count == 3)
        let returned = root.subviews.last!
        // Reparenting the owning shell retires the old window's sibling view.
        second.contentView!.addSubview(shell)
        anchor.updatePanel()
        precondition(returned.superview == nil && root.subviews.count == 1)
        precondition(second.contentView!.subviews.count == 2)
        let moved = second.contentView!.subviews.last!
        precondition(moved.frame.maxX == second.contentView!.bounds.maxX - 12)
        precondition(moved.frame.minY == 12, "Flipped native content must use its top edge")
        second.close()
        precondition(moved.superview == nil)
        anchor.updatePanel()
        precondition(second.contentView!.subviews.count == 1, "Closed owner must not remount")
        anchor.stop(); anchor.stop()
        first.close()
        hostRootPlacesPanels()
        print("Native panel: bounded frame/input, ancestor hide, reparent and close cleanup PASS; windows never shown")
        print("Native panel in a host root: page, fitted and window panels placed by the root whatever the sidebar does PASS")
    }

    /// In host mode the sidebar holding the anchors may sit outside the window; panels still go
    /// where the root says.
    static func hostRootPlacesPanels() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = HostRoot(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        window.contentView = root
        let sidebar = FlippedRoot(frame: NSRect(x: -252, y: 0, width: 247, height: 700))
        root.addSubview(sidebar)
        func anchor(_ fill: ChromiumPanelFill) -> ChromiumPagePanel<PanelFixture>.Anchor {
            let anchor = ChromiumPagePanel<PanelFixture>.Anchor(frame: sidebar.bounds)
            anchor.content = PanelFixture(); anchor.fill = fill
            sidebar.addSubview(anchor)
            anchor.updatePanel()
            return anchor
        }
        let page = anchor(.page), fitted = anchor(.fitted), whole = anchor(.window)
        let inPage = root.pageFrame.subviews
        precondition(inPage.count == 2, "page and fitted panels go into the page frame with the sidebar out: \(inPage)")
        precondition(inPage[0].frame == root.pageFrame.bounds, "a page panel fills the page frame: \(inPage[0].frame)")
        precondition(inPage[1].frame == NSRect(x: 743 - 12 - 264, y: 12, width: 264, height: 200),
                     "a fitted panel sits at the page frame's top right: \(inPage[1].frame)")
        let top = root.subviews.last!
        precondition(top !== sidebar && top.frame == root.bounds, "a window panel covers the whole root above the sidebar")
        sidebar.frame.origin.x = 0
        page.updatePanel(); fitted.updatePanel(); whole.updatePanel()
        precondition(root.pageFrame.subviews.count == 2 && root.subviews.last === top, "showing the sidebar moves no panel")
        root.pageFrame.frame = NSRect(x: 10, y: 10, width: 980, height: 680)
        precondition(inPage[0].frame == root.pageFrame.bounds, "a page panel follows the page frame")
        precondition(inPage[1].frame.maxX == 980 - 12 && inPage[1].frame.minY == 12, "a fitted panel keeps its corner")
        page.stop(); fitted.stop(); whole.stop()
        precondition(root.pageFrame.subviews.isEmpty && root.subviews.last === sidebar, "stopping removes every panel")
        window.close()
    }
}
