// Licensed under GPL-3.0. See LICENSE.
//
//  TabSuggestionItem.swift
//  Nook
//
//  Created by Maciek Bagiński on 18/08/2025.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct TabSuggestionItem: View {
    let tab: SearchManager.TabMatch
    let destination: (name: String, icon: String, profileName: String?)?
    /// Held Command on the highlighted row shows the whole address instead of the short one.
    var showsFullURL: Bool = false

    private var actionLabel: Text {
        guard let destination else { return Text("Switch to Tab") }
        if let profile = destination.profileName {
            return Text("Switch to \(destination.name) (\(profile) profile)")
        }
        return Text("Switch to \(destination.name)")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SuggestionIcon(image: tab.favicon).accessibilityHidden(true)
            SuggestionLines(title: tab.title, detail: showsFullURL ? tab.url.absoluteString : tab.detail ?? PaletteText.shortURL(tab.url))
            Spacer()
            if let destination { SpaceIcon(destination.icon).foregroundStyle(.secondary).accessibilityHidden(true) }
            actionLabel
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            Image(systemName: "arrow.right")
                .font(NookDesign.Font.label)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(NookDesign.Surface.fill)
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.xs))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A sidebar folder in the command bar: Return reveals it, Tab searches inside it.
struct FolderSuggestionItem: View {
    let folder: SearchManager.FolderMatch

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SuggestionIcon(image: Image(systemName: "folder")).accessibilityHidden(true)
            SuggestionLines(title: folder.title, detail: folder.path, detailLineLimit: nil)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer()
            if let icon = folder.spaceIcon { SpaceIcon(icon).foregroundStyle(.secondary).accessibilityHidden(true) }
            VStack(alignment: .trailing, spacing: 1) {
                Text(folder.detail)
                Text("Tab to search inside")
            }
            .fixedSize(horizontal: true, vertical: false)
            .font(NookDesign.Font.secondary)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
