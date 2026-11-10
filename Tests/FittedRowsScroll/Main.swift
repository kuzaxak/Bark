import AppKit
import SwiftUI

private final class Heights { var seen: [CGFloat] = [] }

private struct Fixture: View {
    let rows: [CGFloat]
    let heights: Heights

    var body: some View {
        FittedRowsScroll(maxHeight: 470, spacing: 5) {
            ForEach(rows.indices, id: \.self) { index in Color.gray.frame(height: rows[index]).id(index) }
        }
        .frame(width: 700)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.seen.append($0) }
    }
}

@main @MainActor
private enum Checks {
    static var failures: [String] = []
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()); print("FAIL", message()) }
    }

    /// Lays the list out in a window the way the command bar's panel does: frame from the fitting size, then layout.
    static func settle(_ rows: [CGFloat], label: String, expected: CGFloat) {
        let heights = Heights()
        let host = NSHostingView(rootView: Fixture(rows: rows, heights: heights))
        check(host.fittingSize.height == expected, "\(label): first fitting height \(host.fittingSize.height), rows need \(expected)")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<40 {
            host.frame.size.height = host.fittingSize.height
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        check(host.fittingSize.height == expected, "\(label): settled fitting height \(host.fittingSize.height), rows need \(expected)")
        check(Set(heights.seen) == [expected], "\(label): list heights over 40 layouts \(heights.seen.prefix(12))")
        let scroll = host.firstSubview(of: NSScrollView.self)
        let document = scroll?.documentView?.frame.height ?? 0
        let total = rows.reduce(0, +) + CGFloat(rows.count - 1) * 5
        check(document == total, "\(label): scrollable rows \(document), rows need \(total)")
        window.close()
    }

    static func main() {
        _ = NSApplication.shared
        // Section headers between rows, as the bar lists Actions and History under their own headings.
        let sections: [CGFloat] = [16, 41, 41, 41, 16, 41, 41, 41, 41]
        settle(sections, label: "sections", expected: 359)
        settle([60, 14, 36, 36, 14, 36, 36], label: "return row", expected: 262)
        settle([43], label: "one row", expected: 43)
        settle(Array(repeating: 34, count: 30), label: "past the cap", expected: 470)
        if failures.isEmpty { print("PASS FittedRowsScroll") }
        exit(failures.isEmpty ? 0 : 1)
    }
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for child in subviews {
            if let match = child as? T ?? child.firstSubview(of: type) { return match }
        }
        return nil
    }
}
