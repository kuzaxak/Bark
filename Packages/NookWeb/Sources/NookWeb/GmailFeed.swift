// Licensed under GPL-3.0. See LICENSE.
//
//  GmailFeed.swift
//  Nook
//
//  A Gmail favorite's unread mail, read from Gmail's unread feed with the favorite's own
//  sign-in. Nothing read here is logged or stored.
//

import Foundation

public enum GmailFeed {
    public struct Message: Equatable, Sendable {
        public let sender: String
        public let subject: String
        public let summary: String
        public let link: URL
        public let modified: Date
    }

    public struct Inbox: Equatable, Sendable {
        /// Unread conversations in the inbox; the feed lists only the newest of them.
        public let unread: Int
        public let messages: [Message]

        public var newest: Message? { messages.max { $0.modified < $1.modified } }
    }

    public enum Outcome: Equatable, Sendable {
        case inbox(Inbox)
        /// No one is signed in to that account in the favorite's profile.
        case signedOut
        case failed
    }

    /// Google's sign-in cookies and Gmail's own; no other site's.
    private static let cookieDomains: Set<String> = ["google.com", ".google.com", "mail.google.com", ".mail.google.com"]

    static func fetch(account: Int, cookies: [HTTPCookie]) async -> Outcome {
        do {
            let (data, status) = try await LiveFetch.get(GoogleFavorite.mailFeed(account: account), cookies: cookies, domains: cookieDomains)
            return outcome(status: status, data: data)
        } catch LiveFetch.Failure.signedOut {
            return .signedOut
        } catch {
            return .failed
        }
    }

    /// Signed out, the feed answers 401 or redirects to the sign-in page.
    static func outcome(status: Int, data: Data) -> Outcome {
        if status == 401 || (300..<400).contains(status) { return .signedOut }
        guard status == 200, let inbox = parse(data) else { return .failed }
        return .inbox(inbox)
    }

    /// The feed's `fullcount` and entries; nil when the data is not the feed.
    static func parse(_ data: Data) -> Inbox? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawFeed else { return nil }
        return Inbox(unread: reader.fullcount ?? reader.messages.count, messages: reader.messages)
    }

    /// The regular wait between reads, doubled after each failure up to half an hour.
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(30 * 60, 120 * pow(2, Double(min(failures, 10))))
    }

    /// The count in a Gmail tab's title, "Inbox (3) - …"; 0 for "Inbox - …", nil on other pages.
    public static func unreadCount(title: String?) -> Int? {
        guard let title, title.hasPrefix("Inbox") else { return nil }
        let rest = title.dropFirst("Inbox".count)
        if rest.hasPrefix(" - ") { return 0 }
        guard rest.hasPrefix(" ("), let close = rest.firstIndex(of: ")") else { return nil }
        return Int(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close].filter(\.isNumber)))
    }

    /// The count a Gmail favorite shows: the feed's, unless the loaded tab's title shows a count
    /// and changed after the feed was read; the title's count without a feed.
    public static func unread(feed: (count: Int, at: Date)?, title: String?, titleChangedAt: Date?) -> Int {
        let fromTitle = unreadCount(title: title)
        guard let feed else { return fromTitle ?? 0 }
        if let fromTitle, let titleChangedAt, titleChangedAt > feed.at { return fromTitle }
        return feed.count
    }

    /// How long ago, in the largest whole unit: "now", "4m", "2h", "3d".
    public static func age(of date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var sawFeed = false
        var fullcount: Int?
        var messages: [Message] = []
        private var inEntry = false
        private var inAuthor = false
        private var fields: [String: String] = [:]
        private var link: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "feed": sawFeed = true
            case "entry": inEntry = true; fields = [:]; link = nil
            case "author" where inEntry: inAuthor = true
            case "link" where inEntry && link == nil: link = attributes["href"]
            default: break
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            guard inEntry else {
                if name == "fullcount" { fullcount = Int(value) }
                return
            }
            switch name {
            case "name" where inAuthor, "email" where inAuthor, "title", "summary", "modified": fields[name] = value
            case "author": inAuthor = false
            case "entry":
                inEntry = false
                if let message { messages.append(message) }
            default: break
            }
        }

        /// The entry, when it links to a Gmail conversation. The feed links over http.
        private var message: Message? {
            guard let href = link, var components = URLComponents(string: href),
                  components.host?.lowercased() == "mail.google.com",
                  let modified = fields["modified"].flatMap({ try? Date($0, strategy: .iso8601) }) else { return nil }
            components.scheme = "https"
            guard let url = components.url else { return nil }
            let name = fields["name"] ?? ""
            return Message(sender: name.isEmpty ? fields["email"] ?? "" : name, subject: fields["title"] ?? "",
                           summary: fields["summary"] ?? "", link: url, modified: modified)
        }
    }
}

extension TabsController {
    /// A Gmail favorite's unread mail, read with the cookies of its space's profile.
    public func gmailInbox(inSpace spaceID: UUID, account: Int) async -> GmailFeed.Outcome {
        guard let profile = profile(forSpace: spaceID) else { return .failed }
        let cookies = await profile.dataStore.httpCookieStore.allCookies()
        return await GmailFeed.fetch(account: account, cookies: cookies)
    }
}
