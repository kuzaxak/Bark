// Licensed under GPL-3.0. See LICENSE.
//
//  HistorySuggestionItem.swift
//  Nook
//
//  Created by Maciek Bagiński on 18/08/2025.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct HistorySuggestionItem: View {
    let entry: HistoryEntry
    /// Held Command on the highlighted row shows the whole address instead of the short one.
    var showsFullURL: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SuggestionIcon(image: Image(systemName: "globe"))
            SuggestionLines(title: entry.displayTitle, detail: showsFullURL ? entry.url.absoluteString : PaletteText.shortURL(entry.url))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The favicon tile at the start of a row.
struct SuggestionIcon: View {
    let image: SwiftUI.Image

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .frame(width: 24, height: 24)
            .background(NookDesign.Surface.fill)
            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.xs))
    }
}

/// A row's title over its short address.
struct SuggestionLines: View {
    let title: String
    let detail: String
    var detailLineLimit: Int? = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(NookDesign.Font.label)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(detailLineLimit)
                .truncationMode(.middle)
        }
    }
}
