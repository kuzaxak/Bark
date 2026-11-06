// Licensed under GPL-3.0. See LICENSE.
//
//  GoogleFavorite.swift
//  Nook
//
//  Gmail and Google Calendar favorites: which signed-in account each one is, and the pages its
//  hover card opens.
//

import Foundation

public enum GoogleFavorite: Equatable, Sendable {
    case calendar(account: Int)
    case mail(account: Int)

    /// A favorite on mail.google.com or calendar.google.com. The account is the N of /mail/u/N/
    /// or /calendar/u/N/, which is how Google tells signed-in accounts apart; 0 without one.
    public init?(url: URL?) {
        guard let url else { return nil }
        let parts = url.path.split(separator: "/")
        let account = parts.count >= 3 && parts[1] == "u" ? Int(parts[2]).map { max(0, $0) } ?? 0 : 0
        switch url.host?.lowercased() {
        case "mail.google.com": self = .mail(account: account)
        case "calendar.google.com": self = .calendar(account: account)
        default: return nil
        }
    }

    public var account: Int {
        switch self {
        case .calendar(let account), .mail(let account): return account
        }
    }

    public static func mailFeed(account: Int) -> URL {
        URL(string: "https://mail.google.com/mail/u/\(account)/feed/atom")!
    }

    public static func compose(account: Int) -> URL {
        URL(string: "https://mail.google.com/mail/u/\(account)/#inbox?compose=new")!
    }

    public static func newEvent(account: Int) -> URL {
        calendarPage("r/eventedit", account: account)
    }

    /// The day view on `date`'s day.
    public static func day(_ date: Date, account: Int, calendar: Calendar = .current) -> URL {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return calendarPage("r/day/\(day.year ?? 0)/\(day.month ?? 0)/\(day.day ?? 0)", account: account)
    }

    private static func calendarPage(_ page: String, account: Int) -> URL {
        URL(string: "https://calendar.google.com/calendar/" + (account == 0 ? "" : "u/\(account)/") + page)!
    }
}
