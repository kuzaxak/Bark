// Licensed under GPL-3.0. See LICENSE.
//
//  LiveFavorites.swift
//  Nook
//
//  What Gmail and Google Calendar favorites show, as in Arc: unread mail from Gmail's feed and
//  the next meeting from macOS Calendar. It runs only while Settings → Appearance → Show
//  meetings and mail on favorites is on and a regular window is on screen, keeps mail in memory
//  only, and never asks for Calendar access by itself.
//

import AppKit
import EventKit
import NookSettings
import NookTabsCore
import NookWeb

@MainActor
@Observable
final class LiveFavorites {
    static let shared = LiveFavorites()

    enum CalendarAccess { case unknown, granted, denied }

    /// Set at each refresh, so countdowns and the Join row follow the clock.
    private(set) var now = Date()
    private(set) var calendarAccess = LiveFavorites.currentCalendarAccess()
    private(set) var meetings: [Meeting] = []
    /// Join rows the person closed, until their meeting ends.
    private(set) var hiddenJoins: Set<String> = []
    /// Each Gmail favorite's last read of its feed, and when that read went out.
    private struct MailRead {
        let outcome: GmailFeed.Outcome
        let at: Date
        let spaceID: UUID
        let profileID: UUID
        let account: Int
    }
    private var mail: [UUID: MailRead] = [:]
    /// When each Gmail favorite's tab title last changed.
    private(set) var titleChanges: [UUID: Date] = [:]

    @ObservationIgnored private weak var tabs: TabsController?
    @ObservationIgnored private weak var windows: WindowRegistry?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Made once, off the main thread, and kept for the app's lifetime.
    @ObservationIgnored private var eventStore: Task<EKEventStore, Never>?
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    /// Bumped by every load and stop, so only the latest load lands.
    @ObservationIgnored private var calendarGeneration = 0
    @ObservationIgnored private var mailFetches: [UUID: MailFetch] = [:]
    @ObservationIgnored private var nativeMailTail: Task<Void, Never>?

    private struct MailFetch {
        var last = Date.distantPast
        var failures = 0
        var request: UUID?
        var task: Task<Void, Never>?
        var profileID: UUID?
        var spaceID: UUID?
        var account: Int?
    }

    /// A hover or a title change reads the feed again after this long, unless the last read failed.
    private static let mailSoon: TimeInterval = 15

    nonisolated static let declaresCalendarAccess = Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil

    private static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    func start(tabs: TabsController, windows: WindowRegistry) {
        guard self.tabs == nil else { return }
        self.tabs = tabs
        self.windows = windows
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NookSettingsService.favoriteMeetingsAndMailDidChange] {
            // Deferred: a closing window is still on screen while its notification is delivered.
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
        }
        observeActiveWindow()
        update()
    }

    /// What `item` shows, or nil: not a Gmail or Calendar favorite, the setting is off, or the
    /// window is private or shows the Agent space.
    static func kind(of item: Item, in window: BrowserWindowState, tabs: TabsController) -> GoogleFavorite? {
        guard tabs.settings.favoriteMeetingsAndMail, !window.isIncognito,
              let spaceID = tabs.spaceID(of: item.id), tabs.space(spaceID)?.isAgent == false,
              let kind = GoogleFavorite(url: item.url) else { return nil }
        guard kind.isLiveInChromium(engineFetch: tabs.nativeLiveFetch != nil, declaresCalendarAccess: Self.declaresCalendarAccess) else { return nil }
        return kind
    }

    /// Whether the space has a Calendar favorite that shows meetings.
    static func showsMeetings(inSpace spaceID: UUID, window: BrowserWindowState, tabs: TabsController) -> Bool {
        tabs.favorites(of: spaceID).contains {
            if case .calendar = kind(of: $0, in: window, tabs: tabs) { return true }
            return false
        }
    }

    /// The pointer rests on a Gmail or Calendar favorite, or its tab's title changed: what it
    /// shows may be out of date.
    func refresh(_ item: Item, kind: GoogleFavorite) {
        guard isEnabled else { return }
        now = Date()
        switch kind {
        case .calendar:
            loadMeetings()
        case .mail(let account):
            guard let spaceID = tabs?.spaceID(of: item.id) else { return }
            fetchMail(item.id, spaceID: spaceID, account: account, soon: true)
        }
    }

    /// The Gmail favorite's tab title changed, as it does when mail arrives or is read.
    func titleChanged(_ item: Item, kind: GoogleFavorite) {
        guard isEnabled, case .mail = kind else { return }
        titleChanges[item.id] = Date()
        refresh(item, kind: kind)
    }

    private func currentMail(_ itemID: UUID) -> MailRead? {
        guard let tabs, let read = mail[itemID], tabs.spaceID(of: itemID) == read.spaceID,
              tabs.tree.dataStoreID(for: read.spaceID) == read.profileID, tabs.isProfileAvailable(read.profileID),
              GoogleFavorite(url: tabs.item(itemID)?.url) == .mail(account: read.account) else { return nil }
        return read
    }
    func mailOutcome(_ itemID: UUID, account: Int) -> GmailFeed.Outcome? {
        guard let read = currentMail(itemID), read.account == account else { return nil }
        return read.outcome
    }

    /// A Gmail favorite's unread count, from its feed and its loaded tab's `title`.
    func unread(_ itemID: UUID, title: String?) -> Int {
        let feed: (count: Int, at: Date)? = currentMail(itemID).flatMap { read in
            guard case .inbox(let inbox) = read.outcome else { return nil }
            return (inbox.unread, read.at)
        }
        return GmailFeed.unread(feed: feed, title: title, titleChangedAt: titleChanges[itemID])
    }

    func connectCalendar() {
        Task {
            _ = try? await calendarStore().requestFullAccessToEvents()
            refresh()
        }
    }

    func openCalendarSettings() {
        NSWorkspace.shared.open(Self.privacySettings)
    }

    func hideJoin(_ meeting: Meeting) {
        hiddenJoins.insert(meeting.id)
    }

    // MARK: - Running

    private var isEnabled: Bool { tabs?.settings.favoriteMeetingsAndMail == true }

    private var anyWindowOnScreen: Bool {
        windows?.allWindows.contains { !$0.isIncognito && $0.window?.occlusionState.contains(.visible) == true } ?? false
    }

    /// A window's handle is set just before it becomes the active one, which may be after its
    /// first occlusion change.
    private func observeActiveWindow() {
        withObservationTracking { _ = windows?.activeWindowId } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observeActiveWindow()
            }
        }
    }

    private func update() {
        if !isEnabled {
            clear()
            if FavoritePreview.shared.live != nil { FavoritePreview.shared.dismiss() }
        }
        let running = isEnabled && anyWindowOnScreen
        guard running != (ticker != nil) else { return }
        if running {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    // Just past the minute, so "now" and the Join row arrive with a meeting's minute.
                    let seconds = 60.5 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
            stopCalendar()
        }
    }

    private func refresh() {
        guard isEnabled else { return }
        now = Date()
        var calendarShown = false
        var gmail: [(id: UUID, spaceID: UUID, account: Int)] = []
        for favorite in googleFavorites() {
            switch favorite.kind {
            case .calendar: calendarShown = true
            case .mail(let account): gmail.append((favorite.id, favorite.spaceID, account))
            }
        }
        if calendarShown { loadMeetings() } else { dropMeetings() }
        keepMail(of: Set(gmail.map(\.id)))
        for favorite in gmail {
            fetchMail(favorite.id, spaceID: favorite.spaceID, account: favorite.account, soon: false)
        }
    }

    /// Gmail and Calendar favorites outside the Agent space, each once, with its own space.
    private func googleFavorites() -> [(id: UUID, spaceID: UUID, kind: GoogleFavorite)] {
        guard let tabs else { return [] }
        var seen: Set<UUID> = []
        return tabs.orderedSpaces.filter { !$0.isAgent }.flatMap { tabs.favorites(of: $0.id) }.compactMap { item in
            guard seen.insert(item.id).inserted, let kind = GoogleFavorite(url: item.url),
                  let spaceID = tabs.spaceID(of: item.id), tabs.space(spaceID)?.isAgent == false else { return nil }
            guard kind.isLiveInChromium(engineFetch: tabs.nativeLiveFetch != nil, declaresCalendarAccess: Self.declaresCalendarAccess) else { return nil }
            return (item.id, spaceID, kind)
        }
    }

    private func clear() {
        dropMeetings()
        if !hiddenJoins.isEmpty { hiddenJoins = [] }
        keepMail(of: [])
    }

    // MARK: - Mail

    /// Reads a Gmail favorite's feed when due: every two minutes, waiting longer after failures.
    /// `soon` shortens a regular wait to `mailSoon`.
    @discardableResult
    func fetchMail(_ itemID: UUID, spaceID: UUID, account: Int, soon: Bool) -> Task<Void, Never>? {
        guard let tabs else { return nil }
        let profileID = tabs.tree.dataStoreID(for: spaceID)
        var fetch = mailFetches[itemID] ?? MailFetch()
        if fetch.profileID != profileID || fetch.spaceID != spaceID || fetch.account != account {
            fetch.task?.cancel()
            fetch = MailFetch(); fetch.profileID = profileID; fetch.spaceID = spaceID; fetch.account = account
            mail[itemID] = nil
        }
        let wait = soon && fetch.failures == 0 ? Self.mailSoon : GmailFeed.retryDelay(afterFailures: fetch.failures)
        // Minute ticks land a few milliseconds either side of the minute.
        if let task = fetch.task { return task }
        guard Date().timeIntervalSince(fetch.last).rounded() >= wait else { return nil }
        let sent = Date()
        fetch.last = sent
        let request = UUID(), profile = profileID
        fetch.request = request
        mailFetches[itemID] = fetch
        // Reuse the existing per-favorite task as its admission claim. Native
        // mail batches (and individual refreshes) run one source at a time,
        // leaving the other profile slot available to the folder batch.
        let previous = nativeMailTail
        let task = Task { @MainActor in
            if let previous { await previous.value }
            guard !Task.isCancelled,
                  tabs.spaceID(of: itemID) == spaceID,
                  tabs.profile(forSpace: spaceID)?.id == profile,
                  GoogleFavorite(url: tabs.item(itemID)?.url) == .mail(account: account) else {
                if mailFetches[itemID]?.request == request {
                    mailFetches[itemID]?.task = nil
                    mailFetches[itemID]?.request = nil
                    mailFetches[itemID]?.last = .distantPast
                }
                return
            }
            let outcome = await tabs.gmailInbox(inSpace: spaceID, account: account, forFavorite: itemID)
            guard var fetch = mailFetches[itemID], fetch.request == request else { return }
            fetch.task = nil; fetch.request = nil
            mailFetches[itemID] = fetch
            guard !Task.isCancelled, tabs.spaceID(of: itemID) == spaceID,
                  tabs.profile(forSpace: spaceID)?.id == profile,
                  GoogleFavorite(url: tabs.item(itemID)?.url) == .mail(account: account) else { return }
            fetch.failures = outcome == .failed ? fetch.failures + 1 : 0
            mailFetches[itemID] = fetch
            if let profile { mail[itemID] = MailRead(outcome: outcome, at: sent, spaceID: spaceID, profileID: profile, account: account) }
        }
        mailFetches[itemID]?.task = task
        nativeMailTail = task
        return task
    }

    /// Forgets the mail of every favorite not in `ids`.
    func keepMail(of ids: Set<UUID>) {
        if ids.isEmpty { nativeMailTail?.cancel() }
        for (id, fetch) in mailFetches where !ids.contains(id) { fetch.task?.cancel() }
        mailFetches = mailFetches.filter { ids.contains($0.key) }
        if mail.keys.contains(where: { !ids.contains($0) }) {
            mail = mail.filter { ids.contains($0.key) }
        }
        if titleChanges.keys.contains(where: { !ids.contains($0) }) {
            titleChanges = titleChanges.filter { ids.contains($0.key) }
        }
    }

    // MARK: - Calendar

    private static func currentCalendarAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    private func loadMeetings() {
        let access = Self.currentCalendarAccess()
        if access != calendarAccess { calendarAccess = access }
        guard access == .granted else { return dropMeetings() }
        calendarGeneration += 1
        let generation = calendarGeneration
        Task {
            let store = await calendarStore()
            guard generation == calendarGeneration else { return }
            if storeObserver == nil {
                storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.loadMeetings() }
                }
            }
            let found = await Task.detached(priority: .utility) { Self.meetings(in: store, around: Date()) }.value
            guard generation == calendarGeneration else { return }
            meetings = found
            hiddenJoins.formIntersection(found.map(\.id))
        }
    }

    private func calendarStore() async -> EKEventStore {
        let making = eventStore ?? Task.detached(priority: .utility) { EKEventStore() }
        eventStore = making
        return await making.value
    }

    private func dropMeetings() {
        stopCalendar()
        if !meetings.isEmpty { meetings = [] }
    }

    private func stopCalendar() {
        calendarGeneration += 1
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
    }

    /// Events from the start of this hour through the timeline's six, from every event calendar.
    /// EventKit reads synchronously; callers run this off the main thread.
    nonisolated private static func meetings(in store: EKEventStore, around now: Date) -> [Meeting] {
        let start = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let predicate = store.predicateForEvents(withStart: start, end: start.addingTimeInterval(6 * 3600), calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled,
                  event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined,
                  let begins = event.startDate, let ends = event.endDate else { return nil }
            return Meeting(
                id: "\(event.calendarItemIdentifier)@\(begins.timeIntervalSince1970)",
                title: event.title ?? "",
                start: begins,
                end: ends,
                isAllDay: event.isAllDay,
                conferenceURL: ConferenceLink.find(url: event.url, location: event.location, notes: event.notes))
        }
    }
}
