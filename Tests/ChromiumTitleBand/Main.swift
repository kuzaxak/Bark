// Licensed under GPL-3.0. See LICENSE.
// Compiles the shipped title band against a real titled window, which is never shown.
import AppKit

@MainActor private func window(_ style: NSWindow.StyleMask) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: style, backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    return window
}

/// The zoom button's frame in `view`, top-left origin, worked out through the window rather than the view.
@MainActor private func zoomFrame(seenFrom view: NSView) -> CGRect {
    let window = view.window!, zoom = window.standardWindowButton(.zoomButton)!
    let inWindow = zoom.convert(zoom.bounds, to: nil), viewInWindow = view.convert(view.bounds, to: nil)
    return CGRect(x: inWindow.minX - viewInWindow.minX, y: viewInWindow.maxY - inWindow.maxY, width: inWindow.width, height: inWindow.height)
}

@MainActor private func drain() {
    for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

@main struct Main {
    @MainActor static func main() {
        _ = NSApplication.shared
        let titled = window([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        let shell = NSView(frame: titled.contentView!.bounds)
        titled.contentView!.addSubview(shell)
        let zoom = zoomFrame(seenFrom: shell)
        let band = SidebarTitleBand.measure(in: shell)
        precondition(band != nil, "a titled window's lights give the band")
        precondition(abs(band!.height - 2 * zoom.midY) < 0.5, "the row is centred on the lights: \(band!) against \(zoom)")
        precondition(abs(band!.leadingInset - (zoom.maxX + 4)) < 0.5, "the sidebar button starts Arc's gap past the zoom light")
        precondition(band!.contentTop == 46, "below a band shorter than Arc's, the content starts where Arc's address field does: \(band!)")

        let toolbar = window([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        toolbar.toolbar = NSToolbar()
        toolbar.toolbarStyle = .unified
        let tall = NSView(frame: toolbar.contentView!.bounds)
        toolbar.contentView!.addSubview(tall)
        let tallBand = SidebarTitleBand.measure(in: tall)!
        precondition(tallBand.height > 46 && tallBand.contentTop == tallBand.height, "a band taller than Arc's keeps the content below it: \(tallBand)")

        let offset = NSView(frame: NSRect(x: 120, y: 40, width: 240, height: 400))
        titled.contentView!.addSubview(offset)
        let seen = zoomFrame(seenFrom: offset)
        let offsetBand = SidebarTitleBand.measure(in: offset)
        precondition(offsetBand != nil && abs(offsetBand!.height - 2 * seen.midY) < 0.5 && abs(offsetBand!.leadingInset - (seen.maxX + 4)) < 0.5,
                     "measured from where the sidebar is, not the window's corner")

        var reported: [SidebarTitleBand?] = []
        let probe = SidebarTitleBandReader.Probe(frame: shell.frame)
        probe.onChange = { reported.append($0) }
        titled.contentView!.addSubview(probe)
        drain()
        precondition(reported.last == SidebarTitleBand.measure(in: probe) && reported.last! != nil, "the probe reports the band once in a window")
        let lights = titled.standardWindowButton(.closeButton)!.superview!
        lights.isHidden = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: titled)
        drain()
        precondition(reported.last! == nil, "entering full screen, where the lights leave the window, reports no band")
        lights.isHidden = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: titled)
        drain()
        precondition(reported.last! == SidebarTitleBand.measure(in: probe), "leaving full screen measures the lights again")
        lights.isHidden = true

        precondition(SidebarTitleBand.measure(in: shell) == nil, "hidden lights leave the design's band")
        precondition(SidebarTitleBand.measure(in: NSView()) == nil, "no window, no lights")
        let plain = window([.borderless])
        let content = NSView(frame: plain.contentView!.bounds)
        plain.contentView!.addSubview(content)
        precondition(SidebarTitleBand.measure(in: content) == nil, "a window without lights keeps the design's band")
        print("Title band: centred on the lights and past the zoom light, from the sidebar's own place")
    }
}
