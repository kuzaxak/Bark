// Licensed under GPL-3.0. See LICENSE.
//
//  JoinMeetingRow.swift
//  Nook
//
//  The row under the favorites that joins the current call, as in Arc: from ten minutes before a
//  meeting with a call link starts until it ends, in a space with a Calendar favorite.
//

import SwiftUI
import NookDesign
import NookUI
import NookWeb

struct JoinMeetingRow: View {
    let spaceID: UUID

    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovering = false

    private let live = LiveFavorites.shared

    var body: some View {
        if LiveFavorites.showsMeetings(inSpace: spaceID, window: windowState, tabs: tabs),
           let meeting = Meetings.joinable(live.meetings, at: live.now, hidden: live.hiddenJoins),
           let link = meeting.conferenceURL {
            let title = meeting.title.isEmpty ? "Meeting" : meeting.title
            HStack(spacing: NookDesign.Spacing.md) {
                Group {
                    if isHovering {
                        Button {
                            live.hideJoin(meeting)
                        } label: {
                            Image(systemName: "xmark")
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Hide Until the Meeting Ends")
                    } else {
                        Image(systemName: "video")
                    }
                }
                .font(.system(size: NookDesign.Size.rowGlyph, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: NookDesign.Size.favicon)
                Text(title)
                    .font(NookDesign.Font.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button {
                    tabs.open(url: link, in: windowState, placement: .newTab)
                } label: {
                    Text("Join")
                        .font(NookDesign.Font.label)
                        .foregroundStyle(NookDesign.Surface.windowBackground)
                        .padding(.horizontal, NookDesign.Spacing.md)
                        .padding(.vertical, NookDesign.Spacing.xs)
                        .background(Color.primary, in: NookDesign.Radius.shape(NookDesign.Radius.sm))
                        .contentShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
                }
                .buttonStyle(.plain)
                .help("Join \(title)")
            }
            .padding(.horizontal, NookDesign.Spacing.rowPadding)
            .frame(height: NookDesign.Size.row)
            .background(isHovering ? NookDesign.Surface.fill : Color.clear, in: NookDesign.Radius.shape(NookDesign.Radius.md))
            .onHoverTracking { isHovering = $0 }
        }
    }
}
