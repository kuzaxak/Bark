// Licensed under GPL-3.0. See LICENSE.
//
//  VaultSaveOfferView.swift
//  Nook
//
//  The card offering to save a password typed on the page to Pawl Vault. It never holds the
//  password; AutofillManager's offer does, until the user answers or the offer expires.
//

import SwiftUI
import NookDesign
import NookUI

struct VaultSaveOfferView: View {
    let offer: AutofillManager.SaveOffer
    let answer: (Bool) -> Void

    private var title: LocalizedStringKey {
        switch offer.action {
        case .create: "Save password to Pawl Vault?"
        case .update: "Update password in Pawl Vault?"
        case .manageNew: "Open Pawl Vault to save this login"
        case .manageExisting: "Review this login in Pawl Vault"
        }
    }

    private var buttonLabel: LocalizedStringKey {
        switch offer.action {
        case .create: "Save"
        case .update: "Update"
        case .manageNew, .manageExisting: "Open Pawl Vault"
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Not Now") { answer(false) }
            .buttonStyle(.bordered)
        Button(buttonLabel) { answer(true) }
            .buttonStyle(.borderedProminent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.sm) {
            Text(title)
                .font(NookDesign.Font.body)
                .foregroundStyle(.primary)
            Text("\(offer.username) on \(offer.host)")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NookDesign.Spacing.sm) { actions }
                    .fixedSize()
                VStack(alignment: .trailing, spacing: NookDesign.Spacing.xs) { actions }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .controlSize(.small)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(NookDesign.Spacing.md)
        .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.md))
    }
}
