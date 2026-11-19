// Licensed under GPL-3.0. See LICENSE.
import AppKit
import SwiftUI
import NookDesign
import NookSettings

/// Where a pane sits in its split, which decides the corners it rounds.
struct SplitPanePosition: Equatable {
    var index: Int
    var count: Int
    var vertical: Bool
}

/// Add Split View's new pane until the command bar fills it. Not a tab, so there is no page:
/// only the strip with the bar's placeholder. The bar draws the pane's close button.
final class EmptySplitPaneView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private let maskLayer = CAShapeLayer()
    private weak var settings: NookSettingsService?
    var position: SplitPanePosition {
        didSet { if position != oldValue { updateMask() } }
    }

    init(frame: NSRect, position: SplitPanePosition, settings: NookSettingsService?) {
        self.settings = settings
        self.position = position
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = maskLayer
        viewDidChangeEffectiveAppearance()
        let strip = NSHostingView(rootView: EmptySplitPaneStrip())
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.safeAreaRegions = []
        addSubview(strip)
        let inset = NookDesign.Spacing.sm
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        updateMask()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMask()
    }

    private func updateMask() {
        maskLayer.path = Self.maskPath(position: position, bounds: bounds, settings: settings)
    }

    private static func maskPath(position: SplitPanePosition, bounds: CGRect, settings: NookSettingsService?) -> CGPath {
        let radius = NookDesign.Radius.page
        let outer = settings?.hideWebContentBorder == true ? 0 : radius
        let first = position.index == 0, last = position.index == position.count - 1
        let leading = position.vertical || first, trailing = position.vertical || last
        let top = !position.vertical || first, bottom = !position.vertical || last
        return roundedPath(
            rect: bounds,
            topLeadingRadius: top && leading ? 0 : radius,
            bottomLeadingRadius: bottom && leading ? outer : radius,
            bottomTrailingRadius: bottom && trailing ? outer : radius,
            topTrailingRadius: top && trailing ? 0 : radius
        )
    }

    private static func roundedPath(
        rect: CGRect,
        topLeadingRadius: CGFloat,
        bottomLeadingRadius: CGFloat,
        bottomTrailingRadius: CGFloat,
        topTrailingRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()

        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX
        let maxY = rect.maxY

        // Start from top-left, move clockwise
        path.move(to: CGPoint(x: minX + topLeadingRadius, y: maxY))

        // Top edge to top-right corner
        path.addLine(to: CGPoint(x: maxX - topTrailingRadius, y: maxY))
        if topTrailingRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - topTrailingRadius), radius: topTrailingRadius)
        }

        // Right edge to bottom-right corner
        path.addLine(to: CGPoint(x: maxX, y: minY + bottomTrailingRadius))
        if bottomTrailingRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX - bottomTrailingRadius, y: minY), radius: bottomTrailingRadius)
        }

        // Bottom edge to bottom-left corner
        path.addLine(to: CGPoint(x: minX + bottomLeadingRadius, y: minY))
        if bottomLeadingRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX, y: minY + bottomLeadingRadius), radius: bottomLeadingRadius)
        }

        // Left edge to top-left corner
        path.addLine(to: CGPoint(x: minX, y: maxY - topLeadingRadius))
        if topLeadingRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + topLeadingRadius, y: maxY), radius: topLeadingRadius)
        }

        path.closeSubpath()
        return path
    }
}

private struct EmptySplitPaneStrip: View {
    var body: some View {
        Text(CommandPaletteView.placeholder)
            .font(NookDesign.Font.secondary)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: NookDesign.Size.navRow)
    }
}
