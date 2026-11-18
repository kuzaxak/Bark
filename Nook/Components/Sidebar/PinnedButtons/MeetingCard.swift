// Licensed under GPL-3.0. See LICENSE.
//
//  MeetingCard.swift
//  Nook
//
//  The Calendar favorite's hover card, as in Arc: the next six hours of macOS Calendar, or a
//  way to connect it.
//

import SwiftUI
import NookSettings
import NookDesign
import NookWeb

struct MeetingCard: View {
    let account: Int
    let accent: Color
    /// Opens a page in the favorite's tab.
    let open: (URL) -> Void

    private let live = LiveFavorites.shared
    private let hour = NookDesign.Size.timelineHour
    private let lane = NookDesign.Size.favoriteCard - NookDesign.Size.timelineLabel - NookDesign.Spacing.md * 2

    var body: some View {
        switch live.calendarAccess {
        case .granted:
            timeline(MeetingTimeline(meetings: live.meetings, now: live.now))
        case .unknown:
            prompt("\(ProductDisplayName.current) can show your next meetings from macOS Calendar.",
                   button: "Connect Calendar", action: live.connectCalendar)
        case .denied:
            prompt("To see your meetings here, allow \(ProductDisplayName.current) in System Settings → Privacy & Security → Calendars.",
                   button: "Open System Settings", action: live.openCalendarSettings)
        }
    }

    private func prompt(_ message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
            Label("Google Calendar", systemImage: "calendar")
                .font(NookDesign.Font.label)
            Text(message)
                .font(NookDesign.Font.bodyRegular)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .tint(accent)
        }
        .padding(NookDesign.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeline(_ timeline: MeetingTimeline) -> some View {
        VStack(spacing: 0) {
            if !timeline.allDay.isEmpty {
                VStack(spacing: NookDesign.Spacing.xxs) {
                    ForEach(timeline.allDay) { meeting in
                        event(meeting, height: nil)
                    }
                }
                .padding(NookDesign.Spacing.md)
                .overlay(alignment: .bottom) { rule }
            }
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(timeline.hours, id: \.self) { start in
                        Text(start, format: .dateTime.hour())
                            .font(NookDesign.Font.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, NookDesign.Spacing.xs)
                            .padding(.leading, NookDesign.Spacing.md)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .frame(height: hour)
                            .overlay(alignment: .top) { rule }
                    }
                }
                ForEach(timeline.blocks, id: \.meeting.id) { block in
                    let width = lane / CGFloat(block.columns)
                    event(block.meeting, height: max(hour / 3, CGFloat(block.bottom - block.top) * hour) - NookDesign.Spacing.xxs)
                        .frame(width: width - NookDesign.Spacing.xxs)
                        .offset(x: NookDesign.Spacing.md + NookDesign.Size.timelineLabel + width * CGFloat(block.column),
                                y: CGFloat(block.top) * hour)
                }
                nowLine
                    .offset(x: NookDesign.Spacing.md + NookDesign.Size.timelineLabel - NookDesign.Size.timelineNow * 1.5,
                            y: CGFloat(timeline.now) * hour - NookDesign.Size.timelineNow * 1.5)
            }
            .frame(height: hour * CGFloat(timeline.hours.count), alignment: .top)
            .clipped()
        }
        .overlay(alignment: .bottomTrailing) {
            FavoriteCardAddButton(help: "New Event") { open(GoogleFavorite.newEvent(account: account)) }
        }
    }

    /// An event as a block in the accent; a click opens its day in the favorite.
    private func event(_ meeting: Meeting, height: CGFloat?) -> some View {
        Button {
            open(GoogleFavorite.day(meeting.start, account: account))
        } label: {
            Text(meeting.title.isEmpty ? "No Title" : meeting.title)
                .font(NookDesign.Font.caption)
                .foregroundStyle(.primary)
                .lineLimit(height == nil ? 1 : nil)
                .padding(.horizontal, NookDesign.Spacing.xs)
                .padding(.vertical, NookDesign.Spacing.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height, alignment: .topLeading)
                .background(NookDesign.Radius.shape(NookDesign.Radius.sm).fill(accent.opacity(NookDesign.Surface.tintOpacity)))
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
                .contentShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
        }
        .buttonStyle(.plain)
        .help(meeting.title)
    }

    private var nowLine: some View {
        HStack(spacing: 0) {
            Circle()
                .frame(width: NookDesign.Size.timelineNow * 3, height: NookDesign.Size.timelineNow * 3)
            Rectangle()
                .frame(width: lane, height: NookDesign.Size.timelineNow)
        }
        .foregroundStyle(accent)
        .allowsHitTesting(false)
    }

    private var rule: some View {
        Rectangle()
            .fill(NookDesign.Surface.hairline)
            .frame(height: NookDesign.Size.hairlineWidth)
    }
}

/// The round + in the corner of a Gmail or Calendar card, as in Arc.
struct FavoriteCardAddButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: NookDesign.Size.rowGlyph, weight: .semibold))
                .frame(width: NookDesign.Size.iconButton, height: NookDesign.Size.iconButton)
                .background(Circle().fill(NookDesign.Surface.raised))
                .overlay(Circle().strokeBorder(NookDesign.Surface.hairline, lineWidth: NookDesign.Size.hairlineWidth))
                .nookElevation(.raised)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .padding(NookDesign.Spacing.md)
    }
}
