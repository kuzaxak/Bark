import SwiftUI

/// Rows stacked in a vertical scroll view that is as tall as the rows, up to `maxHeight`.
struct FittedRowsScroll<Rows: View>: View {
    let maxHeight: CGFloat
    var spacing: CGFloat = 5
    @ViewBuilder let rows: Rows

    var body: some View {
        HeightCap(maxHeight: maxHeight) {
            ScrollView(.vertical) {
                // A LazyVStack reports a height estimated from the rows it has built, which depends on the viewport.
                VStack(alignment: .leading, spacing: spacing) { rows }
            }
        }
    }
}

/// Offers its one subview the subview's own ideal height, capped.
private struct HeightCap: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
