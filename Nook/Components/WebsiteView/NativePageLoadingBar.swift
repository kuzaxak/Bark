// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import NookDesign

/// Native progress when the bridge has it, with a sweep while the fraction is unknown.
struct NativePageLoadingBar: View {
    let isLoading: Bool
    let progress: Double?

    private var gradient: some View {
        Rectangle().fill(LinearGradient(colors: [.blue.opacity(0.7), .cyan.opacity(0.5)],
                                        startPoint: .leading, endPoint: .trailing))
    }

    var body: some View {
        GeometryReader { geo in
            if isLoading {
                ZStack(alignment: .leading) {
                    Rectangle().fill(NookDesign.Surface.fillPressed)
                    if let progress {
                        gradient.frame(width: geo.size.width * progress)
                    } else {
                        TimelineView(.animation) { context in
                            let sweep = NativePageLoadingSweep.frame(at: context.date.timeIntervalSinceReferenceDate, width: geo.size.width)
                            gradient.frame(width: sweep.width).offset(x: sweep.x)
                        }
                    }
                }
            }
        }
        .frame(height: 2.5)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityRepresentation {
            if isLoading {
                if let progress {
                    ProgressView("Page loading", value: progress, total: 1)
                } else {
                    ProgressView("Page loading")
                        .accessibilityValue("In progress")
                }
            }
        }
        .accessibilityHidden(!isLoading)
    }
}
