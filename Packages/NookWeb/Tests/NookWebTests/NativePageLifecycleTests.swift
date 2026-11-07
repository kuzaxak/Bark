// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Observation
import Testing
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
@testable import NookWeb

#if os(macOS)
@MainActor
struct NativePageLifecycleTests {
    @Test func nativeTransferReusesSessionAndRepairsOnlySourceSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let page = fixture.host.finishCreate(0)
        let item = try #require(fixture.window.selectedItemID)
        let session = try #require(fixture.tabs.session(for: item))
        let space = try #require(fixture.window.spaceID)
        let otherSpace = try #require(fixture.tabs.createSpace(name: "Other", icon: "house", accentHex: "#123456",
            after: nil, sharingLoginsWith: space))
        let target = BrowserWindowState(); target.spaceID = otherSpace
        fixture.registry.register(target)
        fixture.tabs.attach(window: target, restoringSavedState: false)
        let tree = fixture.tabs.tree, loads = page.loaded.count, selections = fixture.host.selectionCount
        let admitted = fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: target, spaceID: space, select: false)
        #expect(admitted == item && fixture.tabs.session(for: item) === session && session.navigation === page)
        #expect(fixture.window.selectedItemID == nil && target.selectedItemID == nil && target.spaceID == otherSpace)
        #expect(fixture.tabs.tree == tree && page.loaded.count == loads && !page.invalidated)
        #expect(fixture.host.selectionCount == selections && fixture.host.closes.isEmpty && fixture.host.creates.count == 1)
        #expect(fixture.tabs.miniPlayerPages(for: target).count == 1)
        let device = fixture.tabs.device
        #expect(fixture.tabs.adoptNativePage(page, through: fixture.host, in: target, spaceID: space, select: false) == item)
        #expect(fixture.tabs.device == device)
    }

    @Test func sourceSelectionCallbackCannotPublishAnObsoleteTransfer() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let page = fixture.host.finishCreate(0)
        let item = try #require(fixture.window.selectedItemID), space = try #require(fixture.window.spaceID)
        let target = BrowserWindowState(), newer = BrowserWindowState()
        for window in [target, newer] {
            window.spaceID = space; fixture.registry.register(window)
            fixture.tabs.attach(window: window, restoringSavedState: false)
        }
        fixture.host.nativeOwnerWindow = target.id
        var nested: UUID?, observed = false
        withObservationTracking { _ = fixture.window.selectedItemBySpace } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }; observed = true
                fixture.host.nativeOwnerWindow = newer.id
                nested = fixture.tabs.adoptNativePage(page, through: fixture.host,
                    in: newer, spaceID: space, select: false)
            }
        }
        let obsolete = fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: target, spaceID: space, select: false)
        #expect(observed && obsolete == nil && nested == item)
        let session = try #require(fixture.tabs.session(for: item))
        #expect(fixture.tabs.isNativePageOwner(session, in: newer))
        #expect(!fixture.tabs.isNativePageOwner(session, in: target) && session.navigation === page)
        #expect(fixture.host.closes.isEmpty && !page.invalidated)
    }

    @Test func sourceUnregisterDuringTransferDoesNotRecreateItsSavedRecord() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let page = fixture.host.finishCreate(0)
        let item = try #require(fixture.window.selectedItemID), space = try #require(fixture.window.spaceID)
        let target = BrowserWindowState(); target.spaceID = space
        fixture.registry.register(target); fixture.tabs.attach(window: target, restoringSavedState: false)
        fixture.registry.onWindowClose = { id in
            if let source = fixture.registry.windows[id] { fixture.tabs.detach(window: source) }
        }
        var observed = false
        withObservationTracking { _ = fixture.window.selectedItemBySpace } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }; observed = true
                fixture.registry.unregister(fixture.window.id)
            }
        }
        let moved = fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: target, spaceID: space, select: false)
        #expect(observed && moved == item && fixture.registry.windows[fixture.window.id] == nil)
        #expect(!fixture.tabs.device.windows.contains { $0.id == fixture.window.id })
        let session = try #require(fixture.tabs.session(for: item))
        #expect(fixture.tabs.isNativePageOwner(session, in: target) && session.navigation === page)
        #expect(!page.invalidated && fixture.host.closes.isEmpty)
    }

    @Test func pendingNativeCloseRefusesTransferWithoutDeletingItem() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let page = fixture.host.finishCreate(0)
        let item = try #require(fixture.window.selectedItemID), space = try #require(fixture.window.spaceID)
        let target = BrowserWindowState(); target.spaceID = space
        fixture.registry.register(target); fixture.tabs.attach(window: target, restoringSavedState: false)
        fixture.tabs.close(item)
        #expect(fixture.tabs.adoptNativePage(page, through: fixture.host, in: target, spaceID: space, select: false) == nil)
        #expect(fixture.tabs.tree.item(item) != nil && !page.invalidated)
        fixture.host.finishClose(0, admitted: false)
        #expect(fixture.tabs.adoptNativePage(page, through: fixture.host, in: target, spaceID: space, select: false) == item)
    }

    @Test func engineCreatedWindowDoesNotClaimSavedRecordOrInventSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let space = try #require(fixture.window.spaceID)
        let item = try #require(fixture.window.selectedItemID)
        let saved = BrowserWindowState()
        saved.spaceID = space
        saved.selectedItemBySpace = [space: item]
        fixture.tabs.mirror(saved)
        let record = try #require(fixture.tabs.device.windows.first { $0.id == saved.id })
        let native = BrowserWindowState()
        native.spaceID = space
        native.selectedItemBySpace = [space: item]
        fixture.registry.register(native)
        let creates = fixture.host.creates.count
        fixture.tabs.attach(window: native, restoringSavedState: false)
        #expect(native.spaceID == space && native.selectedItemID == nil && native.selectedItemBySpace.isEmpty)
        #expect(fixture.tabs.device.windows.contains(record))
        #expect(!fixture.tabs.device.windows.contains { $0.id == native.id })
        fixture.registry.unregister(native.id) // Failed admission: no saved record is detached/preserved.
        #expect(fixture.tabs.device.windows.contains(record))
        #expect(fixture.host.creates.count == creates && fixture.host.selectionCount == 0)
        let restored = BrowserWindowState()
        fixture.registry.register(restored)
        fixture.tabs.attach(window: restored)
        #expect(restored.spaceID == space && restored.selectedItemID == item)
        #expect(!fixture.tabs.device.windows.contains { $0.id == saved.id })
    }

    @Test func engineCreatedWindowWithoutExplicitSpaceDoesNotBorrowDefaultProfile() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let native = BrowserWindowState()
        fixture.registry.register(native)
        fixture.tabs.attach(window: native, restoringSavedState: false)
        #expect(native.spaceID == nil && native.selectedItemID == nil)
    }

    @Test func adoptingExistingPagePreservesDocumentAndDeduplicatesPublishedAdmission() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let opener = try #require(fixture.window.selectedItemID)
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.tree.dataStoreID(for: space))
        let native = NativeTestPage(profileID: profile)
        let url = URL(string: "https://synthetic.invalid/existing")!
        native.state = PageNavigationState(url: url, title: "Live form", canGoBack: true, canGoForward: false)
        let originalState = native.state
        var publicationSawBoundPage = false
        var repeated: UUID?
        fixture.tabs.onTreeChanged = {
            let page = fixture.tabs.sessions.first { $0.navigation === native }
            publicationSawBoundPage = page != nil
            page?.loadWebViewIfNeeded()
            repeated = fixture.tabs.adoptNativePage(native, through: fixture.host,
                in: fixture.window, spaceID: space, from: opener, select: false)
        }
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, from: opener, select: false))
        fixture.tabs.onTreeChanged = nil
        let session = try #require(fixture.tabs.session(for: adopted))
        #expect(publicationSawBoundPage && repeated == adopted)
        #expect(session.navigation === native && session.profile?.id == profile)
        #expect(session.url == url && session.title == "Live form" && session.canGoBack)
        #expect(fixture.tabs.opener(of: adopted) == opener)
        #expect(fixture.window.selectedItemID == opener)
        #expect(native.loaded.isEmpty && native.stops == 0 && !native.invalidated)
        #expect(native.state == originalState && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
        native.onEvent?(.ownerEnded)
        #expect(session.isUnloaded && fixture.tabs.tree.item(adopted)?.url == url)
        #expect(fixture.host.closes.isEmpty)
    }

    @Test func reentrantSpaceCallbackCannotOverwriteNewerSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let selected = try #require(fixture.window.selectedItemID)
        fixture.host.finishCreate(0)
        let originalSpace = try #require(fixture.window.spaceID)
        let personal = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house", accentHex: "#123456", after: nil))
        let native = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: personal)))
        let delegate = RecordingCertificateDelegate()
        fixture.tabs.sessionDelegate = delegate
        delegate.onSpaceChanged = { _ in
            delegate.onSpaceChanged = nil
            fixture.tabs.select(selected, in: fixture.window)
        }
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: personal, select: true))
        #expect(fixture.window.selectedItemID == selected && fixture.window.spaceID == originalSpace)
        #expect(fixture.tabs.session(for: adopted)?.navigation === native)
        #expect(native.loaded.isEmpty && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func profileObserverReentryCannotReplaceAnAdmittedPageBinding() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.profile(forSpace: space))
        let native = NativeTestPage(profileID: profile.id)
        profile.name = "Stale metadata"
        var nested: UUID?
        var observed = false
        withObservationTracking {
            _ = profile.name
        } onChange: {
            MainActor.assumeIsolated {
                guard !observed else { return }
                observed = true
                nested = fixture.tabs.adoptNativePage(native, through: fixture.host,
                    in: fixture.window, spaceID: space, select: false)
            }
        }
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        #expect(nested == adopted)
        let session = try #require(fixture.tabs.session(for: adopted))
        native.onEvent?(.ownerEnded)
        #expect(session.isUnloaded && fixture.tabs.tree.item(adopted) != nil)
        #expect(native.loaded.isEmpty && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func snapshotReentryReusesNewerBindingInsteadOfOverwritingCallbacks() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let native = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: space)))
        var nested: UUID?
        native.onReadState = {
            nested = fixture.tabs.adoptNativePage(native, through: fixture.host,
                in: fixture.window, spaceID: space, select: false)
        }
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        #expect(nested == adopted)
        let session = try #require(fixture.tabs.session(for: adopted))
        native.onEvent?(.ownerEnded)
        #expect(session.isUnloaded && fixture.tabs.tree.item(adopted) != nil)
        #expect(native.loaded.isEmpty && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func selectedAdoptionBindsExistingResourceAndClosesOnlyAfterActualOutcome() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let native = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: space)))
        let selectedBefore = fixture.host.selectionCount
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: true))
        #expect(fixture.window.selectedItemID == adopted)
        #expect(fixture.host.selectionCount == selectedBefore + 1)
        #expect(native.loaded.isEmpty && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
        fixture.tabs.close(adopted)
        #expect(fixture.tabs.tree.item(adopted) != nil && fixture.host.closes.count == 1)
        fixture.host.finishClose(0, admitted: true)
        #expect(fixture.tabs.tree.item(adopted) == nil && native.invalidated)
        #expect(native.stops == 0 && fixture.host.closes.count == 1)
    }

    @Test func adoptionUsesExplicitInactiveProfileWithoutAnotherCreateOrLoad() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let selected = fixture.window.selectedItemID
        fixture.host.finishCreate(0)
        let personal = try #require(fixture.tabs.createSpace(name: "Personal", icon: "house", accentHex: "#123456", after: nil))
        let profile = try #require(fixture.tabs.tree.dataStoreID(for: personal))
        let native = NativeTestPage(profileID: profile)
        let adopted = try #require(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: personal, select: false))
        #expect(fixture.tabs.session(for: adopted)?.profile?.id == profile)
        #expect(fixture.tabs.tree.spaceID(of: adopted) == personal && fixture.window.selectedItemID == selected)
        #expect(fixture.host.creates.count == 1 && native.loaded.isEmpty && fixture.host.closes.isEmpty)
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: personal, select: true) == adopted)
        #expect(fixture.window.selectedItemID == adopted && fixture.window.spaceID == personal)
        #expect(fixture.host.creates.count == 1 && native.loaded.isEmpty && fixture.host.closes.isEmpty)
    }

    @Test func refusedForeignStaleAndEndingAdoptionsLeaveNativeResourceUntouched() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.tree.dataStoreID(for: space))
        let native = NativeTestPage(profileID: profile)
        let foreign = NativeTestPage(profileID: UUID())
        let original = fixture.tabs.tree
        let selected = fixture.window.selectedItemID
        #expect(fixture.tabs.adoptNativePage(foreign, through: fixture.host,
            in: fixture.window, spaceID: space, select: true) == nil)
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: BrowserWindowState(), spaceID: space, select: false) == nil)
        fixture.host.admitSelection = false
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: true) == nil)
        fixture.host.admitSelection = true
        fixture.host.admitsAdoption = false
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: false) == nil)
        #expect(fixture.tabs.tree == original && fixture.window.selectedItemID == selected)
        #expect(native.onEvent == nil && native.loaded.isEmpty && native.stops == 0 && !native.invalidated)
        #expect(foreign.loaded.isEmpty && !foreign.invalidated && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func reentrantNewerSelectionPreventsPublishingAnObsoleteAdoption() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let selected = try #require(fixture.window.selectedItemID)
        let originalPage = fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let native = NativeTestPage(profileID: try #require(fixture.tabs.tree.dataStoreID(for: space)))
        let original = fixture.tabs.tree
        fixture.host.onSelect = { _, _ in fixture.tabs.select(selected, in: fixture.window) }
        #expect(fixture.tabs.adoptNativePage(native, through: fixture.host,
            in: fixture.window, spaceID: space, select: true) == nil)
        #expect(fixture.tabs.tree == original && fixture.window.selectedItemID == selected)
        #expect(fixture.tabs.sessions.allSatisfy { $0.navigation !== native })
        #expect(native.loaded.isEmpty && !native.invalidated && native.onEvent == nil)
        #expect(originalPage.loaded.count == 1 && fixture.host.creates.count == 1 && fixture.host.closes.isEmpty)
    }

    @Test func nativeSelectionReflectionUpdatesBackgroundModelWithoutActivationOrLoading() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        _ = fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let profile = try #require(fixture.tabs.profile(forSpace: space))
        let page = NativeTestPage(profileID: profile.id)
        let id = try #require(fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        let foreground = BrowserWindowState()
        fixture.registry.register(foreground)
        fixture.registry.setActive(foreground)
        fixture.host.nativeSelectedPage = page
        fixture.host.nativeSelectedWindow = fixture.window.id
        let selections = fixture.host.selectionCount, creates = fixture.host.creates.count
        #expect(fixture.tabs.reflectNativeSelection(id, in: fixture.window))
        #expect(fixture.window.selectedItemID == id)
        #expect(fixture.registry.activeWindowId == foreground.id)
        #expect(fixture.host.selectionCount == selections && fixture.host.creates.count == creates)
        #expect(page.loaded.isEmpty && fixture.host.closes.isEmpty)
        #expect(fixture.tabs.device.windows.first { $0.id == fixture.window.id }?.selectedItemBySpace[space] == id)
    }

    @Test func reflectionRefusesUnselectedPageAndReentrantHeaderSupersession() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let original = fixture.host.finishCreate(0)
        let previous = fixture.window.selectedItemID
        let space = try #require(fixture.window.spaceID)
        let page = NativeTestPage(profileID: original.profileID!)
        let id = try #require(fixture.tabs.adoptNativePage(page, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        let selections = fixture.host.selectionCount
        #expect(!fixture.tabs.reflectNativeSelection(id, in: fixture.window))
        fixture.host.nativeSelectedPage = page
        fixture.host.nativeSelectedWindow = fixture.window.id
        fixture.host.onAcceptNativeSelection = { _, _ in fixture.host.nativeSelectedPage = original }
        #expect(!fixture.tabs.reflectNativeSelection(id, in: fixture.window))
        #expect(fixture.window.selectedItemID == previous && fixture.host.selectionCount == selections)
        #expect(page.loaded.isEmpty && fixture.host.closes.isEmpty)
    }

    @Test func newerNativeReflectionDuringPublicationWinsWithoutFocusOrRollback() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let original = fixture.host.finishCreate(0)
        let space = try #require(fixture.window.spaceID)
        let first = NativeTestPage(profileID: original.profileID!), newer = NativeTestPage(profileID: original.profileID!)
        let firstID = try #require(fixture.tabs.adoptNativePage(first, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        let newerID = try #require(fixture.tabs.adoptNativePage(newer, through: fixture.host,
            in: fixture.window, spaceID: space, select: false))
        fixture.host.nativeSelectedPage = first
        fixture.host.nativeSelectedWindow = fixture.window.id
        let selections = fixture.host.selectionCount
        fixture.tabs.onLeavingTab = { _, window in
            fixture.tabs.onLeavingTab = nil
            fixture.host.nativeSelectedPage = newer
            #expect(fixture.tabs.reflectNativeSelection(newerID, in: window))
        }
        #expect(!fixture.tabs.reflectNativeSelection(firstID, in: fixture.window))
        #expect(fixture.window.selectedItemID == newerID && fixture.host.selectionCount == selections)
        #expect(first.loaded.isEmpty && newer.loaded.isEmpty && fixture.host.closes.isEmpty)
    }

    @Test func ownerEndDuringPendingClosePreservesSavedTabAndCancelsSelection() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let native = fixture.host.finishCreate(0)
        let original = fixture.tabs.tree.item(id)
        let history = fixture.tabs.device.closed
        fixture.tabs.close(id)
        fixture.tabs.select(id, in: fixture.window)
        #expect(fixture.window.nativeSelectionGeneration != nil)
        fixture.host.finishOwnerEnd(0, eventFirst: false)
        #expect(page.isUnloaded && native.invalidated && native.stops == 0)
        #expect(fixture.tabs.tree.item(id) == original)
        #expect(fixture.tabs.device.closed == history)
        #expect(fixture.window.nativeSelectionGeneration == nil)
        #expect(fixture.host.creates.count == 1 && fixture.host.closes.count == 1)
        #expect(fixture.tabs.windowRegistry.windows[fixture.window.id] === fixture.window)
    }

    @Test func ownerEndDuringUnloadDoesNotResumeQueuedReturn() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let native = fixture.host.finishCreate(0)
        page.unload()
        fixture.tabs.select(id, in: fixture.window)
        fixture.host.finishOwnerEnd(0, eventFirst: true)
        #expect(page.isUnloaded && !page.nativeUnloadPending && !page.nativeIsEnding)
        #expect(native.invalidated && native.stops == 0)
        #expect(fixture.tabs.tree.item(id) != nil)
        #expect(fixture.host.creates.count == 1 && fixture.host.closes.count == 1)
    }

    @Test func unsolicitedOwnerEndPreservesMetadataAndIgnoresLateEvents() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        let native = fixture.host.finishCreate(0)
        let original = fixture.tabs.tree.item(id)
        let late = native.onEvent
        var modelClosed = false
        page.onClose = { modelClosed = true }
        native.onEvent?(.ownerEnded)
        late?(.closed)
        late?(.started(URL(string: "https://late.invalid")!))
        #expect(page.isUnloaded && !modelClosed)
        #expect(fixture.tabs.tree.item(id) == original)
        #expect(fixture.host.closes.isEmpty && fixture.host.creates.count == 1)
        #expect(native.invalidated && native.stops == 0)
    }

    @Test func ownerEndCancelsPendingCreationWithoutRemovingItem() throws {
        let fixture = try NativeModelFixture()
        defer { fixture.cleanup() }
        let id = try #require(fixture.window.selectedItemID)
        let page = try #require(fixture.tabs.session(for: id))
        page.nativeOwnerEnded()
        #expect(fixture.host.creates[0].cancelled)
        #expect(fixture.window.nativeSelectionGeneration == nil)
        let late = fixture.host.finishCreate(0)
        #expect(late.loaded.isEmpty && page.isUnloaded)
        fixture.host.finishOwnerEnd(0, eventFirst: false)
        #expect(late.invalidated && fixture.tabs.tree.item(id) != nil)
        #expect(fixture.host.creates.count == 1 && fixture.host.closes.count == 1)
    }

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
            if admitted == .cancelled {
                page.requestNativeRelease { secondAdmitted = $0 == .closed }
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
        var completion: (@MainActor (PageCloseOutcome) -> Void)?
        init(page: NativeTestPage, completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
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
    private(set) var selectionCount = 0
    var admitsAdoption = true
    var nativeOwnerWindow: UUID?
    func canAdoptPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        admitsAdoption && (nativeOwnerWindow == nil || nativeOwnerWindow == window.id) && !(page as! NativeTestPage).invalidated
    }
    func selectPage(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        selectionCount += 1
        let admitted = admitSelection
        let callback = onSelect
        onSelect = nil
        callback?(page, window)
        return admitted
    }
    var nativeSelectedPage: NativeTestPage?
    var nativeSelectedWindow: UUID?
    private var nativeHeaderPage: NativeTestPage?
    var onAcceptNativeSelection: ((any PageNavigation, BrowserWindowState) -> Void)?
    func acceptNativeSelection(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        guard canAdoptPage(page, in: window), nativeSelectedPage === page,
              nativeSelectedWindow == window.id else { return false }
        let callback = onAcceptNativeSelection
        onAcceptNativeSelection = nil
        callback?(page, window)
        guard canAdoptPage(page, in: window), nativeSelectedPage === page,
              nativeSelectedWindow == window.id else { return false }
        nativeHeaderPage = page as? NativeTestPage
        return true
    }
    func isNativeSelection(_ page: any PageNavigation, in window: BrowserWindowState) -> Bool {
        canAdoptPage(page, in: window) && nativeSelectedPage === page &&
            nativeSelectedWindow == window.id && nativeHeaderPage === page
    }
    func closePage(_ page: any PageNavigation, completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
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
    func finishOwnerEnd(_ index: Int, eventFirst: Bool) {
        let request = closes[index]
        let done = request.completion
        request.completion = nil
        let event = request.page.onEvent
        if eventFirst { event?(.ownerEnded) }
        done?(.ownerEnded)
        if !eventFirst { event?(.ownerEnded) }
    }
    func finishClose(_ index: Int, admitted: Bool) {
        let request = closes[index]
        let done = request.completion
        request.completion = nil
        if admitted { request.page.onEvent?(.closed) }
        done?(admitted ? .closed : .cancelled)
    }
}

@MainActor
private final class NativeTestPage: PageNavigation {
    let profileID: UUID?
    private var snapshot = PageNavigationState(url: URL(string: "about:blank")!, canGoBack: false, canGoForward: false)
    var onReadState: (() -> Void)?
    var state: PageNavigationState {
        get {
            let callback = onReadState
            onReadState = nil
            callback?()
            return snapshot
        }
        set { snapshot = newValue }
    }
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
