import AppKit
import SwiftUI

// Deliberately no App/Scene entry point: BrowserCrApplication owns startup and
// the sole application loop. This view is created only by the browser UI hook.
private struct SmokeShell: View {
    @State private var clicks = 0
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Barc SwiftUI smoke")
            Button("Increment") { clicks += 1 }
                .accessibilityIdentifier("barc-smoke-increment")
            Text("Count: \(clicks)")
                .accessibilityIdentifier("barc-smoke-count")
            TextField("Focus / IME draft", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("barc-smoke-draft")
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// C ABI returns one retained Objective-C NSView as an opaque pointer. The
// Objective-C++ caller consumes it exactly once with __bridge_transfer.
@MainActor
@_cdecl("barc_create_swiftui_smoke_view")
public func barcCreateSwiftUISmokeView() -> UnsafeMutableRawPointer {
    precondition(Thread.isMainThread)
    let view = NSHostingView(rootView: SmokeShell())
    view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
    return Unmanaged.passRetained(view).toOpaque()
}
