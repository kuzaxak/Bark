// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookWeb

@MainActor
struct PageNavigationTests {
    @Test func muteUsesObservedStateAndRefusalNeverChangesTheModel() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!, title: "Audio", isPrivate: false, controller: nil)
        let page = RecordingNavigation(profileID: UUID())
        session.installNavigation(page)
        session.setMuted(true)
        #expect(page.muteRequests == [true] && !session.isAudioMuted)
        page.acceptsMute = true
        session.setMuted(true)
        #expect(page.muteRequests == [true, true] && !session.isAudioMuted)
        page.state.isAudioMuted = true; page.state.isAudible = true
        page.onStateChanged?(page.state)
        #expect(session.isAudioMuted && session.hasPlayingAudio && session.hasAudioContent)
        session.toggleMute()
        #expect(page.muteRequests.last == false && session.isAudioMuted)
        page.state.isAudioMuted = false; page.state.isAudible = false
        page.onStateChanged?(page.state)
        #expect(!session.isAudioMuted && !session.hasPlayingAudio && !session.hasAudioContent)
        #expect(!page.invalidated)
    }

    @Test func sessionCommandsUseInstalledNavigation() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        // An independently installed navigation has no Chromium window or resource owner.
        #expect(!session.usesNativePageHost)
        let page = RecordingNavigation(profileID: UUID())
        session.installNavigation(page)
        #expect(!session.isUnloaded && !session.usesNativePageHost)
        session.loadWebViewIfNeeded()
        let url = URL(string: "about:blank#next")!
        session.load(url)
        #expect(page.loaded == [url])
        #expect(session.url == url)
        page.publish(back: true, forward: true)
        #expect(session.canGoBack && session.canGoForward)
        session.goBack()
        session.goForward()
        session.refresh()
        session.stop()
        #expect(page.back == 1 && page.forward == 1 && page.reloads == 1)
        #expect(page.stops == 1)
        #expect(session.loadingState == .idle)
        session.unload()
        #expect(session.isUnloaded)
        #expect(page.invalidated)
    }

    @Test func pendingSnapshotDoesNotHideDocumentChangeFromStart() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let page = RecordingNavigation(profileID: UUID())
        let old = URL(string: "https://old.invalid/")!
        page.state = PageNavigationState(url: old, title: "Old",
                                        canGoBack: false, canGoForward: false)
        session.installNavigation(page)
        session.hasAudioContent = true
        session.hasPlayingAudio = true
        let next = URL(string: "https://next.invalid/")!
        page.state = PageNavigationState(url: next, isLoading: true,
                                        canGoBack: false, canGoForward: false)
        page.onStateChanged?(page.state)
        #expect(session.url == next)
        page.onEvent?(.started(next))
        #expect(!session.hasAudioContent && !session.hasPlayingAudio)
        session.unload()
    }

    @Test func admittedCloseRetiresWithoutStopOrRecursiveClose() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let page = RecordingNavigation(profileID: UUID())
        session.installNavigation(page)
        var closed = 0
        session.onClose = { closed += 1 }
        let deliver = page.onEvent
        deliver?(.closed)
        #expect(session.isUnloaded && session.loadingState == .idle)
        #expect(page.invalidated && page.stops == 0 && closed == 1)
        deliver?(.closed)
        deliver?(.started(URL(string: "about:blank#retired")!))
        #expect(closed == 1 && session.loadingState == .idle)
    }

    @Test func replacedAndUnloadedOwnersCannotPublishLateState() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Test", isPrivate: true, controller: nil)
        let first = RecordingNavigation(profileID: UUID())
        session.installNavigation(first)
        let late = first.onStateChanged
        let replacement = RecordingNavigation(profileID: UUID())
        session.installNavigation(replacement)
        #expect(first.invalidated)
        late?(PageNavigationState(canGoBack: true, canGoForward: true))
        #expect(!session.canGoBack && !session.canGoForward)
        replacement.publish(back: true, forward: false)
        #expect(session.canGoBack && !session.canGoForward)
        let afterUnload = replacement.onStateChanged
        session.unload()
        afterUnload?(PageNavigationState(canGoBack: false, canGoForward: true))
        #expect(session.canGoBack && !session.canGoForward)
    }

    @Test func bindingSeedIsNotAVisitAndSameDocumentCommitKeepsLoadingPhase() {
        let session = PageSession(itemID: UUID(), url: URL(string: "about:blank")!,
                                  title: "Restored", isPrivate: true, controller: nil)
        let page = RecordingNavigation(profileID: UUID())
        let committed = URL(string: "https://seed.invalid/committed")!
        page.state = PageNavigationState(url: committed, title: "Already loaded",
                                        canGoBack: true, canGoForward: false)
        session.typedVisitPending = true
        session.installNavigation(page)
        #expect(session.url == committed && session.title == "Already loaded")
        #expect(session.loadingState == .didFinish && session.hasCommittedPage)
        #expect(session.typedVisitPending, "Binding must not append a history visit")
        let fragment = URL(string: committed.absoluteString + "#section")!
        page.onEvent?(.committed(fragment, sameDocument: true))
        #expect(session.url == fragment && session.loadingState == .didFinish)
        page.onEvent?(.started(URL(string: "https://seed.invalid/fails")!))
        page.onEvent?(.failed(URLError(.cannotConnectToHost), provisional: true,
                             committedURL: fragment))
        #expect(session.url == fragment)
        #expect(!session.isLoading)
        page.onEvent?(.finished(fragment, title: "Final", isReload: false))
        #expect(!session.typedVisitPending)
        #expect(session.title == "Final")
        session.typedVisitPending = true
        page.onEvent?(.finished(fragment, title: "Final", isReload: false))
        #expect(session.typedVisitPending, "Duplicate finish cannot append another visit")
        page.onEvent?(.started(committed))
        page.onEvent?(.cancelled(committedURL: fragment))
        #expect(session.url == fragment && session.loadingState == .idle)
        page.onEvent?(.finished(committed, title: "Cancelled title", isReload: false))
        #expect(session.title == "Final" && session.loadingState == .idle)
        let late = page.onEvent
        session.unload()
        late?(.started(committed))
        late?(.titleChanged("Retired title"))
        #expect(session.loadingState == .idle && session.title == "Final")
    }

}

@MainActor
private final class RecordingNavigation: PageNavigation {
    let profileID: UUID?
    var state = PageNavigationState(canGoBack: false, canGoForward: false)
    var onStateChanged: ((PageNavigationState) -> Void)?
    var onEvent: ((PageNavigationEvent) -> Void)?
    var loaded: [URL] = []
    var back = 0
    var forward = 0
    var reloads = 0
    var stops = 0
    var invalidated = false
    var acceptsMute = false
    var muteRequests: [Bool] = []
    func setAudioMuted(_ muted: Bool) -> Bool { muteRequests.append(muted); return acceptsMute }
    init(profileID: UUID) { self.profileID = profileID }
    func publish(back: Bool, forward: Bool) {
        state = PageNavigationState(canGoBack: back, canGoForward: forward)
        onStateChanged?(state)
    }
    func load(_ url: URL) { loaded.append(url) }
    func goBack() -> Bool { back += 1; return true }
    func goForward() -> Bool { forward += 1; return true }
    func reload() -> Bool { reloads += 1; return true }
    func stop() { stops += 1 }
    func invalidate() { invalidated = true; onStateChanged = nil; onEvent = nil }
}
