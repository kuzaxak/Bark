// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookWeb

/// Which favorites are Gmail or Google Calendar, which signed-in account they are, and the
/// pages their hover cards open.
struct GoogleFavoriteTests {
    private func favorite(_ string: String?) -> GoogleFavorite? {
        GoogleFavorite(url: string.flatMap(URL.init(string:)))
    }

    @Test func gmailTakesTheAccountFromItsPath() {
        #expect(favorite("https://mail.google.com/mail/u/2/#inbox") == .mail(account: 2))
        #expect(favorite("https://mail.google.com/mail/u/1") == .mail(account: 1))
        #expect(favorite("https://mail.google.com/mail/u/0/") == .mail(account: 0))
        #expect(favorite("https://mail.google.com/mail/") == .mail(account: 0))
        #expect(favorite("https://mail.google.com/mail/u/x/") == .mail(account: 0))
    }

    @Test func calendarTakesTheAccountFromItsPath() {
        #expect(favorite("https://calendar.google.com/calendar/u/1/r/week") == .calendar(account: 1))
        #expect(favorite("https://calendar.google.com/calendar/r") == .calendar(account: 0))
    }

    @Test func onlyGmailAndCalendarPagesCount() {
        #expect(favorite("https://mail.google.com/chat/u/0/") == nil)
        #expect(favorite("https://mail.google.com/") == nil)
        #expect(favorite("https://mail.google.com/calendar/u/0/") == nil)
        #expect(favorite("https://calendar.google.com/") == nil)
        #expect(favorite("https://calendar.google.com/mail/u/0/") == nil)
    }

    @Test func chromiumShowsCalendarOnceTheAppDeclaresCalendarAccess() {
        #expect(GoogleFavorite.calendar(account: 0).isLiveInChromium(engineFetch: true, declaresCalendarAccess: true))
        #expect(GoogleFavorite.calendar(account: 2).isLiveInChromium(engineFetch: false, declaresCalendarAccess: true))
        #expect(!GoogleFavorite.calendar(account: 0).isLiveInChromium(engineFetch: true, declaresCalendarAccess: false))
        #expect(GoogleFavorite.mail(account: 1).isLiveInChromium(engineFetch: true, declaresCalendarAccess: false))
        #expect(!GoogleFavorite.mail(account: 1).isLiveInChromium(engineFetch: false, declaresCalendarAccess: true))
    }

    @Test func otherSitesAreNotGoogleFavorites() {
        #expect(favorite("https://www.google.com/mail/u/1/") == nil)
        #expect(favorite("https://mail.google.com.example.com/mail/") == nil)
        #expect(favorite("https://example.com") == nil)
        #expect(favorite(nil) == nil)
    }

    @Test func gmailPages() {
        #expect(GoogleFavorite.mailFeed(account: 2).absoluteString == "https://mail.google.com/mail/u/2/feed/atom")
        #expect(GoogleFavorite.compose(account: 0).absoluteString == "https://mail.google.com/mail/u/0/#inbox?compose=new")
    }

    @Test func calendarPages() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23))!
        #expect(GoogleFavorite.newEvent(account: 0).absoluteString == "https://calendar.google.com/calendar/r/eventedit")
        #expect(GoogleFavorite.newEvent(account: 1).absoluteString == "https://calendar.google.com/calendar/u/1/r/eventedit")
        #expect(GoogleFavorite.day(day, account: 0, calendar: utc).absoluteString == "https://calendar.google.com/calendar/r/day/2026/11/6")
        #expect(GoogleFavorite.day(day, account: 3, calendar: utc).absoluteString == "https://calendar.google.com/calendar/u/3/r/day/2026/11/6")
    }
}
