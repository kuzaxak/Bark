// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped ToastView with NookDesign; the sizes are what SwiftUI lays the toasts out at.
import AppKit
import SwiftUI

@main @MainActor enum Check {
    static func size(_ text: String, width: CGFloat) -> CGSize {
        let toast = ToastView { ToastContent(icon: "checkmark.circle.fill", text: text) }
        return NSHostingController(rootView: toast).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    static func main() {
        let sidebar: CGFloat = 224
        let short = size("Copied", width: sidebar), long = size("Developer Mode isn’t available in private windows", width: sidebar)
        let oneLine = size("Developer Mode isn’t available in private windows", width: 2_000)
        precondition(short.width < sidebar, "a short toast keeps to its text: \(short)")
        precondition(long.width <= sidebar, "a toast never grows past the width it is given: \(long)")
        precondition(long.height > oneLine.height, "its text wraps instead: \(long) against \(oneLine)")
        precondition(oneLine.width > sidebar && abs(oneLine.height - short.height) < 1, "with room it stays on one line: \(oneLine)")
        print("Toasts: a toast keeps to the width it is given and wraps its text")
    }
}
