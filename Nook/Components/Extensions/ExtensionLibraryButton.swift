// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionLibraryButton.swift
//  Nook
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct ExtensionLibraryButton: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.chromiumSiteControlsAnchor) private var siteControlsAnchor

    var body: some View {
        // Arc's site controls button; the panel springs out of it.
        Button("Site Controls", systemImage: "slider.horizontal.2.square") {
            siteControlsAnchor?.source = .address
            withAnimation(.interpolatingSpring(Spring(response: 0.3, dampingRatio: 0.86))) {
                windowState.isExtensionLibraryVisible.toggle()
            }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: NookDesign.Size.siteControlsGlyph, weight: .regular))
        .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.addressButton, radius: NookDesign.Radius.sm, foreground: .secondary))
        // The overlay in WindowView hangs off this frame.
    }
}
