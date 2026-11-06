// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookWeb

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func at(_ hour: Int, _ minute: Int = 0, day: Int = 6) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private let now = at(13, 20)
private let meet = "https://meet.google.com/abc-defg-hij"

private func meeting(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false, link: String? = nil) -> Meeting {
    Meeting(id: id, title: id, start: start, end: end, isAllDay: allDay, conferenceURL: link.flatMap(URL.init(string:)))
}

/// The call link a calendar event carries in its URL, location or notes.
struct ConferenceLinkTests {
    private func find(url: String? = nil, location: String? = nil, notes: String? = nil) -> String? {
        ConferenceLink.find(url: url.flatMap(URL.init(string:)), location: location, notes: notes)?.absoluteString
    }

    @Test func findsEachProvidersMeetingLinks() {
        #expect(find(location: "https://meet.google.com/abc-defg-hij") == "https://meet.google.com/abc-defg-hij")
        #expect(find(notes: "Join https://zoom.us/j/123456789?pwd=abc now") == "https://zoom.us/j/123456789?pwd=abc")
        #expect(find(notes: "https://acme.zoom.us/j/987") == "https://acme.zoom.us/j/987")
        #expect(find(notes: "https://us02web.zoom.us/my/jane.doe") == "https://us02web.zoom.us/my/jane.doe")
        #expect(find(notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d")
            == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d")
        #expect(find(notes: "https://teams.live.com/meet/9123456") == "https://teams.live.com/meet/9123456")
        #expect(find(notes: "https://acme.webex.com/meet/jdoe") == "https://acme.webex.com/meet/jdoe")
        #expect(find(notes: "https://acme.webex.com/join/jdoe") == "https://acme.webex.com/join/jdoe")
    }

    @Test func ignoresOtherPagesOfTheSameSites() {
        #expect(find(notes: "https://zoom.us/signin https://meet.google.com/ https://teams.microsoft.com/v2/ https://acme.webex.com/webappng/") == nil)
        #expect(find(notes: "https://notzoom.us/j/123 https://example.com/meet.google.com/abc-defg-hij") == nil)
    }

    @Test func takesTheFirstMatchInURLThenLocationThenNotes() {
        #expect(find(url: "https://calendar.google.com/event?eid=1", location: "https://zoom.us/j/1", notes: meet) == "https://zoom.us/j/1")
        #expect(find(url: meet, location: "https://zoom.us/j/1") == meet)
        #expect(find(location: "Room 4", notes: "Primary https://zoom.us/j/1 backup \(meet)") == "https://zoom.us/j/1")
    }

    @Test func stripsTrailingPunctuation() {
        #expect(find(notes: "Join at \(meet).") == meet)
        #expect(find(notes: "(https://zoom.us/j/123),") == "https://zoom.us/j/123")
        #expect(find(notes: "<https://teams.live.com/meet/9123456>") == "https://teams.live.com/meet/9123456")
    }

    @Test func addsTheSchemeToABareLink() {
        #expect(find(location: "meet.google.com/abc-defg-hij") == meet)
    }

    @Test func nothingWithoutACallLink() {
        #expect(find() == nil)
        #expect(find(location: "Room 4", notes: "Agenda: https://docs.google.com/document/d/1") == nil)
    }
}

/// The capsule under a Calendar favorite's icon.
struct MeetingBadgeTests {
    private func badge(startingIn seconds: TimeInterval) -> String? {
        Meetings.badge([meeting("a", now + seconds, now + seconds + 1800)], at: now)?.text
    }

    @Test func countsDownWholeMinutesWithinTheHour() {
        #expect(badge(startingIn: 1) == "in 1m")
        #expect(badge(startingIn: 60) == "in 1m")
        #expect(badge(startingIn: 61) == "in 2m")
        #expect(badge(startingIn: 28 * 60) == "in 28m")
        #expect(badge(startingIn: 28 * 60 + 1) == "in 29m")
        #expect(badge(startingIn: 3600) == "in 60m")
        #expect(badge(startingIn: 3601) == nil)
    }

    @Test func saysNowWhileAMeetingRuns() {
        #expect(Meetings.badge([meeting("a", now, now + 600)], at: now)?.text == "now")
        #expect(Meetings.badge([meeting("b", now + 300, now + 900), meeting("a", now - 600, now + 1)], at: now)?.text == "now")
        #expect(Meetings.badge([meeting("a", now - 600, now)], at: now) == nil)
    }

    @Test func allDayEventsNeverCount() {
        let allDay = meeting("d", at(0), at(0, day: 7), allDay: true)
        #expect(Meetings.badge([allDay], at: now) == nil)
        #expect(Meetings.badge([allDay, meeting("a", now + 300, now + 900)], at: now)?.text == "in 5m")
    }

    @Test func theSoonestCountsWhateverTheOrder() {
        #expect(Meetings.badge([meeting("late", now + 1800, now + 3600), meeting("soon", now + 600, now + 900)], at: now)?.text == "in 10m")
    }
}

/// The Join row under the favorites.
struct JoinableMeetingTests {
    @Test func showsFromTenMinutesBeforeTheStartUntilTheEnd() {
        let call = meeting("call", now + 600, now + 2400, link: meet)
        #expect(Meetings.joinable([call], at: now)?.id == "call")
        #expect(Meetings.joinable([call], at: now - 1) == nil)
        #expect(Meetings.joinable([call], at: now + 2399)?.id == "call")
        #expect(Meetings.joinable([call], at: now + 2400) == nil)
    }

    @Test func needsACallLinkAndATimedEvent() {
        #expect(Meetings.joinable([meeting("room", now, now + 600)], at: now) == nil)
        #expect(Meetings.joinable([meeting("day", at(0), at(0, day: 7), allDay: true, link: meet)], at: now) == nil)
    }

    @Test func theOneThatStartsFirstWins() {
        let later = meeting("later", now + 300, now + 1200, link: meet)
        let earlier = meeting("earlier", now - 300, now + 1200, link: meet)
        #expect(Meetings.joinable([later, earlier], at: now)?.id == "earlier")
    }

    @Test func aHiddenMeetingStepsAsideForTheNext() {
        let first = meeting("first", now - 300, now + 1200, link: meet)
        let second = meeting("second", now + 300, now + 1200, link: meet)
        #expect(Meetings.joinable([first, second], at: now, hidden: ["first"])?.id == "second")
        #expect(Meetings.joinable([first], at: now, hidden: ["first"]) == nil)
    }
}

/// The Calendar favorite's hover card: six hours from the current one.
struct MeetingTimelineTests {
    private func timeline(_ meetings: [Meeting], at time: Date = now) -> MeetingTimeline {
        MeetingTimeline(meetings: meetings, now: time, calendar: utc)
    }

    private func layout(_ timeline: MeetingTimeline) -> [String] {
        timeline.blocks.map { "\($0.meeting.id) \($0.top)-\($0.bottom) \($0.column)/\($0.columns)" }
    }

    @Test func spansSixHoursFromTheCurrentHour() {
        let empty = timeline([])
        #expect(empty.hours == [at(13), at(14), at(15), at(16), at(17), at(18)])
        #expect(empty.now == 20.0 / 60)
        #expect(empty.blocks.isEmpty && empty.allDay.isEmpty)
    }

    @Test func placesEventsInHoursFromTheStart() {
        #expect(layout(timeline([meeting("a", at(14), at(15, 30))])) == ["a 1.0-2.5 0/1"])
    }

    @Test func clipsEventsToTheSixHours() {
        let clipped = timeline([
            meeting("before", at(11), at(12)),
            meeting("started", at(12, 30), at(13, 30)),
            meeting("runsOver", at(18, 30), at(20)),
            meeting("after", at(19), at(20)),
            meeting("allAlong", at(9), at(22)),
        ])
        #expect(layout(clipped) == ["allAlong 0.0-6.0 0/2", "started 0.0-0.5 1/2", "runsOver 5.5-6.0 1/2"])
    }

    @Test func overlappingEventsSitSideBySide() {
        let overlapping = timeline([
            meeting("d", at(16), at(17)),
            meeting("c", at(15), at(15, 30)),
            meeting("b", at(14, 30), at(15, 30)),
            meeting("a", at(14), at(15)),
        ])
        #expect(layout(overlapping) == ["a 1.0-2.0 0/2", "b 1.5-2.5 1/2", "c 2.0-2.5 0/2", "d 3.0-4.0 0/1"])
    }

    @Test func allDayEventsGoInTheStrip() {
        let today = meeting("today", at(0), at(0, day: 7), allDay: true)
        let yesterday = meeting("yesterday", at(0, day: 5), at(0), allDay: true)
        let withAllDay = timeline([today, yesterday, meeting("a", at(14), at(15))])
        #expect(withAllDay.allDay.map(\.id) == ["today"])
        #expect(layout(withAllDay) == ["a 1.0-2.0 0/1"])
    }

    @Test func runsPastMidnight() {
        let late = timeline([meeting("tomorrow", at(0, day: 7), at(0, day: 8), allDay: true)], at: at(22, 10))
        #expect(late.hours.first == at(22) && late.hours.last == at(3, day: 7))
        #expect(late.allDay.map(\.id) == ["tomorrow"])
    }
}
