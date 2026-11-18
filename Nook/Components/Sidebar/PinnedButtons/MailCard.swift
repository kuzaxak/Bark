// Licensed under GPL-3.0. See LICENSE.
//
//  MailCard.swift
//  Nook
//
//  The Gmail favorite's hover card, as in Arc: the newest unread email, with a + to compose.
//

import SwiftUI
import NookSettings
import NookDesign
import NookWeb

struct MailCard: View {
    let itemID: UUID
    let account: Int
    /// Opens a page in the favorite's tab.
    let open: (URL) -> Void

    private let live = LiveFavorites.shared

    var body: some View {
        content
            .padding(NookDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomTrailing) {
                FavoriteCardAddButton(help: "Compose") { open(GoogleFavorite.compose(account: account)) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch live.mailOutcome(itemID, account: account) {
        case .inbox(let inbox)?:
            if let message = inbox.newest {
                Button {
                    open(message.link)
                } label: {
                    newest(message)
                }
                .buttonStyle(.plain)
            } else {
                note("No unread mail")
            }
        case .unavailable?:
            note("Mail previews aren’t available for this profile")
        case .signedOut?:
            note("Sign in to Gmail in this favorite to see new mail")
        case .failed?:
            note("Gmail didn't answer. \(ProductDisplayName.current) will try again shortly.")
        case nil:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func newest(_ message: GmailFeed.Message) -> some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: NookDesign.Spacing.md) {
                Text(message.sender)
                    .font(NookDesign.Font.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(GmailFeed.age(of: message.modified, now: live.now))
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                .font(NookDesign.Font.body)
                .lineLimit(1)
            Text(message.summary)
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.trailing, NookDesign.Size.iconButton)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(NookDesign.Font.bodyRegular)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, NookDesign.Size.iconButton)
    }
}
