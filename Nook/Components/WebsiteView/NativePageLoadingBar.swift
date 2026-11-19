// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import NookDesign

/// The bridge reports no load fraction, so the bar sweeps while the page loads.
struct NativePageLoadingBar: View {
    let isLoading: Bool

    var body: some View {
        GeometryReader { geo in
            if isLoading {
                TimelineView(.animation) { context in
                    let sweep = NativePageLoadingSweep.frame(at: context.date.timeIntervalSinceReferenceDate, width: geo.size.width)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(NookDesign.Surface.fillPressed)
                        Rectangle()
                            .fill(LinearGradient(colors: [.blue.opacity(0.7), .cyan.opacity(0.5)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: sweep.width)
                            .offset(x: sweep.x)
                    }
                }
            }
        }
        .frame(height: 2.5)
        .clipped()
        .allowsHitTesting(false)
    }
}
