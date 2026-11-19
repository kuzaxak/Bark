// Licensed under GPL-3.0. See LICENSE.
import AppKit
import NookDesign
import NookUI
import NookWeb
import SwiftUI

struct PeekActionButtons: View {
    let canEnterSplit: Bool
    let dismiss: () -> Void
    let openAsTab: () -> Void
    let openInSplit: () -> Void

    var body: some View {
        VStack(spacing: NookDesign.Spacing.sm) {
            peekButton("Close", systemImage: "xmark", action: dismiss)
            peekButton("Open as Tab", systemImage: "arrow.up.left.and.arrow.down.right", action: openAsTab)
            peekButton("Open in Split View", systemImage: "square.split.2x1", action: openInSplit)
                .disabled(!canEnterSplit)
        }
    }

    private func peekButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: NookDesign.Size.rowGlyph, weight: .semibold))
            .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.iconButton, radius: NookDesign.Size.iconButton / 2))
            .foregroundStyle(.secondary)
            .nookFloatingSurface(in: Circle())
            .help(title)
    }
}

/// Arc's Peek bar: back, forward and reload at the leading edge and the site in the middle, which
/// copies the link. It takes the page's colour, as the top bar does.
struct PeekNavigationBar: View {
    let page: PageSession
    let cornerRadius: CGFloat
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    private var copyURLHelp: String { browserManager.help("Copy URL", shortcut: .copyCurrentURL) }

    private var pageColor: NSColor? { page.topBarBackgroundColor ?? page.pageBackgroundColor }

    var body: some View {
        ZStack {
            HStack(spacing: NookDesign.Spacing.xxs) {
                Button("Back", systemImage: "chevron.backward") { page.goBack() }
                    .disabled(!page.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { page.goForward() }
                    .disabled(!page.canGoForward)
                Button(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise") {
                    page.isLoading ? page.stop() : page.refresh()
                }
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.navRow, radius: NookDesign.Radius.sm))

            Button(action: copyLink) {
                Label(page.url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? page.url.absoluteString,
                      systemImage: copied ? "checkmark" : "link")
                    .font(NookDesign.Font.secondary)
                    .lineLimit(1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(copyURLHelp)
            .padding(.horizontal, NookDesign.Size.navRow * 3 + NookDesign.Spacing.lg)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, NookDesign.Spacing.sm)
        .frame(height: NookDesign.Size.peekBar)
        .background(
            pageColor.map { Color(nsColor: $0) } ?? NookDesign.Surface.raised,
            in: UnevenRoundedRectangle(topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius, style: .continuous)
        )
        .environment(\.colorScheme, pageColor.map { $0.isPerceivedDark ? .dark : .light } ?? colorScheme)
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(page.url.absoluteString, forType: .string)
        withAnimation(NookDesign.Motion.quick) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(NookDesign.Motion.quick) { copied = false }
        }
    }
}
