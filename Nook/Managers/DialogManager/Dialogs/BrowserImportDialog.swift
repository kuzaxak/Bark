// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserImportDialog.swift
//  Nook
//
//  Created by Maciek Bagiński on 14/10/2025.
//
//

import AppKit
import NookDesign
import SwiftUI

/// Imports from Arc or Chrome, whichever is on this Mac: the choice, then the app's one import
/// session, running or finished, from whichever window opens the dialog.
struct BrowserImportDialog: DialogPresentable {
    @EnvironmentObject private var browserManager: BrowserManager
    let onCancel: () -> Void
    @State private var choice: ImportBrowser?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    private var session: BrowserImportSession { browserManager.importSession }

    private var offered: [ImportBrowser] {
        ImportBrowser.allCases.filter(browserManager.importManager.isInstalled)
    }

    private var selected: ImportBrowser? { choice ?? offered.first }

    var body: some View {
        dialogChrome(header: dialogHeader(), content: dialogContent(), footer: dialogFooter())
            .onChange(of: session.isRunning, initial: true) { _, running in
                browserManager.dialogManager.closesOnScrimTap = !running
            }
    }

    func dialogHeader() -> DialogHeader {
        DialogHeader(
            icon: "square.and.arrow.down.on.square",
            title: "Import from Another Browser",
            subtitle: session.summary != nil || session.isRunning ? nil
                : offered.isEmpty ? "Bark didn't find Arc or Chrome on this Mac."
                : "Bring in spaces, bookmarks, history and the list of extensions."
        )
    }

    @ViewBuilder
    func dialogContent() -> some View {
        if let summary = session.summary {
            BrowserImportResultView(summary: summary) { item in
                browserManager.browserImporter(progress: session.progress).openWebStorePage(item)
            }
        } else if session.isRunning, let browser = session.browser {
            BrowserImportProgressView(browser: browser, progress: session.progress)
        } else if let selected {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Browser", selection: Binding(get: { selected }, set: { choice = $0 })) {
                    ForEach(offered, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let date = BrowserImporter.lastImport(of: selected, in: browserManager.lastImportsFile) {
                    Text("Last imported from \(selected.name) on \(date.formatted(date: .abbreviated, time: .shortened)). Importing again adds its spaces again.")
                        .font(NookDesign.Font.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    func dialogFooter() -> DialogFooter {
        if session.summary != nil {
            return DialogFooter(rightButtons: [
                DialogButton(text: "Done", variant: .primary, keyboardShortcut: .return) {
                    session.dismiss()
                    onCancel()
                },
            ])
        }
        if session.isRunning {
            return DialogFooter(rightButtons: [
                DialogButton(text: "Stop Import", variant: .secondary, keyboardShortcut: .escape) { session.stop() },
            ])
        }
        guard let selected else {
            return DialogFooter(rightButtons: [
                DialogButton(text: "Close", variant: .primary, keyboardShortcut: .return, action: onCancel),
            ])
        }
        return DialogFooter(rightButtons: [
            DialogButton(text: "Maybe later", variant: .secondary, keyboardShortcut: .escape, action: onCancel),
            DialogButton(text: "Import from \(selected.name)", variant: .primary, keyboardShortcut: .return) {
                browserManager.startImport(selected)
            },
        ])
    }
}
