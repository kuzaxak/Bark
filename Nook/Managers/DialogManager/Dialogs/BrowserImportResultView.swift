// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserImportResultView.swift
//  Nook
//

import NookDesign
import NookWeb
import SwiftUI

/// How far an import's history has come.
struct BrowserImportProgressView: View {
    let browser: ImportBrowser
    let progress: BrowserImportProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(progress.visitsTotal > 0 ? "Importing history: \(progress.visitsRead.formatted()) of \(progress.visitsTotal.formatted()) visits"
                 : progress.itemsTotal > 0 ? "Importing tabs and bookmarks: \(progress.itemsDone.formatted()) of \(progress.itemsTotal.formatted())"
                 : "Importing from \(browser.name)…")
                .font(NookDesign.Font.body)
                .monospacedDigit()
        }
    }
}

/// What an import brought in, what it skipped, and the extensions to add from the Web Store.
struct BrowserImportResultView: View {
    @Environment(TabsController.self) private var tabs
    let summary: BrowserImportSummary
    let open: (BrowserImportSummary.Extension) -> Void
    @State private var opened: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.foundNothing {
                Text(summary.nothingFoundMessage)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    count(summary.spaces, "space", "spaces")
                    count(summary.tabs, "tab or bookmark", "tabs and bookmarks")
                    count(summary.visits, "history visit", "history visits")
                    count(summary.extensions.count, "extension found", "extensions found")
                }
                if summary.cancelled {
                    Text("The import was stopped. What came in before that stays.")
                }
            }
            ForEach(summary.skipped.indices, id: \.self) { index in
                let skipped = summary.skipped[index]
                Text(skipped.reason == .folderMissing ? "Skipped \(skipped.profile): its profile folder is missing."
                                                      : "Skipped the history of \(skipped.profile): it could not be read.")
                    .foregroundStyle(.secondary)
            }
            if !summary.extensions.isEmpty {
                Text("Add each extension from the Chrome Web Store; Bark installs nothing on its own.")
                    .foregroundStyle(.secondary)
                if summary.extensions.count <= 6 {
                    extensionRows
                } else {
                    ScrollView { extensionRows }
                        .frame(height: 180)
                }
            }
            if !summary.foundNothing {
                Text(BrowserImportSummary.signInNote)
                    .foregroundStyle(.secondary)
            }
        }
        .font(NookDesign.Font.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var extensionRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(summary.extensions) { item in
                HStack {
                    Text(item.id)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(opened.contains(item.id) ? "Added to \(tabs.space(item.spaceID)?.name ?? "its space")" : "Open in Web Store") {
                        open(item)
                        opened.insert(item.id)
                    }
                    .disabled(opened.contains(item.id))
                }
            }
        }
    }

    private func count(_ value: Int, _ one: String, _ many: String) -> some View {
        Text("\(value.formatted()) \(value == 1 ? one : many)")
            .monospacedDigit()
    }
}
