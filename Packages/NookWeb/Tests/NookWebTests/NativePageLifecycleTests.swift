// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
@testable import NookWeb

#if os(macOS)
@MainActor
struct NativePageLifecycleTests {
    @Test func metadataEditsDoNotVisitNativeOwnership() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        for index in 0..<32 {
            _ = try #require(fixture.tabs.open(url: URL(string: "about:blank#\(index)")!,
                in: fixture.window, placement: .newTab, parent: .tabs(spaceID: space)))
            fixture.host.finishCreate(index + 1)
        }
        let pages = fixture.tabs.sessions
        #expect(pages.count >= 33)
        let visits = fixture.tabs.nativeOwnershipVisits
        for page in pages {
            _ = fixture.tabs.perform(.main, "metadata", undoable: false) {
                var change = try $0.setURL(page.itemID, URL(string: "about:blank#updated")!)
                change.merge(try $0.setPageTitle(page.itemID, "Updated"))
                return change
            }
        }
        #expect(fixture.tabs.nativeOwnershipVisits == visits)
        #expect(pages.allSatisfy { fixture.tabs.tree.item($0.itemID)?.pageTitle == "Updated" })
        let rejected = fixture.tabs.perform(.main, "ownership change") {
            try $0.setProfile(space, to: UUID(), name: nil, kept: [])
        }
        #expect(rejected == nil)
        #expect(fixture.tabs.nativeOwnershipVisits > visits,
            "The same counter must observe actual structural admission work")
    }

    @Test func bulkUnloadProtectsUnknownNativeActivity() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let first = try #require(fixture.window.selectedItemID)
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        _ = fixture.tabs.open(url: URL(string: "about:blank#other")!, in: fixture.window,
            placement: .newTab, parent: .tabs(spaceID: space))
        fixture.host.finishCreate(1)
        let page = try #require(fixture.tabs.session(for: first))
        #expect(fixture.tabs.inactiveUnloadProtectionReason(for: page) == .unknownNativeActivity)
        fixture.tabs.unloadAllHidden()
        #expect(fixture.host.closes.isEmpty && !page.isUnloaded)
    }

    @Test func selectionCoalescesCreationAndUsesActualProfileIdentity() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        page.loadWebViewIfNeeded()
        page.loadWebViewIfNeeded()
        fixture.tabs.select(id, in: fixture.window)
        #expect(fixture.host.creates.count == 1)
        let target = URL(string: "https://synthetic.invalid/latest")!
        page.load(target)
        let navigation = fixture.host.finishCreate(0)
        #expect(navigation.loaded == [target])
        #expect(navigation.profileID == page.profile?.id)
        #expect(page.webView == nil)
        fixture.tabs.select(id, in: fixture.window)
        #expect(fixture.host.creates.count == 1 && navigation.loaded == [target])
        let space = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: nil))
        let other = try #require(fixture.tabs.open(url: URL(string: "about:blank#personal")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: space)))
        #expect(fixture.window.selectedItemID == id, "No model admission before native admission")
        let second = fixture.host.finishCreate(1)
        #expect(fixture.window.selectedItemID == other)
        #expect(second.profileID == fixture.tabs.profile(forSpace: space)?.id)
        #expect(second.profileID != navigation.profileID)
        #expect(!navigation.invalidated, "Inactive profile retains its live page")
    }

    @Test func closeOfPendingItemReleasesLateCreateWithoutRevival() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        fixture.tabs.close(id)
        #expect(fixture.host.creates[0].cancelled)
        #expect(fixture.tabs.tree.item(id) == nil)
        let late = fixture.host.finishCreate(0)
        #expect(late.loaded.isEmpty)
        #expect(fixture.host.closes.count == 1)
        fixture.host.finishClose(0, admitted: true)
        #expect(late.invalidated)
        #expect(fixture.tabs.session(for: id) == nil && fixture.tabs.tree.item(id) == nil)
    }

    @Test func cancellationKeepsPageAndCloseCommitsMetadataOnlyOnce() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let navigation = fixture.host.finishCreate(0)
        let closedBefore = fixture.tabs.device.closed.count
        fixture.tabs.close(id)
        #expect(fixture.tabs.tree.item(id) != nil && page.navigation === navigation)
        fixture.host.finishClose(0, admitted: false)
        #expect(fixture.tabs.tree.item(id) != nil && fixture.tabs.session(for: id) === page)
        #expect(!navigation.invalidated && !page.isUnloaded)
        fixture.tabs.close(id)
        fixture.host.finishClose(1, admitted: true)
        #expect(fixture.tabs.tree.item(id) == nil)
        #expect(fixture.tabs.device.closed.count == closedBefore + 1)
        #expect(navigation.invalidated && navigation.stops == 0)
        #expect(fixture.host.closes.count == 2, "CLOSED must not recursively dispatch close")
    }

    @Test func unloadKeepsItemAndReturnDuringReleaseRestoresWithoutSecondClick() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let navigation = fixture.host.finishCreate(0)
        let original = fixture.tabs.tree.item(id)
        let closedBefore = fixture.tabs.device.closed.count
        page.unload()
        page.unload()
        #expect(fixture.host.closes.count == 1)
        fixture.tabs.select(id, in: fixture.window)
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.tabs.tree.item(id) == original)
        #expect(fixture.tabs.device.closed.count == closedBefore)
        #expect(navigation.invalidated)
        #expect(fixture.host.creates.count == 2, "Queued return resumes after actual release")
        let replacement = fixture.host.finishCreate(1)
        #expect(fixture.window.selectedItemID == id && !page.isUnloaded)
        #expect(replacement.loaded.count == 1)
    }

    @Test func refusedSelectionAndFailedPreparationKeepPreviousItemAndSpace() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let initial = try #require(fixture.window.selectedItemID)
        _ = fixture.host.finishCreate(0)
        let previousSpace = fixture.window.spaceID
        let space = try #require(fixture.tabs.createSpace(name: "Other", icon: "house",
            accentHex: "#123456", after: nil))
        let other = try #require(fixture.tabs.open(url: URL(string: "about:blank#other")!,
            in: fixture.window, placement: .newTab, parent: .tabs(spaceID: space)))
        fixture.host.admitSelection = false
        _ = fixture.host.finishCreate(1)
        #expect(fixture.window.selectedItemID == initial && fixture.window.spaceID == previousSpace)
        #expect(fixture.tabs.tree.item(other) != nil)
        fixture.host.admitSelection = true
        fixture.tabs.select(other, in: fixture.window)
        #expect(fixture.window.selectedItemID == other && fixture.window.spaceID == space)
        let third = try #require(fixture.tabs.open(url: URL(string: "about:blank#fails")!,
            in: fixture.window, placement: .newTab))
        fixture.host.failCreate(2)
        #expect(fixture.window.selectedItemID == other && fixture.tabs.tree.item(third) != nil)
    }

    @Test func profileChangeAndWindowRemovalCancelPendingCreation() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let space = try #require(fixture.window.spaceID)
        // Actual tree-edit path models an incoming sync edit; the user-facing
        // native reassignment action remains intentionally unavailable.
        _ = fixture.tabs.perform(.main, "incoming profile change") {
            try $0.setProfile(space, to: UUID(), name: nil, kept: [])
        }
        #expect(fixture.host.creates[0].cancelled)
        #expect(fixture.tabs.session(for: id)?.loadingState == .idle)
        let late = fixture.host.finishCreate(0)
        #expect(late.loaded.isEmpty && fixture.tabs.session(for: id)?.isUnloaded == true)
        fixture.host.finishClose(0, admitted: true)
        fixture.tabs.select(id, in: fixture.window)
        fixture.registry.unregister(fixture.window.id)
        #expect(fixture.host.creates[1].cancelled)
        let afterWindow = fixture.host.finishCreate(1)
        #expect(afterWindow.loaded.isEmpty)
        fixture.host.finishClose(1, admitted: true)
        #expect(afterWindow.invalidated)
    }

    @Test func destructiveSpaceAndUndoPathsDoNotBypassNativeAdmission() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let space = try #require(fixture.window.spaceID)
        let navigation = fixture.host.finishCreate(0)
        let shared = try #require(fixture.tabs.createSpace(name: "Shared", icon: "folder",
            accentHex: "#123456", after: space, sharingLoginsWith: space))
        fixture.tabs.deleteSpace(space)
        #expect(fixture.tabs.tree.space(space) != nil && fixture.tabs.tree.item(id) != nil)
        #expect(fixture.window.selectedItemID == id && !navigation.invalidated)
        var proposed = fixture.tabs.tree
        let deletion = try proposed.close(id, promotingChildren: true).change
        fixture.tabs.apply(deletion)
        #expect(fixture.tabs.tree.item(id) != nil && fixture.window.selectedItemID == id)
        _ = fixture.tabs.perform(.main, "external destructive replacement") {
            try $0.close(id, promotingChildren: true).change
        }
        #expect(fixture.tabs.tree.item(id) != nil)
        fixture.tabs.deleteSpace(shared)
        #expect(fixture.tabs.tree.space(shared) == nil)
        #expect(fixture.host.closes.isEmpty)
    }

    @Test func newerSelectionCancelsOlderPendingPages() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        _ = fixture.host.finishCreate(0)
        let oldSelection = fixture.window.selectedItemID
        let second = try #require(fixture.tabs.open(url: URL(string: "about:blank#second")!,
            in: fixture.window, placement: .newTab))
        let third = try #require(fixture.tabs.open(url: URL(string: "about:blank#third")!,
            in: fixture.window, placement: .newTab))
        #expect(fixture.host.creates[1].cancelled)
        #expect(fixture.window.selectedItemID == oldSelection)
        _ = fixture.host.finishCreate(2)
        #expect(fixture.window.selectedItemID == third)
        let obsolete = fixture.host.finishCreate(1)
        #expect(obsolete.loaded.isEmpty && fixture.window.selectedItemID != second)
        fixture.host.finishClose(0, admitted: true)
        #expect(obsolete.invalidated)
    }

    @Test func reentrantRefusedSelectionCannotEraseNewerIntent() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        _ = fixture.host.finishCreate(0)
        let initial = fixture.window.selectedItemID
        _ = fixture.tabs.open(url: URL(string: "about:blank#second")!,
            in: fixture.window, placement: .newTab)
        let third = try #require(fixture.tabs.open(url: URL(string: "about:blank#third")!,
            in: fixture.window, placement: .background))
        fixture.host.admitSelection = false
        fixture.host.onSelect = { _, _ in
            fixture.tabs.select(third, in: fixture.window)
            fixture.host.admitSelection = true
        }
        _ = fixture.host.finishCreate(1)
        #expect(fixture.window.nativeSelectionGeneration != nil)
        #expect(fixture.window.selectedItemID == initial)
        _ = fixture.host.finishCreate(2)
        #expect(fixture.window.selectedItemID == third)
    }

    @Test func cancellationReentryPreservesNewestSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let initial = try #require(fixture.window.selectedItemID)
        _ = fixture.host.finishCreate(0)
        _ = fixture.tabs.open(url: URL(string: "about:blank#pending")!,
            in: fixture.window, placement: .newTab)
        let newest = try #require(fixture.tabs.open(url: URL(string: "about:blank#newest")!,
            in: fixture.window, placement: .background))
        fixture.host.onCancel = {
            fixture.tabs.select(newest, in: fixture.window)
        }
        fixture.tabs.select(initial, in: fixture.window)
        #expect(fixture.window.nativeSelectionGeneration != nil)
        _ = fixture.host.finishCreate(2)
        #expect(fixture.window.selectedItemID == newest)
        let late = fixture.host.finishCreate(1)
        #expect(late.loaded.isEmpty)
        fixture.host.finishClose(0, admitted: true)
    }

    @Test func refusalCompletionCanStartNewReleaseWithoutLosingGuard() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        _ = fixture.host.finishCreate(0)
        var secondAdmitted = false
        page.requestNativeRelease { admitted in
            if !admitted {
                page.requestNativeRelease { secondAdmitted = $0 }
            }
        }
        fixture.host.finishClose(0, admitted: false)
        #expect(page.nativeIsEnding && page.nativeRelease != nil)
        #expect(fixture.host.closes.count == 2)
        fixture.host.finishClose(1, admitted: true)
        #expect(secondAdmitted && page.isUnloaded)
        #expect(fixture.tabs.tree.item(id) != nil)
    }

    @Test func synchronousCreateCompletionDoesNotCancelAcceptedPage() throws {
        let fixture = try NativeModelFixture(synchronous: true)
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        #expect(fixture.host.creates.count == 1)
        #expect(!fixture.host.creates[0].cancelled)
        #expect(fixture.tabs.session(for: id)?.isUnloaded == false)
        #expect(fixture.host.closes.isEmpty)
    }
}

@MainActor
private final class NativeModelFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite = "NookNativePageTests-\(UUID().uuidString)"
    let tabs: TabsController
    let registry = WindowRegistry()
    let window = BrowserWindowState()
    let host = ControlledNativeHost()
    init(synchronous: Bool = false) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = NookSettingsService(kagiTokenStore: NativeNoTokenStore(), userDefaults: defaults)
        tabs = TabsController(settings: settings, windowRegistry: registry,
            blocker: ContentBlockerManager(settings: settings), sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings), profileEngine: .chromium,
            directory: directory.appendingPathComponent("Tabs"))
        registry.register(window)
        registry.setActive(window)
        tabs.attach(window: window)
        host.synchronous = synchronous
        tabs.nativePageHost = host
    }
    func cleanup() {
        for index in host.creates.indices where host.creates[index].completion != nil { host.failCreate(index) }
        for index in host.closes.indices where host.closes[index].completion != nil { host.finishClose(index, admitted: true) }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct NativeNoTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}

@MainActor
private final class ControlledNativeHost: NativePageHost {
    final class Creation {
        let profileID: UUID
        var cancelled = false
        var completion: (@MainActor (Result<any PageNavigation, Error>) -> Void)?
        init(profileID: UUID, completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void) {
            self.profileID = profileID
            self.completion = completion
        }
    }
    final class Closing {
        let page: NativeTestPage
        var completion: (@MainActor (Bool) -> Void)?
        init(page: NativeTestPage, completion: @escaping @MainActor (Bool) -> Void) {
            self.page = page
            self.completion = completion
        }
    }
    var creates: [Creation] = []
    var closes: [Closing] = []
    var synchronous = false
    var admitSelection = true
    var onSelect: ((any PageNavigation, BrowserWindowState) -> Void)?
    var onCancel: (() -> Void)?
    func createPage(for session: PageSession, profile: Profile, in window: BrowserWindowState,
                    completion: @escaping @MainActor (Result<any PageNavigation, Error>) -> Void) -> (@MainActor () -> Void) {
        let request = Creation(profileID: profile.id, completion: completion)
        creates.append(request)
        if synchronous { _ = finishCreate(creates.count - 1) }
        return { [weak self, weak request] in
            if request?.completion != nil {
                request?.cancelled = true
                let callback = self?.onCancel
                self?.onCancel = nil
                callback?()
            }
        }
    }
    func selectPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        let admitted = admitSelection
        let callback = onSelect
        onSelect = nil
        callback?(page, window)
        return admitted
    }
    func closePage(_ page: any PageNavigation, completion: @escaping @MainActor (Bool) -> Void) {
        closes.append(Closing(page: page as! NativeTestPage, completion: completion))
    }
    @discardableResult func finishCreate(_ index: Int) -> NativeTestPage {
        let request = creates[index]
        let page = NativeTestPage(profileID: request.profileID)
        let done = request.completion
        request.completion = nil
        done?(.success(page))
        return page
    }
    func failCreate(_ index: Int) {
        let request = creates[index]
        let done = request.completion
        request.completion = nil
        done?(.failure(URLError(.cancelled)))
    }
    func finishClose(_ index: Int, admitted: Bool) {
        let request = closes[index]
        let done = request.completion
        request.completion = nil
        if admitted { request.page.onEvent?(.closed) }
        done?(admitted)
    }
}

@MainActor
private final class NativeTestPage: PageNavigation {
    let profileID: UUID?
    var state = PageNavigationState(url: URL(string: "about:blank")!, canGoBack: false, canGoForward: false)
    var onStateChanged: ((PageNavigationState) -> Void)?
    var onEvent: ((PageNavigationEvent) -> Void)?
    var loaded: [URL] = []
    var invalidated = false
    var stops = 0
    init(profileID: UUID) { self.profileID = profileID }
    func load(_ url: URL) { loaded.append(url) }
    func goBack() -> Bool { false }
    func goForward() -> Bool { false }
    func reload() -> Bool { false }
    func stop() { stops += 1 }
    func invalidate() { invalidated = true; onStateChanged = nil; onEvent = nil }
}
#endif
