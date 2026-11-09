import AppKit
import SwiftUI

private struct PanelFixture: View {
    var body: some View { Text("Panel").frame(width: 264, height: 200) }
}
private final class FlippedRoot: NSView {
    override var isFlipped: Bool { true }
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
        print("Native panel: bounded frame/input, ancestor hide, reparent and close cleanup PASS; windows never shown")
    }
}
