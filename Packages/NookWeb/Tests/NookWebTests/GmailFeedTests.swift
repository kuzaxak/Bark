// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookWeb

private func utc(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: hour, minute: minute, second: second))!
}

/// Gmail's unread feed (Atom 0.3), as mail.google.com/mail/u/N/feed/atom answers it.
private func feed(fullcount: String? = "27", entries: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <feed version="0.3" xmlns="http://purl.org/atom/ns#">
    <title>Gmail - Inbox for jane@example.com</title>
    <tagline>New messages in your Gmail Inbox</tagline>
    \(fullcount.map { "<fullcount>\($0)</fullcount>" } ?? "")
    <link rel="alternate" href="https://mail.google.com/mail" type="text/html" />
    <modified>2026-11-06T13:16:00Z</modified>
    \(entries)
    </feed>
    """.utf8)
}

private func entry(_ subject: String, summary: String = "", link: String, modified: String, name: String, email: String) -> String {
    """
    <entry>
    <title>\(subject)</title>
    <summary>\(summary)</summary>
    <link rel="alternate" href="\(link)" type="text/html" />
    <modified>\(modified)</modified>
    <issued>\(modified)</issued>
    <id>tag:gmail.google.com,2004:\(modified)</id>
    <author><name>\(name)</name><email>\(email)</email></author>
    </entry>
    """
}

private let invite = entry(
    "Notification: some event @ Fri Nov 6", summary: "some event You have been invited by Raman to attend an event",
    link: "http://mail.google.com/mail?account_id=jane@example.com&amp;message_id=19a5&amp;view=conv&amp;extsrc=atom",
    modified: "2026-11-06T13:16:00Z", name: "Google Calendar", email: "calendar-notification@google.com")
private let lunch = entry(
    "Lunch &amp; plans", summary: "Are you free?",
    link: "https://mail.google.com/mail?account_id=jane@example.com&amp;message_id=19a4&amp;view=conv&amp;extsrc=atom",
    modified: "2026-11-06T12:00:00Z", name: "", email: "bob@example.com")

struct GmailFeedParsingTests {
    @Test func readsTheCountAndEachUnreadMessage() throws {
        let inbox = try #require(GmailFeed.parse(feed(entries: invite + lunch)))
        #expect(inbox.unread == 27)
        #expect(inbox.messages == [
            GmailFeed.Message(
                sender: "Google Calendar", subject: "Notification: some event @ Fri Nov 6",
                summary: "some event You have been invited by Raman to attend an event",
                link: URL(string: "https://mail.google.com/mail?account_id=jane@example.com&message_id=19a5&view=conv&extsrc=atom")!,
                modified: utc(13, 16)),
            GmailFeed.Message(
                sender: "bob@example.com", subject: "Lunch & plans", summary: "Are you free?",
                link: URL(string: "https://mail.google.com/mail?account_id=jane@example.com&message_id=19a4&view=conv&extsrc=atom")!,
                modified: utc(12)),
        ])
    }

    @Test func theNewestIsTheLatestModifiedWhateverTheOrder() throws {
        let inbox = try #require(GmailFeed.parse(feed(entries: lunch + invite)))
        #expect(inbox.newest?.subject == "Notification: some event @ Fri Nov 6")
    }

    @Test func withoutFullcountTheEntriesAreTheCount() throws {
        #expect(try #require(GmailFeed.parse(feed(fullcount: nil, entries: invite + lunch))).unread == 2)
    }

    @Test func anEmptyInboxHasNothingNew() throws {
        let inbox = try #require(GmailFeed.parse(feed(fullcount: "0", entries: "")))
        #expect(inbox.unread == 0)
        #expect(inbox.newest == nil)
    }

    @Test func entriesLinkingOffGmailAreDropped() throws {
        let offsite = entry("Elsewhere", link: "https://example.com/x", modified: "2026-11-06T13:00:00Z", name: "X", email: "x@example.com")
        let inbox = try #require(GmailFeed.parse(feed(entries: offsite + lunch)))
        #expect(inbox.messages.map(\.subject) == ["Lunch & plans"])
    }

    @Test func otherDocumentsAreNotAFeed() {
        #expect(GmailFeed.parse(Data("<html><body>Sign in</body></html>".utf8)) == nil)
        #expect(GmailFeed.parse(Data("not xml".utf8)) == nil)
    }
}

struct GmailFeedResponseTests {
    @Test func aFeedIsTheInbox() {
        guard case .inbox(let inbox) = GmailFeed.outcome(status: 200, data: feed(entries: invite)) else {
            Issue.record("expected an inbox")
            return
        }
        #expect(inbox.unread == 27)
    }

    @Test func unauthorizedOrALoginRedirectIsSignedOut() {
        #expect(GmailFeed.outcome(status: 401, data: Data()) == .signedOut)
        #expect(GmailFeed.outcome(status: 302, data: Data()) == .signedOut)
    }

    @Test func anythingElseFailed() {
        #expect(GmailFeed.outcome(status: 200, data: Data("<html></html>".utf8)) == .failed)
        #expect(GmailFeed.outcome(status: 500, data: feed(entries: invite)) == .failed)
        #expect(GmailFeed.outcome(status: 403, data: Data()) == .failed)
    }

    @Test func retriesBackOffAfterFailures() {
        #expect(GmailFeed.retryDelay(afterFailures: 0) == 120)
        #expect(GmailFeed.retryDelay(afterFailures: 1) == 240)
        #expect(GmailFeed.retryDelay(afterFailures: 3) == 960)
        #expect(GmailFeed.retryDelay(afterFailures: 4) == 1800)
        #expect(GmailFeed.retryDelay(afterFailures: 50) == 1800)
    }
}

/// The fallback count, from the Gmail tab's title.
struct GmailTitleTests {
    @Test func readsTheInboxCount() {
        #expect(GmailFeed.unreadCount(title: "Inbox (3) - jane@example.com - Gmail") == 3)
        #expect(GmailFeed.unreadCount(title: "Inbox (1,234) - jane@example.com - Gmail") == 1234)
        #expect(GmailFeed.unreadCount(title: "Inbox - jane@example.com - Gmail") == 0)
    }

    @Test func otherPagesSayNothing() {
        #expect(GmailFeed.unreadCount(title: "Lunch & plans - jane@example.com - Gmail") == nil)
        #expect(GmailFeed.unreadCount(title: "Inboxes (3) - jane@example.com - Gmail") == nil)
        #expect(GmailFeed.unreadCount(title: "Gmail") == nil)
        #expect(GmailFeed.unreadCount(title: "") == nil)
        #expect(GmailFeed.unreadCount(title: nil) == nil)
    }
}

/// "4m" beside the newest message.
struct GmailAgeTests {
    @Test func saysHowLongAgoInTheLargestWholeUnit() {
        let now = utc(13, 20)
        #expect(GmailFeed.age(of: now.addingTimeInterval(-30), now: now) == "now")
        #expect(GmailFeed.age(of: now.addingTimeInterval(60), now: now) == "now")
        #expect(GmailFeed.age(of: now.addingTimeInterval(-4 * 60), now: now) == "4m")
        #expect(GmailFeed.age(of: now.addingTimeInterval(-3599), now: now) == "59m")
        #expect(GmailFeed.age(of: now.addingTimeInterval(-2 * 3600), now: now) == "2h")
        #expect(GmailFeed.age(of: now.addingTimeInterval(-3 * 86400), now: now) == "3d")
    }
}
