// Licensed under GPL-3.0. See LICENSE.
//
//  FInalStage.swift
//  Nook
//
//  Created by Maciek Bagiński on 19/02/2026.
//

import SwiftUI

struct FinalStage: View {

    var body: some View {
        VStack(spacing: 16) {
            Text("Your spaces start on this Mac")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text("Your Nook iCloud spaces and invitations stay in Nook.")
            Text("To sync with other Macs running Bark, turn on iCloud Sync in Settings → Spaces.")
        }
        .font(.system(size: 16))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.8))
        .frame(maxWidth: 480)
        .padding(.horizontal, 16)
    }
}
