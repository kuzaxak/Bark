// Licensed under GPL-3.0. See LICENSE.
//
//  HelloStage.swift
//  Nook
//
//  Created by Maciek Bagiński on 19/02/2026.
//

import AppKit
import SwiftUI
import NookSettings

struct HelloStage: View {

    var body: some View {
        VStack(spacing: 24){
            Text("Say Hi to \(ProductDisplayName.current)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            Text("Your new open-source browser.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
