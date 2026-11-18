import AppKit
import BarcChromium
import NookWeb
import SwiftUI

struct ChromiumMiniDestination: Identifiable, Equatable {
    let id: UUID
    let name: String
    let profileID: UUID
    let isCopy: Bool
}

struct ChromiumMiniWindowAPI {
    let bridge: BarcBridge
    let canUse: @MainActor (Int32, Int32) -> Bool
    typealias CommandOMonitor = @MainActor (NSEvent) -> NSEvent?
    var installCommandOMonitor: @MainActor (NSView, @escaping CommandOMonitor) -> Any? = { header, handler in
        guard header.window != nil else { return nil }
        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handler(event) }
        }
    }
    var removeCommandOMonitor: @MainActor (Any) -> Void = { NSEvent.removeMonitor($0) }
    var eventBelongsToHeader: @MainActor (NSEvent, NSView) -> Bool = { event, header in
        guard let window = header.window, event.window === window, window.attachedSheet == nil else { return false }
        return true
    }
    var shareURL: @MainActor (URL, NSView) -> AnyObject? = { url, header in
        guard let window = header.window, window.attachedSheet == nil else { return nil }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: header.bounds, of: header, preferredEdge: .minY)
        return picker
    }
    var applicationPending: @MainActor (Int32, Int32) -> Bool = { _, _ in false }
}

/// Presents Chromium's live popup page and its controls in a compact Bark root.
@MainActor
final class ChromiumMiniWindowController: DetachedPageWindowController, NativePageResourceOwner {
    private var boundPage: PageSession?
    var page: PageSession { boundPage! }
    let navigation: ChromiumPageNavigation
    let window: Int32
    var nativeWindowID: Int32? { window }
    var nativeTabID: Int32? { navigation.nativeTabID }
    private let api: ChromiumMiniWindowAPI
    private var header: NSView?
    private var root: ChromiumCompactRoot?
    private var ended = false
    private var promoting = false
    private var admitted = false
    private var commandOMonitor: Any?
    private var installingCommandOMonitor = false
    private var sharingPresentation: AnyObject?
    private(set) var presentationRefused = false
    var isPresented: Bool { admitted && ownsControls() }
    private var pending: [@MainActor (PageCloseOutcome) -> Void] = []
    private let canPromote: @MainActor (PageSession) -> Bool
    private let promote: @MainActor (PageSession, UUID?) -> Bool
    private let destinations: @MainActor (PageSession) -> [ChromiumMiniDestination]
    private let openCopy: @MainActor (PageSession, UUID) -> Bool
    private let onEnd: @MainActor (ChromiumMiniWindowController) -> Void

    init?(tabs: TabsController, profile: Profile, navigation: ChromiumPageNavigation,
          origin: BrowserWindowState?, api: ChromiumMiniWindowAPI,
          promote: @escaping @MainActor (PageSession, UUID?) -> Bool,
          destinations: @escaping @MainActor (PageSession) -> [ChromiumMiniDestination] = { _ in [] },
          openCopy: @escaping @MainActor (PageSession, UUID) -> Bool = { _, _ in false },
          canPromote: @escaping @MainActor (PageSession) -> Bool = { _ in true },
          onEnd: @escaping @MainActor (ChromiumMiniWindowController) -> Void) {
        self.navigation = navigation; self.window = navigation.nativeWindowID
        self.api = api; self.promote = promote; self.destinations = destinations; self.openCopy = openCopy
        self.canPromote = canPromote; self.onEnd = onEnd
        guard !navigation.isClosed, navigation.profileID == profile.id,
              navigation.isPrivateSession == profile.isEphemeral,
              let page = tabs.bindDetachedNativePage(navigation, profile: profile,
            owner: self, in: origin), !navigation.isClosed else { return nil }
        self.boundPage = page
        navigation.onNativeOwnerChanged = { [weak self] owner in
            guard let self, owner != self.window, !self.promoting else { return }
            self.detachHeader()
        }
        navigation.onNativeCloseOutcome = { [weak self] outcome in self?.completed(outcome) }
    }

    isolated deinit {
        if let commandOMonitor { api.removeCommandOMonitor(commandOMonitor) }
    }

    func present(canPresent: () -> Bool) -> Bool {
        guard !ended, canPresent(), page.navigation === navigation,
              navigation.nativeWindowID == window, !navigation.isClosed else { return false }
        if admitted && ownsControls() { installCommandOMonitor(); return true }
        let tab = navigation.nativeTabID
        guard api.canUse(window, tab), (root != nil || api.bridge.tab_native_view(window, tab) != nil) else {
            presentationRefused = true
            clearHeaderServices()
            return false
        }
        let view: NSView
        if let header { view = header }
        else {
            let hosting = NSHostingView(rootView: ChromiumMiniHeader(page: page,
                leadingInset: ChromiumMiniHeader.besideLights,
                promote: { [weak self] in self?.openInSpace() },
                canPromote: { [weak self] in self.map { $0.canPromote($0.page) } == true },
                destinations: { [weak self] in self.map { $0.page.isPrivate ? [] : $0.destinations($0.page) } ?? [] },
                chooseDestination: { [weak self] in self?.openInSpace($0) },
                share: { [weak self] in _ = self?.share() },
                close: { [weak self] in self?.close() }))
            // The compact root already reserves the title band and the traffic-light inset.
            hosting.safeAreaRegions = []
            view = hosting
            header = hosting
        }
        if root == nil {
            let compact = ChromiumCompactRoot(bridge: api.bridge, client: window)
            guard compact.attach(header: view, showing: tab) else {
                presentationRefused = true
                clearHeaderServices()
                return false
            }
            root = compact
        }
        guard let root else { return false }
        root.setHeader(view)
        guard root.show(tab: navigation.nativeTabID), canPresent(), ownsControls() else {
            presentationRefused = true
            detachHeader()
            return false
        }
        admitted = true
        presentationRefused = false
        installCommandOMonitor()
        return true
    }

    private func ownsControls() -> Bool {
        guard !ended, let header, page.navigation === navigation,
              navigation.nativeWindowID == window, !navigation.isClosed,
              api.canUse(window, navigation.nativeTabID) else { return false }
        guard let root, root.holdsHeader(header) else { return false }
        return api.bridge.window_native_shell_is_owned(window, Unmanaged.passUnretained(root).toOpaque()) == 1
    }

    func close() {
        guard ownsControls() else { return }
        page.unload()
    }

    func closePage(_ page: any PageNavigation,
                   completion: @escaping @MainActor (PageCloseOutcome) -> Void) {
        guard page === navigation, ownsControls() else { completion(.cancelled); return }
        pending.append(completion)
        if pending.count == 1, api.bridge.tab_close(window, navigation.nativeTabID) == 0 {
            completed(.cancelled)
        }
    }

    private func completed(_ outcome: PageCloseOutcome) {
        let callbacks = pending
        pending.removeAll()
        if outcome != .cancelled, !ended {
            ended = true
            clearHeaderServices()
            if outcome != .ownerEnded { detachHeader() }
            header = nil
            root = nil
        }
        callbacks.forEach { $0(outcome) }
        if outcome != .cancelled { onEnd(self) }
    }

    func openInSpace(_ destination: ChromiumMiniDestination? = nil) {
        guard ownsControls(), !promoting, pending.isEmpty,
              !api.applicationPending(window, navigation.nativeTabID) else { return }
        if let destination {
            guard !page.isPrivate else { return }
            // A menu can outlive profile reassignment/deletion. Never reinterpret
            // an old live-move label as consent to reload into another profile.
            guard let current = destinations(page).first(where: { $0.id == destination.id }),
                  current.profileID == destination.profileID, current.isCopy == destination.isCopy else { return }
            if destination.isCopy { _ = openCopy(page, destination.id); return }
        } else if !canPromote(page) { return }
        promoting = true
        _ = promote(page, destination?.id)
        promoting = false
        if !page.isDetached { releaseAfterAdoption() }
    }

    @discardableResult
    func share() -> Bool {
        guard ownsControls(), !promoting, pending.isEmpty,
              !api.applicationPending(window, navigation.nativeTabID), let header else { return false }
        let result = api.shareURL(page.url, header)
        guard ownsControls() else { return false }
        sharingPresentation = result
        return result != nil
    }

    private func installCommandOMonitor() {
        guard commandOMonitor == nil, !installingCommandOMonitor, isPresented else { return }
        installingCommandOMonitor = true
        defer { installingCommandOMonitor = false }
        guard let header else { return }
        let monitor = api.installCommandOMonitor(header) { [weak self] event in
            guard let self, event.type == .keyDown,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "o", let header = self.header,
                  self.api.eventBelongsToHeader(event, header) else { return event }
            guard self.isPresented else { self.clearHeaderServices(); return event }
            // Do not let a disabled/repeated mini action fall through to Chrome's
            // unrelated Open File command in this same native window.
            if !event.isARepeat { self.openInSpace() }
            return nil
        }
        if isPresented, commandOMonitor == nil { commandOMonitor = monitor }
        else if let monitor { api.removeCommandOMonitor(monitor) }
    }

    private func clearHeaderServices() {
        let monitor = commandOMonitor
        commandOMonitor = nil
        if let monitor { api.removeCommandOMonitor(monitor) }
        sharingPresentation = nil
    }

    func releaseAfterAdoption() {
        guard !ended, !page.isDetached else { return }
        ended = true
        detachHeader()
        header = nil
        root = nil
        navigation.onNativeOwnerChanged = nil
        onEnd(self)
    }

    func relinquishNativeHeader() { detachHeader() }

    private func detachHeader() {
        admitted = false
        clearHeaderServices()
        if let root, let header, root.holdsHeader(header) { root.setHeader(nil) }
    }
}

private struct ChromiumMiniHeader: View {
    /// Past the window's lights, which sit in the header of a Bark window.
    static let besideLights: CGFloat = 78
    @Bindable var page: PageSession
    let leadingInset: CGFloat
    let promote: () -> Void
    let canPromote: () -> Bool
    let destinations: () -> [ChromiumMiniDestination]
    let chooseDestination: (ChromiumMiniDestination) -> Void
    let share: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title.isEmpty ? page.url.absoluteString : page.title).lineLimit(1)
                if let profile = page.profile { Text(profile.name).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Open in Space", action: promote).disabled(!canPromote())
                .help("Open this live page as a tab (⌘O)")
            let choices = destinations()
            if !choices.isEmpty {
                Menu {
                    ForEach(choices) { destination in
                        Button(destination.isCopy ? "Open a copy in \(destination.name)" : "Open in \(destination.name)") {
                            chooseDestination(destination)
                        }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Choose a space")
            }
            Button(action: share) { Image(systemName: "square.and.arrow.up") }.help("Share current URL")
            Button(action: close) { Image(systemName: "xmark") }.help("Close")
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(.bar)
        .background { TranslationTaskHost(session: page) }
        .overlay(alignment: .leading) {
            if let language = page.translationOffer, !page.isTranslated {
                TranslateOfferView(session: page, language: language).padding(.leading, leadingInset)
            } else if let notice = page.translationNotice, page.isTranslated {
                TranslationNoticeView(session: page, notice: notice).padding(.leading, leadingInset)
            }
        }
    }
}
