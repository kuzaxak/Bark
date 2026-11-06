// Licensed under GPL-3.0. See LICENSE.
//
//  Meetings.swift
//  Nook
//
//  What a Google Calendar favorite shows of the person's macOS Calendar events: the countdown
//  under its icon, the Join row under the favorites and the hover timeline. Foundation only;
//  the app reads the events through EventKit.
//

import Foundation

/// One calendar event, as the favorites need it.
public struct Meeting: Identifiable, Equatable, Sendable {
    /// Unique per occurrence: a repeating event's occurrences share their event identifier.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let conferenceURL: URL?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, conferenceURL: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.conferenceURL = conferenceURL
    }
}

/// The video call link in an event: Google Meet, Zoom, Microsoft Teams or Webex.
public enum ConferenceLink {
    /// The first call link in `url`, then `location`, then `notes`.
    public static func find(url: URL?, location: String?, notes: String?) -> URL? {
        [url?.absoluteString, location, notes].lazy.compactMap { $0 }.compactMap(first(in:)).first
    }

    private static let token = try! NSRegularExpression(
        pattern: #"(?:https?://)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/[^\s<>"]*"#, options: .caseInsensitive)
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)]}'\"*")

    private static func first(in text: String) -> URL? {
        let ns = text as NSString
        for match in token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var candidate = ns.substring(with: match.range)
            while let last = candidate.unicodeScalars.last, trailing.contains(last) { candidate.removeLast() }
            if !candidate.lowercased().hasPrefix("http") { candidate = "https://" + candidate }
            if let url = URL(string: candidate), isCall(url) { return url }
        }
        return nil
    }

    private static func isCall(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        switch true {
        case host == "meet.google.com": return path.count > 1
        case on("zoom.us"): return path.hasPrefix("/j/") || path.hasPrefix("/my/")
        case host == "teams.microsoft.com": return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
        case host == "teams.live.com": return path.hasPrefix("/meet/")
        case on("webex.com"):
            let parts = path.split(separator: "/")
            return path.hasPrefix("/meet/") || path.hasPrefix("/join/") || (parts.count == 2 && parts[1] == "j.php")
        default: return false
        }
    }
}

public enum MeetingBadge: Equatable, Sendable {
    case now
    case startsIn(minutes: Int)

    public var text: String {
        switch self {
        case .now: return "now"
        case .startsIn(let minutes): return "in \(minutes)m"
        }
    }
}

public enum Meetings {
    /// How long before a call's start the Join row appears.
    public static let joinLead: TimeInterval = 10 * 60
    private static let countdown: TimeInterval = 60 * 60

    /// "now" while a timed event runs, else the minutes to the next one within the hour, rounded
    /// up so each count lasts a minute and the last is "in 1m".
    public static func badge(_ meetings: [Meeting], at now: Date) -> MeetingBadge? {
        let timed = meetings.filter { !$0.isAllDay }
        if timed.contains(where: { $0.start <= now && now < $0.end }) { return .now }
        guard let next = timed.filter({ $0.start > now }).map(\.start).min(),
              next.timeIntervalSince(now) <= countdown else { return nil }
        return .startsIn(minutes: Int((next.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// The call to offer: a timed event with a call link, from `joinLead` before its start until
    /// its end and not hidden, the earliest start first.
    public static func joinable(_ meetings: [Meeting], at now: Date, hidden: Set<String> = []) -> Meeting? {
        meetings
            .filter { !$0.isAllDay && $0.conferenceURL != nil && !hidden.contains($0.id) }
            .filter { $0.start.addingTimeInterval(-joinLead) <= now && now < $0.end }
            .min { $0.start < $1.start }
    }
}

/// Events laid out on the hours from the current one, in hours from its start.
public struct MeetingTimeline: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public let meeting: Meeting
        public let top: Double
        public let bottom: Double
        /// Overlapping events share the width: this one's column of `columns`.
        public let column: Int
        public let columns: Int
    }

    /// The start of each hour shown.
    public let hours: [Date]
    /// The current time, in hours from the first.
    public let now: Double
    public let blocks: [Block]
    public let allDay: [Meeting]

    public init(meetings: [Meeting], now: Date, calendar: Calendar = .current, span: Int = 6) {
        let start = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let end = start.addingTimeInterval(TimeInterval(span) * 3600)
        func hours(_ date: Date) -> Double { min(Double(span), max(0, date.timeIntervalSince(start) / 3600)) }

        self.hours = (0..<span).map { start.addingTimeInterval(TimeInterval($0) * 3600) }
        self.now = now.timeIntervalSince(start) / 3600
        allDay = meetings.filter { $0.isAllDay && $0.start < end && $0.end > start }

        let shown = meetings
            .filter { !$0.isAllDay && $0.start < end && $0.end > start }
            .map { (meeting: $0, top: hours($0.start), bottom: hours($0.end)) }
            .sorted { $0.top != $1.top ? $0.top < $1.top : $0.bottom > $1.bottom }

        var blocks: [Block] = []
        var cluster: [(meeting: Meeting, top: Double, bottom: Double, column: Int)] = []
        var columnEnds: [Double] = []
        func closeCluster() {
            blocks += cluster.map { Block(meeting: $0.meeting, top: $0.top, bottom: $0.bottom, column: $0.column, columns: columnEnds.count) }
            cluster = []
            columnEnds = []
        }
        for event in shown {
            if let reach = columnEnds.max(), event.top >= reach { closeCluster() }
            let column = columnEnds.firstIndex { $0 <= event.top } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(event.bottom) } else { columnEnds[column] = event.bottom }
            cluster.append((event.meeting, event.top, event.bottom, column))
        }
        closeCluster()
        self.blocks = blocks
    }
}
