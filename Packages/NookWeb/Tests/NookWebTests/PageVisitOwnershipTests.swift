// Licensed under GPL-3.0. See LICENSE.
import Foundation
import SwiftData
import Testing
@testable import NookWeb

@MainActor
struct PageVisitOwnershipTests {
    @Test func visitsUseOnlyTheBoundRegularNativeProfile() async throws {
        let host = try Host(); defer { host.cleanup() }
        let container = try ModelContainer(for: HistoryEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let frontProfile = UUID()
        let history = HistoryManager(context: container.mainContext, profileId: frontProfile)
        host.tabs.history = history
        let session = try #require(host.tabs.selectedSession(in: host.window))
        let bound = try #require(session.profile?.id)
        let navigation = VisitNavigation(profileID: bound)
        session.installNavigation(navigation)
        let wrongProfile = UUID()

        for (path, id) in [("missing", nil), ("mismatched", wrongProfile), ("bound", bound)] {
            let url = URL(string: "https://visits.invalid/\(path)")!
            navigation.profileID = id
            navigation.onEvent?(.started(url))
            session.typedVisitPending = true
            navigation.onEvent?(.committed(url, sameDocument: false))
            navigation.onEvent?(.finished(url, title: path, isReload: false))
            #expect(session.title == path && session.url == url && !session.typedVisitPending)
        }

        #expect(await history.getHistory(profile: bound).entries.map(\.title) == ["bound"])
        #expect(await history.getHistory(profile: frontProfile).entries.isEmpty)
        #expect(await history.getHistory(profile: wrongProfile).entries.isEmpty)
    }

    @Test func unboundSessionCannotFallBackToTheHistoryProfile() async throws {
        let host = try Host(); defer { host.cleanup() }
        let container = try ModelContainer(for: HistoryEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let front = UUID()
        let history = HistoryManager(context: container.mainContext, profileId: front)
        host.tabs.history = history
        let url = URL(string: "https://visits.invalid/unclaimed")!
        let session = PageSession(itemID: UUID(), url: url, title: "Initial", isPrivate: false, controller: host.tabs)
        #expect(session.profile == nil)
        let navigation = VisitNavigation(profileID: nil)
        session.installNavigation(navigation)
        session.typedVisitPending = true
        navigation.onEvent?(.finished(url, title: "Unclaimed", isReload: false))
        #expect(session.title == "Unclaimed" && !session.typedVisitPending)
        #expect(await history.getHistory(profile: front).entries.isEmpty)
    }
}

@MainActor
private final class VisitNavigation: PageNavigation {
    var profileID: UUID?
    let state = PageNavigationState(canGoBack: false, canGoForward: false)
    var onStateChanged: ((PageNavigationState) -> Void)?
    var onEvent: ((PageNavigationEvent) -> Void)?

    init(profileID: UUID?) { self.profileID = profileID }
    func load(_ url: URL) {}
    func goBack() -> Bool { false }
    func goForward() -> Bool { false }
    func reload() -> Bool { false }
    func stop() {}
    func invalidate() { onStateChanged = nil; onEvent = nil }
}
