// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import WebKit
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
@testable import NookWeb

@MainActor
struct ProfileEngineTests {
    #if os(macOS)
    private func liveCallbacks() async {
        for _ in 0..<4 { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
    }

    @Test func nativeLiveGmailUsesExactRegularProfileWithoutWindowsOrWebKit() async throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let work = try #require(tabs.tree.orderedSpaces.first?.id)
        let personal = try #require(tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: work))
        let workID = try #require(tabs.tree.dataStoreID(for: work)), personalID = try #require(tabs.tree.dataStoreID(for: personal))
        var calls: [(UUID, ProfileLiveSource)] = []
        tabs.nativeLiveFetch = { profile, source in
            calls.append((profile, source))
            if profile == workID { return ProfileLiveResponse(data: Data(), status: 302) }
            return ProfileLiveResponse(data: Data("<feed xmlns=\"http://purl.org/atom/ns#\"><fullcount>3</fullcount></feed>".utf8), status: 200)
        }
        #expect(await tabs.gmailInbox(inSpace: work, account: 2) == .signedOut)
        let inbox = await tabs.gmailInbox(inSpace: personal, account: 0)
        guard case .inbox(let value) = inbox else { Issue.record("Expected synthetic inbox"); return }
        #expect(value.unread == 3 && calls.count == 2)
        #expect(calls[0].0 == workID && calls[0].1 == .gmail(account: 2) && calls[1].0 == personalID)
        #expect(await tabs.gmailInbox(inSpace: UUID(), account: 0) == .failed && calls.count == 2)
        #expect(tabs.sessions.isEmpty && tabs.windowRegistry.windows.isEmpty)
        #expect(tabs.profile(forSpace: work)?.webKitDataStore == nil && tabs.profile(forSpace: personal)?.webKitDataStore == nil)
    }

    @Test func nativeLiveFolderReassignmentCancelsAndCannotPublishOldProfileReply() async throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let space = try #require(tabs.tree.orderedSpaces.first?.id)
        let other = try #require(tabs.createSpace(name: "Other", icon: "", accentHex: "#123456", after: space))
        let oldProfile = try #require(tabs.tree.dataStoreID(for: space)), nextProfile = try #require(tabs.tree.dataStoreID(for: other))
        var pending: CheckedContinuation<ProfileLiveResponse, Error>?, cancelled = false
        tabs.nativeLiveFetch = { profile, source in
            #expect(profile == oldProfile && source == .githubPulls)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending = $0 }
            } onCancel: { Task { @MainActor in cancelled = true } }
        }
        let folder = try #require(tabs.createLiveFolder(.githubPulls, in: space))
        await liveCallbacks(); #expect(pending != nil)
        #expect(tabs.perform(.main, "reassignLiveSource", undoable: false) { try $0.setProfile(space, to: nextProfile) } != nil)
        await liveCallbacks(); #expect(cancelled && !tabs.liveRefreshing.contains(folder))
        let body = Data("{\"payload\":{\"pullsDashboardSurfaceContentRoute\":{\"results\":[{\"permalink\":\"https://github.com/synthetic/repo/pull/1\",\"title\":\"Old private data\"}]}}}".utf8)
        pending?.resume(returning: ProfileLiveResponse(data: body, status: 200)); pending = nil
        await liveCallbacks()
        #expect(tabs.children(of: .folder(itemID: folder)).isEmpty)
        #expect(tabs.tree.dataStoreID(for: space) == nextProfile && tabs.sessions.isEmpty)
    }

    @Test func nativeLiveCallerCancellationAndDeletedSourceReleaseWithoutPublishing() async throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let space = try #require(tabs.tree.orderedSpaces.first?.id)
        var pending: CheckedContinuation<ProfileLiveResponse, Error>?, cancellations = 0
        tabs.nativeLiveFetch = { _, _ in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending = $0 }
            } onCancel: { Task { @MainActor in cancellations += 1 } }
        }
        let caller = Task { await tabs.gmailInbox(inSpace: space, account: 0) }
        await liveCallbacks(); caller.cancel(); _ = await caller.value
        await liveCallbacks(); #expect(cancellations == 1)
        pending?.resume(returning: ProfileLiveResponse(data: Data(), status: 200)); pending = nil
        let folder = try #require(tabs.createLiveFolder(.githubIssues, in: space))
        await liveCallbacks(); #expect(pending != nil)
        tabs.remove(folder); await liveCallbacks()
        #expect(cancellations == 2 && !tabs.liveRefreshing.contains(folder))
        pending?.resume(returning: ProfileLiveResponse(data: Data(), status: 200)); pending = nil
        await liveCallbacks(); #expect(tabs.tree.item(folder) == nil)
    }

    @Test func nativeDeveloperModeCannotChangeWebKitConfiguration() throws {
        let native = try ProfileFixture(); defer { native.cleanup() }
        let legacy = try ProfileFixture(); defer { legacy.cleanup() }
        let nativeTabs = native.makeTabs(engine: .chromium)
        let legacyTabs = legacy.makeTabs(engine: .webKit)
        let controller = BrowserConfiguration.webKit.webViewConfiguration.userContentController
        func captureInstalled() -> Bool {
            controller.userScripts.contains { $0.source.hasPrefix(DevCaptureScript.marker) }
        }
        let original = captureInstalled()
        defer { DevCaptureScript.setInstalled(original, in: controller) }
        legacyTabs.setDeveloperMode(true)
        nativeTabs.setDeveloperMode(false)
        #expect(captureInstalled())
        legacyTabs.setDeveloperMode(false)
        nativeTabs.setDeveloperMode(true)
        #expect(!captureInstalled())
        #expect(BrowserConfiguration.webKitAdapter(for: .chromium) == nil)
    }

    @Test func chromiumMetadataHasNoWebKitStorageOrCookieConnection() async {
        let id = UUID()
        let profile = Profile(id: id, name: "Work", icon: "person", engine: .chromium)
        #expect(profile.engine == .chromium)
        #expect(profile.webKitDataStore == nil)
        profile.name = "Renamed"
        profile.icon = "folder"
        #expect(profile.id == id && profile.name == "Renamed")
        #expect(profile.webKitDataStore == nil)
        #expect(await profile.validateDataStore() == false)
        let privateProfile = Profile.createEphemeral(engine: .chromium)
        #expect(privateProfile.isEphemeral && privateProfile.engine == .chromium)
        #expect(privateProfile.webKitDataStore == nil)
        #expect(privateProfile.id != id)
        for identity in [profile, privateProfile] {
            #expect(BrowserConfiguration.webViewConfiguration(for: identity) == nil)
            await identity.refreshDataStoreStats()
            #expect(await identity.clearAllData() == false)
            var completed = false
            identity.destroyEphemeralDataStore { completed = true }
            #expect(completed && identity.webKitDataStore == nil)
            #expect(identity.cachedCookieCount == 0 && identity.cachedRecordCount == 0)
        }
    }

    @Test func nativeExtensionCommandCapturesSelectedProfileWithoutRetargetingOrPageCreation() throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let work = try #require(tabs.tree.orderedSpaces.first?.id)
        let personal = try #require(tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: work))
        let personalID = try #require(tabs.tree.dataStoreID(for: personal))
        let window = BrowserWindowState()
        tabs.windowRegistry.register(window); tabs.windowRegistry.setActive(window)
        window.spaceID = personal
        let selected = try #require(tabs.open(url: URL(string: "https://synthetic.test/")!, in: window, placement: .background))
        // A mixed-profile pane can have a different space than its surrounding window.
        window.spaceID = work
        window.selectedItemBySpace[work] = selected
        let original = tabs.tree
        var valid: (@MainActor () -> Bool)?, finish: (@MainActor (Result<Void, ProfilePageOpenError>) -> Void)?
        var calls = 0, successes = 0
        tabs.onOpenProfilePage = { profile, destination, canPresent, completion in
            calls += 1
            #expect(profile.id == personalID && destination == .extensions)
            valid = canPresent; finish = completion
        }
        tabs.openExtensionControls(in: window) { if case .success = $0 { successes += 1 } }
        #expect(calls == 1 && valid?() == true)
        window.selectedItemBySpace[work] = nil; window.spaceID = work
        tabs.windowRegistry.unregister(window.id)
        #expect(valid?() == true) // Admitted controls belong to the captured profile independently.
        finish?(.success(())); finish?(.success(()))
        #expect(successes == 1 && tabs.tree == original && tabs.sessions.isEmpty)
    }

    @Test func nativeExtensionCommandRefusesPrivateMissingAndDeletedOwners() throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "", accentHex: "#123456", after: nil))
        let window = BrowserWindowState(); window.spaceID = work
        var calls = 0, failures = 0
        tabs.onOpenProfilePage = { _, _, _, _ in calls += 1 }
        let completed: @MainActor (Result<Void, ProfilePageOpenError>) -> Void = {
            if case .failure = $0 { failures += 1 }
        }
        tabs.openExtensionControls(in: nil, completion: completed)
        tabs.openExtensionControls(in: window, completion: completed)
        tabs.windowRegistry.register(window)
        tabs.openExtensionControls(in: window, completion: completed) // No active product window.
        tabs.windowRegistry.setActive(window)
        window.isIncognito = true
        tabs.openExtensionControls(in: window, completion: completed)
        window.isIncognito = false
        _ = tabs.perform(.main, "synthetic removed profile") { try $0.deleteSpace(work).change }
        tabs.openExtensionControls(in: window, completion: completed)
        #expect(calls == 0 && failures == 5 && tabs.sessions.isEmpty)
    }

    @Test func nativeExtensionCommandQueuedDeletionCannotOpenAnotherProfile() throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "", accentHex: "#123456", after: nil))
        let window = BrowserWindowState(); window.spaceID = work
        tabs.windowRegistry.register(window); tabs.windowRegistry.setActive(window)
        var valid: (@MainActor () -> Bool)?, finish: (@MainActor (Result<Void, ProfilePageOpenError>) -> Void)?
        tabs.onOpenProfilePage = { _, _, canPresent, completion in valid = canPresent; finish = completion }
        var error: ProfilePageOpenError?
        tabs.openExtensionControls(in: window) { if case .failure(let value) = $0 { error = value } }
        #expect(valid?() == true)
        _ = tabs.perform(.main, "synthetic removed queued profile") { try $0.deleteSpace(work).change }
        #expect(valid?() == false)
        finish?(.success(()))
        #expect(error == .profileUnavailable && tabs.sessions.isEmpty)
    }

    @Test func profileControlsRouteEveryDestinationToRequestedInactiveProfileWithoutTreeEdits() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "person", accentHex: "#123456", after: nil))
        let personal = try #require(tabs.createSpace(name: "Personal", icon: "house", accentHex: "#123456", after: work))
        let profileID = try #require(tabs.tree.dataStoreID(for: work))
        let window = BrowserWindowState()
        tabs.windowRegistry.register(window)
        tabs.windowRegistry.setActive(window)
        window.spaceID = personal
        let original = tabs.tree
        var observed: [ProfilePageDestination] = []
        var successes = 0
        tabs.onOpenProfilePage = { profile, destination, canPresent, completion in
            #expect(profile.id == profileID && profile.name == "Work")
            #expect(canPresent())
            observed.append(destination)
            completion(.success(()))
        }
        for destination in ProfilePageDestination.allCases {
            tabs.openProfilePage(profileID: profileID, destination: destination) {
                if case .success = $0 { successes += 1 }
            }
        }
        #expect(observed == [.settings, .extensions, .privacy, .siteSettings, .clearData, .downloads, .passwords])
        #expect(successes == 7 && tabs.tree == original)
        #expect(window.spaceID == personal && window.selectedItemID == nil)
    }

    @Test(arguments: [ProfilePageDestination.extensions, .passwords])
    func keptProfileControlsNeedNoWindowOrSpaceAssignment(destination: ProfilePageDestination) throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "person", accentHex: "#123456", after: nil))
        let profileID = try #require(tabs.tree.dataStoreID(for: work))
        tabs.deleteSpace(work, keepingLeftProfile: true)
        let original = tabs.tree
        let kept = tabs.device.keptProfiles
        var invoked = false
        tabs.onOpenProfilePage = { profile, requested, canPresent, completion in
            #expect(profile.id == profileID && profile.spaceIDs.isEmpty)
            #expect(requested == destination && canPresent())
            invoked = true
            completion(.success(()))
        }
        tabs.openProfilePage(profileID: profileID, destination: destination) { result in
            if case .failure = result { Issue.record("Kept profile routing unexpectedly failed") }
        }
        #expect(invoked && tabs.windowRegistry.windows.isEmpty)
        #expect(tabs.tree == original && tabs.device.keptProfiles == kept)
    }

    @Test(arguments: [ProfilePageDestination.clearData, .passwords])
    func staleProfileAdmissionFailsOnceWithoutFallback(destination: ProfilePageDestination) throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "person", accentHex: "#123456", after: nil))
        let profileID = try #require(tabs.tree.dataStoreID(for: work))
        var canPresent: (@MainActor () -> Bool)?
        var finish: (@MainActor (Result<Void, ProfilePageOpenError>) -> Void)?
        tabs.onOpenProfilePage = { profile, _, valid, completion in
            #expect(profile.id == profileID)
            canPresent = valid
            finish = completion
        }
        var errors: [ProfilePageOpenError] = []
        tabs.openProfilePage(profileID: profileID, destination: destination) {
            if case .failure(let error) = $0 { errors.append(error) }
        }
        #expect(canPresent?() == true)
        // A received tree edit can remove the target while native presentation is queued.
        _ = tabs.perform(.main, "incoming profile removal") { try $0.deleteSpace(work).change }
        #expect(canPresent?() == false)
        finish?(.success(()))
        finish?(.success(()))
        #expect(errors == [.profileUnavailable])
        tabs.onOpenProfilePage = { _, _, _, _ in Issue.record("Deleted profile reached presenter") }
        tabs.openProfilePage(profileID: profileID, destination: .settings) {
            if case .failure(let error) = $0 { errors.append(error) }
        }
        #expect(errors == [.profileUnavailable, .profileUnavailable])
    }

    @Test func passwordManagerRefusesPrivateSessionIdentityWithoutRegularFallback() throws {
        let fixture = try ProfileFixture(); defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let window = BrowserWindowState()
        window.isIncognito = true
        window.ephemeralProfile = Profile.createEphemeral(engine: .chromium)
        tabs.windowRegistry.register(window)
        let id = try #require(window.ephemeralProfile?.id)
        let original = tabs.tree
        tabs.onOpenProfilePage = { _, _, _, _ in Issue.record("Private identity reached regular presenter") }
        var failure: ProfilePageOpenError?
        tabs.openProfilePage(profileID: id, destination: .passwords) {
            if case .failure(let error) = $0 { failure = error }
        }
        #expect(failure == .profileUnavailable && tabs.tree == original)
        #expect(tabs.sessions.isEmpty && window.ephemeralProfile?.id == id)
    }

    @Test func absentProfilePresenterReportsUnavailableWithoutOpeningOrMutating() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let profile = try #require(tabs.profiles.first)
        let original = tabs.tree
        var error: ProfilePageOpenError?
        tabs.openProfilePage(profileID: profile.id, destination: .siteSettings) {
            if case .failure(let failure) = $0 { error = failure }
        }
        #expect(error == .presentationUnavailable && tabs.tree == original)
        #expect(tabs.sessions.isEmpty && tabs.windowRegistry.windows.isEmpty)
    }

    @Test func nativeLiveSourcesReportUnavailableWithoutStartingLegacyFetches() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let space = try #require(tabs.tree.orderedSpaces.first?.id)
        let profile = try #require(tabs.profile(forSpace: space))
        let sources: [LiveSource] = [.githubPulls, .githubIssues, .githubNotifications, .asanaTasks]
        var folders: [UUID] = []
        for source in sources {
            let folder = try #require(tabs.createLiveFolder(source, in: space))
            folders.append(folder)
            tabs.refreshLiveFolder(folder, force: true)
            #expect(tabs.liveStatus[folder] == .unavailable)
        }
        let item = try #require(tabs.children(of: .tabs(spaceID: space)).first?.id)
        tabs.pageCommitted(itemID: item, url: URL(string: "https://github.com/synthetic/repo/pull/1")!)
        tabs.refreshLiveFolders(inSpace: space)
        #expect(await tabs.pullRequests(inSpace: space) == [])
        #expect(await tabs.gmailInbox(inSpace: space, account: 0) == .unavailable)
        await Task.yield()
        #expect(profile.webKitDataStore == nil)
        #expect(tabs.liveRefreshing.isEmpty && tabs.liveRefreshed.isEmpty)
        #expect(folders.allSatisfy { tabs.liveStatus[$0] == .unavailable })
    }

    @Test func nativeFactoriesReuseStoreUUIDAndKeepNativeMetadataAfterRestart() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let work = try #require(tabs.createSpace(name: "Work", icon: "person",
            accentHex: "#123456", after: nil))
        let shared = try #require(tabs.createSpace(name: "Shared", icon: "folder",
            accentHex: "#123456", after: work, sharingLoginsWith: work))
        let personal = try #require(tabs.createSpace(name: "Personal", icon: "house",
            accentHex: "#123456", after: shared))
        let profile = try #require(tabs.profile(forSpace: work))
        #expect(profile === tabs.profile(forSpace: shared))
        #expect(profile !== tabs.profile(forSpace: personal))
        #expect(profile.id == tabs.tree.dataStoreID(for: work))
        #expect(profile.webKitDataStore == nil)
        tabs.updateSpace(work, name: "Renamed", icon: nil, accentHex: nil)
        #expect(tabs.profile(forSpace: work) === profile)
        #expect(profile.name == "Renamed" && profile.webKitDataStore == nil)
        let id = profile.id
        tabs.deleteSpace(work, keepingLeftProfile: true)
        tabs.deleteSpace(shared, keepingLeftProfile: true)
        tabs.saveNow()
        let reloaded = fixture.makeTabs(engine: .chromium)
        let kept = try #require(reloaded.profile(forStore: id))
        #expect(kept.id == id && kept.engine == .chromium)
        #expect(kept.webKitDataStore == nil)
        #expect(kept === reloaded.profile(forStore: id))
    }

    @Test func unsupportedNativeDestructionAndReassignmentPreserveMetadata() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let space = try #require(tabs.createSpace(name: "Work", icon: "person",
            accentHex: "#123456", after: nil))
        let profile = try #require(tabs.profile(forSpace: space))
        let originalStore = tabs.tree.dataStoreID(for: space)
        tabs.setProfile(space, to: UUID())
        #expect(tabs.tree.dataStoreID(for: space) == originalStore)
        tabs.deleteSpace(space)
        #expect(tabs.tree.space(space) == nil)
        #expect(tabs.device.keptProfiles?.contains { $0.id == profile.id } == true, "Chromium keeps the profile of a last space")
        tabs.deleteKeptProfile(profile.id)
        #expect(tabs.device.keptProfiles?.contains { $0.id == profile.id } == true)
        #expect(tabs.profile(forStore: profile.id) === profile)
    }

    @Test func nativePageConstructionAndFaviconRequestsDoNotEnterWebKit() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let url = URL(string: "https://native-favicon.invalid/page")!
        let page = PageSession(itemID: UUID(), url: url, title: "Native",
                               isPrivate: false, controller: tabs)
        #expect(page.faviconFetchAttempts == 0 && !page.faviconFetchInFlight)
        page.loadWebViewIfNeeded()
        #expect(page.webView == nil && page.isUnloaded)
        page.ensureFaviconLoaded()
        await page.fetchAndSetFavicon(for: url)
        #expect(page.faviconFetchAttempts == 0 && !page.faviconFetchInFlight)
        #expect(!page.hasFavicon)
        let profile = Profile(name: "Native", engine: .chromium)
        #expect(await tabs.clearData(of: profile) == false)
        #expect(profile.webKitDataStore == nil)
        page.unload()
    }
    @Test func keptDeletionPersistsBeforeAdmissionAndCancellationPreservesEverything() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let survivorSpace = try #require(tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: nil))
        let keptSpace = try #require(tabs.createSpace(name: "Work", icon: "", accentHex: "#123456", after: survivorSpace))
        let target = try #require(tabs.tree.dataStoreID(for: keptSpace))
        let survivor = try #require(tabs.tree.dataStoreID(for: survivorSpace))
        tabs.deleteSpace(keptSpace, keepingLeftProfile: true)
        let before = tabs.tree
        var finish: (@MainActor (ProfileDeletionOutcome) -> Void)?
        tabs.onDeleteProfile = { intent, reconcileOnly, canDelete, done in
            #expect(!reconcileOnly)
            #expect(intent == PendingProfileDeletion(target: target, survivor: survivor))
            #expect(canDelete())
            let disk = TabStore(directory: fixture.directory.appendingPathComponent("Tabs")).load()
            #expect(disk.device.pendingProfileDeletion == intent)
            #expect(disk.device.keptProfiles?.contains { $0.id == target } == true)
            finish = done
        }
        tabs.deleteKeptProfile(target, surviving: survivor) { _ in }
        #expect(tabs.profile(forStore: target) == nil)
        #expect(!tabs.isProfileAvailable(target))
        let imported = try #require(tabs.spaceFile(survivorSpace, appVersion: "test"))
        #expect(tabs.importSpace(imported, intoProfile: target) == nil)
        let originalName = tabs.profiles.first { $0.id == survivor }?.name
        tabs.renameProfile(survivor, to: "Changed during deletion")
        #expect(tabs.profiles.first { $0.id == survivor }?.name == originalName)
        #expect(tabs.tree == before)
        finish?(.cancelled(acknowledge: { true }))
        #expect(tabs.device.pendingProfileDeletion == nil)
        #expect(tabs.profile(forStore: target) != nil)
        #expect(tabs.tree == before)
        #expect(tabs.device.keptProfiles?.contains { $0.id == target } == true)
    }

    @Test func interruptedKeptDeletionDoesNotReopenAfterRestartOrFailedRecovery() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let survivorSpace = try #require(tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: nil))
        let keptSpace = try #require(tabs.createSpace(name: "Work", icon: "", accentHex: "#123456", after: survivorSpace))
        let target = try #require(tabs.tree.dataStoreID(for: keptSpace))
        let survivor = try #require(tabs.tree.dataStoreID(for: survivorSpace))
        tabs.deleteSpace(keptSpace, keepingLeftProfile: true)
        tabs.onDeleteProfile = { _, _, _, done in done(.pending) }
        tabs.deleteKeptProfile(target, surviving: survivor) { _ in }
        let recovered = fixture.makeTabs(engine: .chromium)
        #expect(recovered.device.pendingProfileDeletion == PendingProfileDeletion(target: target, survivor: survivor))
        #expect(recovered.profile(forStore: target) == nil)
        var controlOpened = false
        recovered.onOpenProfilePage = { _, _, _, _ in controlOpened = true }
        recovered.openProfilePage(profileID: target, destination: .settings) { _ in }
        #expect(!controlOpened)
        // Native may have cleared its restart marker. A refusal in a new process
        // cannot prove that the previous process never destructively marked it.
        recovered.onDeleteProfile = { _, _, _, done in done(.cancelled(acknowledge: { true })) }
        recovered.resumePendingProfileDeletion { _ in }
        #expect(recovered.device.pendingProfileDeletion != nil)
        #expect(recovered.profile(forStore: target) == nil)
        recovered.onDeleteProfile = { _, _, _, done in done(.deleted) }
        var succeeded = false
        recovered.resumePendingProfileDeletion { if case .success = $0 { succeeded = true } }
        #expect(succeeded && recovered.device.pendingProfileDeletion == nil)
        #expect(recovered.device.keptProfiles?.contains { $0.id == target } == false)
        let terminal = fixture.makeTabs(engine: .chromium)
        #expect(terminal.device.pendingProfileDeletion == nil)
        #expect(terminal.profile(forStore: target) == nil)
        #expect(terminal.isProfileAvailable(survivor))
    }

    @Test func cancelledDeletionWriteFailureRetainsIntentAndRecoveryCannotAuthorizeDeletion() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let keptSpace = try #require(tabs.createSpace(name: "Work", icon: "", accentHex: "#123456", after: nil))
        let survivorSpace = try #require(tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: keptSpace))
        let target = try #require(tabs.tree.dataStoreID(for: keptSpace))
        let survivor = try #require(tabs.tree.dataStoreID(for: survivorSpace))
        tabs.deleteSpace(keptSpace, keepingLeftProfile: true)
        var finish: (@MainActor (ProfileDeletionOutcome) -> Void)?
        tabs.onDeleteProfile = { _, reconcileOnly, _, done in
            #expect(!reconcileOnly); finish = done
        }
        tabs.deleteKeptProfile(target, surviving: survivor) { _ in }
        let path = fixture.directory.appendingPathComponent("Tabs")
        let saved = fixture.directory.appendingPathComponent("saved-intent")
        try FileManager.default.moveItem(at: path, to: saved)
        try Data("not a directory".utf8).write(to: path)
        var acknowledged = false
        finish?(.cancelled(acknowledge: { acknowledged = true; return true }))
        #expect(!acknowledged, "Native admission must stay reserved when cancellation cannot persist")
        #expect(tabs.device.pendingProfileDeletion != nil)
        #expect(!tabs.isProfileAvailable(target))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: saved, to: path)
        let recovered = fixture.makeTabs(engine: .chromium)
        var reconciled = false
        recovered.onDeleteProfile = { _, reconcileOnly, _, done in
            #expect(reconcileOnly, "Automatic recovery must not authorize marking after a veto/crash")
            reconciled = true; done(.pending)
        }
        recovered.resumePendingProfileDeletion { _ in }
        #expect(reconciled && recovered.device.pendingProfileDeletion != nil)
        var retried = false
        recovered.onDeleteProfile = { _, reconcileOnly, _, done in
            #expect(!reconcileOnly, "Only explicit confirmation authorizes retry")
            retried = true; done(.deleted)
        }
        recovered.deleteKeptProfile(target, surviving: survivor) { _ in }
        #expect(retried && recovered.device.pendingProfileDeletion == nil)
    }

    @Test func deletionPersistenceFailureNeverCallsNativeAndDoesNotForgetProfile() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanup() }
        let tabs = fixture.makeTabs(engine: .chromium)
        let space = try #require(tabs.createSpace(name: "Work", icon: "", accentHex: "#123456", after: nil))
        let survivorSpace = try #require(tabs.createSpace(name: "Personal", icon: "", accentHex: "#123456", after: space))
        let target = try #require(tabs.tree.dataStoreID(for: space))
        let survivor = try #require(tabs.tree.dataStoreID(for: survivorSpace))
        tabs.deleteSpace(space, keepingLeftProfile: true)
        tabs.saveNow()
        // Turn the synthetic directory into a file, making the atomic write fail.
        let path = fixture.directory.appendingPathComponent("Tabs")
        try FileManager.default.removeItem(at: path)
        try Data("not a directory".utf8).write(to: path)
        var called = false
        tabs.onDeleteProfile = { _, _, _, _ in called = true }
        var result: ProfileDeletionError?
        tabs.deleteKeptProfile(target, surviving: survivor) { if case .failure(let error) = $0 { result = error } }
        #expect(result == .persistenceFailed && !called)
        #expect(tabs.device.pendingProfileDeletion == nil)
        #expect(tabs.profile(forStore: target) != nil)
    }

    #endif

    @Test func nativeSearchDeletedCustomSeedUsesExistingGoogleFallback() throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let id = try #require(tabs.profiles.first?.id)
        tabs.settings.searchEngineId = "deleted-custom-id"
        var selected: String?
        tabs.onProfileSearch = { _, _, seed, _, _, done in
            if let json = seed(), let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                selected = object["selected"] as? String
            }
            done(.failure(ProfileSearchError.refused))
        }
        tabs.profileSearchState(profileID: id, includeChoices: false) { _ in }
        #expect(selected == "google")
    }

    @Test func nativeSearchSeedIsExactProfileTokenFreeAndCompactQueriesStayCompact() throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let id = try #require(tabs.profiles.first?.id)
        tabs.settings.searchEngineId = SearchProvider.kagi.rawValue
        var seen = false
        tabs.onProfileSearch = { actual, page, seed, selection, choices, done in
            #expect(actual == id && page == nil && selection == nil && !choices)
            let seed = seed() ?? ""
            let object = try? JSONSerialization.jsonObject(with: Data(seed.utf8)) as? [String: Any]
            let engines = object?["engines"] as? [[String: String]]
            #expect(engines?.contains(where: { $0["id"] == "kagi" && $0["url"] == "https://kagi.com/search?q={searchTerms}" }) == true)
            #expect(!seed.contains("token="))
            seen = true
            done(.success(ProfileSearchState(version: "one", selected: "native-guid", name: "Native", controlled: true,
                managed: true, providers: [], suggestions: "")))
        }
        var result: ProfileSearchState?
        tabs.profileSearchState(profileID: id, includeChoices: false) { result = try? $0.get() }
        #expect(seen && result?.controlled == true && result?.suggestions == "")
        #expect(tabs.windowRegistry.windows.isEmpty && tabs.sessions.isEmpty)
    }

    @Test func nativeSearchLateReplyCannotReviveDeletedIdentity() throws {
        let f = try ProfileFixture(); defer { f.cleanup() }
        let tabs = f.makeTabs(engine: .chromium)
        let id = try #require(tabs.profiles.first?.id)
        var reply: ((Result<ProfileSearchState, Error>) -> Void)?
        tabs.onProfileSearch = { _, _, _, _, _, done in reply = done }
        var accepted = false
        tabs.profileSearchState(profileID: id) { accepted = (try? $0.get()) != nil }
        tabs.onProfileSearch = nil
        // Exact availability is rechecked after the native callback; replacing
        // the tree's profile identity cannot be mistaken for a current result.
        let space = try #require(tabs.tree.orderedSpaces.first?.id)
        let peer = try #require(tabs.createSpace(name: "Other", icon: "", accentHex: "#123456", after: space))
        let survivor = try #require(tabs.tree.dataStoreID(for: peer))
        _ = tabs.perform(.main, "removeSearchIdentity", undoable: false) { try $0.setProfile(space, to: survivor) }
        reply?(.success(ProfileSearchState(version: "old", selected: "old", name: "Old", controlled: false,
            managed: false, providers: [], suggestions: "google")))
        #expect(!accepted)
    }

    @Test func defaultPrivateWebKitStorageStillOwnsAndClearsItsCookies() async throws {
        let profile = Profile.createEphemeral()
        let store = try #require(profile.webKitDataStore)
        #expect(profile.engine == .webKit && profile.isEphemeral)
        #expect(!store.isPersistent && profile.webKitDataStore === store)
        let other = Profile.createEphemeral()
        let otherStore = try #require(other.webKitDataStore)
        #expect(other.id != profile.id && otherStore !== store)
        let configuration = try #require(BrowserConfiguration.webViewConfiguration(for: profile))
        #expect(configuration.websiteDataStore === store)
        #expect(configuration.webExtensionController == nil)
        let cookie = try #require(HTTPCookie(properties: [
            .name: "owned-test", .value: "one", .domain: "profile.invalid", .path: "/"]))
        await store.httpCookieStore.setCookie(cookie)
        await otherStore.httpCookieStore.setCookie(cookie)
        await profile.refreshDataStoreStats()
        #expect(profile.cachedCookieCount == 1)
        #expect(await profile.clearAllData())
        #expect(profile.cachedCookieCount == 0)
        #expect(await otherStore.httpCookieStore.allCookies().count == 1)
        await withCheckedContinuation { continuation in
            other.destroyEphemeralDataStore { continuation.resume() }
        }
        #expect(await otherStore.httpCookieStore.allCookies().isEmpty)
    }
}

@MainActor
private final class ProfileFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    init() throws {
        suite = "NookProfileEngineTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func makeTabs(engine: Profile.Engine) -> TabsController {
        let settings = NookSettingsService(kagiTokenStore: NoTokenStore(), userDefaults: defaults,
            boostStore: BoostStore(fileURL: directory.appendingPathComponent("Boosts.json")))
        return TabsController(settings: settings, windowRegistry: WindowRegistry(),
            blocker: ContentBlockerManager(settings: settings),
            sponsorBlock: SponsorBlockManager(settings: settings),
            siteRouting: SiteRoutingManager(settings: settings),
            profileEngine: engine, directory: directory.appendingPathComponent("Tabs"))
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct NoTokenStore: KagiTokenStore {
    func load() -> String? { nil }
    func save(_ token: String?) {}
}
