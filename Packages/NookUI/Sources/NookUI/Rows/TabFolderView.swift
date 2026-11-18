// Licensed under GPL-3.0. See LICENSE.
//
//  TabFolderView.swift
//  Nook
//
//  Created by Jonathan Caudill on 2025-09-24.
//

import NookTabsCore
import SwiftUI
import NookDesign
import NookWeb

/// A folder header row in the sidebar outline. Its children are separate rows below it.
public struct TabFolderView: View {
    let item: Item
    let spaceID: UUID
    /// True while a drag would drop into this folder.
    var isDropTarget: Bool = false

    @State private var isHovering: Bool = false
    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    @Environment(BrowserWindowState.self) private var windowState
    private let renameState = SidebarRenameState.shared

    @Environment(TabsController.self) private var tabs
    private var isOpen: Bool { tabs.isOpen(folder: item.id) }
    private var isRenaming: Bool { renameState.itemID == item.id }

    public init(
        item: Item,
        spaceID: UUID,
        isDropTarget: Bool = false
    ) {
        self.item = item
        self.spaceID = spaceID
        self.isDropTarget = isDropTarget
    }

    public var body: some View {
        Button(action: {
            RowPress.click {
                withAnimation(NookDesign.Motion.spring) {
                    tabs.toggleFolder(item.id)
                }
            }
        }) {
            HStack(spacing: NookDesign.Tab.iconGap) {
                folderGlyph
                    .frame(width: NookDesign.Size.favicon, height: NookDesign.Size.favicon)
                    .foregroundStyle(tabs.space(spaceID)?.accentColor ?? .secondary)
                    .accessibilityHidden(true)

                if isRenaming {
                    TextField("", text: $draftName)
                        .font(NookDesign.Tab.font)
                        .foregroundStyle(.primary)
                        .textFieldStyle(PlainTextFieldStyle())
                        .autocorrectionDisabled()
                        .focused($nameFieldFocused)
                        .onAppear {
                            draftName = item.displayTitle
                            DispatchQueue.main.async {
                                nameFieldFocused = true
                                selectAllInRenameField()
                            }
                        }
                        .onSubmit { commitRename() }
                        .onEscapeKey { cancelRename() }
                } else {
                    // Long names fade at the end, as tab titles do.
                    Text(item.displayTitle)
                        .font(NookDesign.Tab.font)
                        .lineLimit(1)
                        .hidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Text(item.displayTitle)
                                .font(NookDesign.Tab.font)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .nookTrailingFade()
                }

                Spacer(minLength: NookDesign.Spacing.xs)

                if let status = tabs.liveStatus[item.id] {
                    Image(systemName: "exclamationmark.triangle")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .help(liveStatusHelp(status))
                }

                if !isHovering {
                    Text("\(tabs.children(of: .folder(itemID: item.id)).count)")
                        .font(NookDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                }

                if isHovering && !isRenaming {
                    Menu {
                        folderMenu
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                    }
                    .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.rowButton, radius: NookDesign.Radius.sm))
                }
            }
            .padding(.horizontal, NookDesign.Tab.horizontalPadding)
            .frame(height: NookDesign.Tab.height)
            .frame(maxWidth: .infinity)
            .nookTabSurface(selected: isDropTarget, hovered: isHovering)
        }
        .buttonStyle(NookTabButtonStyle())
        // A double-click renames, as in Arc; its two clicks open and close the folder again.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !isRenaming { startRenaming() } })
        .help(isRenaming ? "" : item.displayTitle)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .padding(.vertical, NookDesign.Tab.verticalInset)
        .onHoverTracking { hovering in
            withAnimation(NookDesign.Motion.quick) {
                isHovering = hovering
            }
        }
        .contextMenu {
            folderMenu
                .environment(windowState)
                .environment(tabs)
        }
        .onChange(of: nameFieldFocused) { _, focused in
            if isRenaming && !focused { commitRename() }
        }
    }

    private var folderMenu: some View {
        FolderContextMenu(itemID: item.id, onRename: startRenaming)
    }

    @ViewBuilder
    private var folderGlyph: some View {
        if let liveSymbol {
            Image(systemName: liveSymbol)
                .font(.system(size: NookDesign.Size.spaceIcon, weight: .medium))
        } else if isOpen {
            OpenFolderGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        } else {
            Image(systemName: "folder")
                .font(.system(size: NookDesign.Size.spaceIcon, weight: .medium))
        }
    }

    // MARK: - Live

    private var liveSymbol: String? {
        switch item.live {
        case nil: return nil
        case .githubIssues?: return isOpen ? "smallcircle.filled.circle.fill" : "smallcircle.filled.circle"
        case .githubNotifications?: return isOpen ? "bell.fill" : "bell"
        case .asanaTasks?: return isOpen ? "checkmark.circle.fill" : "checkmark.circle"
        case let source?:
            guard !isOpen else { return nil }
            return source.feedURL != nil ? "dot.radiowaves.up.forward" : "arrow.triangle.pull"
        }
    }

    private func liveStatusHelp(_ status: TabsController.LiveFolderStatus) -> String {
        if status == .unavailable { return "Live updates aren’t available for this profile" }
        let signedOut = status == .signedOut
        switch item.live {
        case .githubIssues?: return signedOut ? "Sign in to GitHub" : "Couldn't load issues"
        case .githubNotifications?: return signedOut ? "Sign in to GitHub" : "Couldn't load notifications"
        case .asanaTasks?: return signedOut ? "Sign in to Asana" : "Couldn't load tasks"
        case let source? where source.feedURL != nil: return "Couldn't load feed"
        default: return signedOut ? "Sign in to GitHub" : "Couldn't load pull requests"
        }
    }

    // MARK: - Rename

    private func startRenaming() {
        draftName = item.displayTitle
        renameState.itemID = item.id
    }

    private func cancelRename() {
        renameState.itemID = nil
        nameFieldFocused = false
    }

    private func commitRename() {
        guard isRenaming else { return }
        let newName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty && newName != item.displayTitle {
            tabs.rename(item.id, newName)
        }
        cancelRename()
    }
}

/// SF Symbols provides a closed folder, so draw the open front and tab in the same-sized slot.
private struct OpenFolderGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 16, y: rect.minY + rect.height * y / 16)
        }

        var path = Path()
        path.move(to: point(1.5, 12.8))
        path.addLine(to: point(1.5, 4))
        path.addQuadCurve(to: point(2.5, 3), control: point(1.5, 3))
        path.addLine(to: point(6, 3))
        path.addLine(to: point(7.5, 4.5))
        path.addLine(to: point(12, 4.5))
        path.addQuadCurve(to: point(13, 5.5), control: point(13, 4.5))
        path.addLine(to: point(13, 7))
        path.move(to: point(1.5, 12.8))
        path.addLine(to: point(3.7, 7))
        path.addLine(to: point(15, 7))
        path.addLine(to: point(12.8, 12.8))
        path.closeSubpath()
        return path
    }
}
