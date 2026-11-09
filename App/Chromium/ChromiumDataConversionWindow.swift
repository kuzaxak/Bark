import AppKit
import SwiftUI

/// A nested modal loop would hold back Chromium's UI-thread tasks until the person answers.
@MainActor
enum ChromiumDataConversionWindow {
    private static var window: NSWindow?

    static func present(_ conversion: ChromiumDataConversion, finished: @escaping @MainActor () -> Void) {
        let menuBar = ChromiumDataConversionFlow.MenuBar(get: { NSApp.mainMenu }, set: { NSApp.mainMenu = $0 })
        let flow = ChromiumDataConversionFlow(conversion: conversion, menuBar: menuBar) {
            window?.close()
            window = nil
            finished()
        }
        let panel = NSWindow(contentViewController: NSHostingController(rootView: ChromiumDataConversionView(flow: flow)))
        panel.styleMask = [.titled]
        panel.title = "Nook"
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct ChromiumDataConversionView: View {
    let flow: ChromiumDataConversionFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ChromiumDataConversion.noticeTitle).font(.headline)
            Text(ChromiumDataConversion.noticeBody).fixedSize(horizontal: false, vertical: true)
            switch flow.phase {
            case .offer:
                actions(primary: "Convert")
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                }
            case .failed(let reason):
                Text(reason).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                actions(primary: "Retry")
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func actions(primary: String) -> some View {
        HStack {
            Spacer()
            Button("Start Fresh") { flow.startFresh() }
            Button(primary) { flow.convert() }.keyboardShortcut(.defaultAction)
        }
    }
}
