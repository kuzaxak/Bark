// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import NookDesign
import NookUI

struct SplitPaneButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.primary)
                .frame(width: NookDesign.Size.rowButton, height: NookDesign.Size.rowButton)
                .background(isHovering ? NookDesign.Surface.fillPressed : Color.clear)
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
        .onHoverTracking { isHovering = $0 }
    }
}
