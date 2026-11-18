import AppKit
import BarcChromium
import NookWeb
import NookTabsCore
import NookSettings

/// One actual product window, sharing the existing model registry and sidebar.
/// The hosting view retains its window-local palette/organizer/hover state.
@MainActor
final class ChromiumProductWindow {
    let state: BrowserWindowState
    let shell: NSView
    var didNotifyStartupWarming = false
    /// A failed restore must not erase its already-saved window record.
    var preservesSavedRecord: Bool
    var presentationCompletion: (@MainActor (Int32?) -> Void)?
    init(state: BrowserWindowState, shell: NSView, preservesSavedRecord: Bool = false) {
        self.state = state; self.shell = shell; self.preservesSavedRecord = preservesSavedRecord
    }
}

/// Admission of existing native pages, not a second tab model. Only the native
/// group -> existing product lifetime association survives a callback.
@MainActor
final class ChromiumCreatedPageAdmission {
    private let bridge: BarcBridge
    private let host: ChromiumNativePageHost
    private let tabs: TabsController
    private let registry: WindowRegistry
    private let isUtility: (Int32) -> Bool
    private let makeShell: (BrowserWindowState) -> NSView
    private let detachedPage: (Int32) -> PageSession?
    private let didAdoptDetached: (Int32) -> Void
    private let didPresent: (BrowserWindowState) -> Void
    private let coveredByPeek: (PageSession, BrowserWindowState) -> Bool
    private var products: [UInt64: ChromiumProductWindow] = [:]

    init(bridge: BarcBridge, host: ChromiumNativePageHost, tabs: TabsController,
         registry: WindowRegistry, isUtility: @escaping (Int32) -> Bool,
         makeShell: @escaping (BrowserWindowState) -> NSView,
         detachedPage: @escaping (Int32) -> PageSession? = { _ in nil },
         didAdoptDetached: @escaping (Int32) -> Void = { _ in },
         coveredByPeek: @escaping (PageSession, BrowserWindowState) -> Bool = { _, _ in false },
         didPresent: @escaping (BrowserWindowState) -> Void = { _ in }) {
        self.bridge = bridge; self.host = host; self.tabs = tabs; self.registry = registry
        self.isUtility = isUtility; self.makeShell = makeShell
        self.detachedPage = detachedPage; self.didAdoptDetached = didAdoptDetached
        self.didPresent = didPresent
        self.coveredByPeek = coveredByPeek
    }

    func reflectInitialActivation(_ row: BarcDiscoveryWindow) {
        // Chromium can make the initial window key without another discovery pass.
        guard row.selected_client == row.window, row.kind == BARC_DISCOVERY_NORMAL.rawValue,
              row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0,
              row.flags & BARC_DISCOVERY_PHYSICAL_ACTIVE.rawValue != 0,
              !isUtility(row.window), let state = products[row.physical_group]?.state,
              registry.windows[state.id] === state, registry.activeWindowId != state.id else { return }
        registry.setActive(state)
    }

    func registerInitial(_ product: ChromiumProductWindow, nativeWindow: Int32) -> Bool {
        guard let row = bridge.windowState(nativeWindow), row.physical_group != 0,
              products[row.physical_group] == nil else { return false }
        products[row.physical_group] = product
        return true
    }

    /// Consume one document-bound menu intent. The synchronous native admission
    /// binds the blank before Chromium performs its single captured navigation.
    func createPeek(from source: PageSession, request: Int32, in window: BrowserWindowState)
        -> (page: PageSession, accepted: Bool)? {
        guard registry.windows[window.id] === window, tabs.isNativePageOwner(source, in: window),
              let navigation = source.navigation as? ChromiumPageNavigation,
              navigation.pendingPeekRequestID == request, let profile = source.profile,
              let row = bridge.windowState(navigation.nativeWindowID),
              products[row.physical_group]?.state === window,
              tabs.reflectNativeSelection(source.itemID, in: window),
              host.isNativeSelection(navigation, in: window) else { return nil }
        let attempt = PeekAdmission { [weak self, weak source, weak window, weak navigation] nativeWindow, tab in
            guard let self, let source, let window, let navigation,
                  source.navigation === navigation, self.registry.windows[window.id] === window,
                  self.tabs.isNativePageOwner(source, in: window), window.selectedItemID == source.itemID,
                  case .success(let binding) = self.host.bindExistingPage(nativeWindow: nativeWindow,
                      tab: tab, profile: profile, in: window) else { return nil }
            let page = self.tabs.bindDetachedNativePage(binding.navigation, profile: profile, owner: self.host, in: window)
            let accepted = page?.navigation === binding.navigation && self.host.canAdoptPage(binding.navigation, in: window)
            binding.finish(adopted: accepted)
            return accepted ? page : nil
        }
        let accepted = withExtendedLifetime(attempt) {
            navigation.createNativePeek(request: request, admission: { context, nativeWindow, tab in
                MainActor.assumeIsolated {
                    guard let context else { return 0 }
                    let attempt = Unmanaged<PeekAdmission>.fromOpaque(context).takeUnretainedValue()
                    attempt.page = attempt.bind(nativeWindow, tab)
                    return attempt.page == nil ? 0 : 1
                }
            }, context: Unmanaged.passUnretained(attempt).toOpaque())
        }
        return attempt.page.map { ($0, accepted) }
    }

    private final class PeekAdmission {
        let bind: (Int32, Int32) -> PageSession?
        var page: PageSession?
        init(bind: @escaping (Int32, Int32) -> PageSession?) { self.bind = bind }
    }

    func ownsPeek(_ session: PageSession, source: PageSession, in window: BrowserWindowState) -> Bool {
        guard session.isDetached, registry.windows[window.id] === window,
              let page = session.navigation as? ChromiumPageNavigation,
              let origin = source.navigation as? ChromiumPageNavigation,
              tabs.isNativePageOwner(source, in: window), host.isBoundPage(page, in: window),
              page.profileID == origin.profileID, let snapshot = bridge.readSnapshot(),
              let sourceRow = snapshot.windows.first(where: { $0.window == origin.nativeWindowID }),
              products[sourceRow.physical_group]?.state === window,
              snapshot.windows.contains(where: { $0.window == page.nativeWindowID &&
                  $0.physical_group == sourceRow.physical_group }) else { return false }
        return snapshot.tabs.contains { $0.window == page.nativeWindowID && $0.tab == page.nativeTabID &&
            $0.flags & BARC_DISCOVERY_TAB_PEEK.rawValue != 0 && $0.peek_source_tab == origin.nativeTabID }
    }

    /// Promotion returns the same live document to its exact source owner; a
    /// different profile or another product window is never chosen as fallback.
    /// A Peek already in its source's client, as in a Bark window, stays there.
    func promotePeek(_ session: PageSession, source: PageSession, in window: BrowserWindowState,
                     intoSplit split: SplitRecord? = nil) -> Bool {
        guard registry.windows[window.id] === window, window.selectedItemID == source.itemID,
              session.isDetached, let profile = session.profile,
              tabs.isNativePageOwner(source, in: window),
              let origin = source.navigation as? ChromiumPageNavigation,
              let page = session.navigation as? ChromiumPageNavigation,
              origin.profileID == profile.id, page.profileID == profile.id,
              split == nil || (page.nativeWindowID == origin.nativeWindowID && host.laysOutSplits(in: window)
                && split?.contains(source.itemID) == true && split?.contains(session.itemID) == true),
              let space = window.isIncognito ? window.spaceID : tabs.spaceID(of: source.itemID) else { return false }
        let commit = { [weak self, weak session, weak source, weak window] () -> Bool in
            guard let self, let session, let source, let window,
                  self.registry.windows[window.id] === window,
                  self.tabs.isNativePageOwner(source, in: window),
                  split == nil ? self.host.acceptNativeSelection(page, in: window)
                               : self.host.isNativePeekSelection(page, source: origin, in: window),
                  let id = self.tabs.adoptDetachedNativePage(session, through: self.host, in: window,
                      spaceID: space, from: source.itemID, select: false),
                  self.tabs.session(for: id) === session, session.navigation === page else { return false }
            return split != nil || self.tabs.reflectNativeSelection(id, in: window)
        }
        if page.nativeWindowID == origin.nativeWindowID {
            guard ownsPeek(session, source: source, in: window), host.admitMovedPeek(page, commit: commit) else { return false }
            if let split {
                // Keep the source layout mounted until the engine clears the
                // Peek role and the split can place the existing card page.
                let stillOwned = { [weak self, weak window, weak session] in
                    guard let self, let window, let session else { return false }
                    return self.tabs.session(for: session.itemID) === session && session.navigation === page
                }
                tabs.presentNativeSplit(split, activeItemID: session.itemID, in: window, liveAdmission: stillOwned) {
                    [weak self, weak window] admitted in
                    guard !admitted, let self, let window, window.selectedItemID == source.itemID,
                          stillOwned(), self.host.isNativeSelection(page, in: window) ||
                            self.host.isNativePeekSelection(page, source: origin, in: window) else { return }
                    // Reflection moves the still-selected Peek into the ordinary page slot.
                    _ = self.tabs.reflectNativeSelection(session.itemID, in: window)
                }
            }
            return true
        }
        return host.promoteDetachedPage(page, profile: profile, to: origin.nativeWindowID, in: window,
                                       peekSource: origin, commit: commit)
    }

    /// Reuse the model's regular-profile preference for external links. A private
    /// Dock reopen requires its still-live exact native session, never UUID replay.
    func browserTarget(kind: Int32, regularProfile: UUID?) -> (window: Int32, regularProfile: UUID?)? {
        let isURL = kind == BARC_APPLICATION_TARGET_URL.rawValue
        guard isURL || kind == BARC_APPLICATION_TARGET_DOCK_REOPEN.rawValue else { return nil }
        func target(_ product: ChromiumProductWindow) -> Int32? {
            let state = product.state
            guard registry.windows[state.id] === state else { return nil }
            if state.showsNativeEmptySpace {
                guard let profileID = state.isIncognito ? state.ephemeralProfile?.id :
                          state.spaceID.flatMap({ tabs.tree.dataStoreID(for: $0) }),
                      state.isIncognito || tabs.isProfileAvailable(profileID) else { return nil }
                if let client = host.emptySpaceClient(in: state, profile: profileID, open: isURL) { return client }
                return isURL ? -1 : host.liveClient(in: state.id)
            }
            guard let session = tabs.selectedSession(in: state), let page = session.navigation as? ChromiumPageNavigation,
                  page.isPrivateSession == state.isIncognito,
                  host.isNativeSelection(page, in: state) || coveredByPeek(session, state),
                  let row = bridge.windowState(page.nativeWindowID),
                  row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 else { return nil }
            let expected = state.isIncognito ? state.ephemeralProfile?.id :
                state.spaceID.flatMap { tabs.tree.dataStoreID(for: $0) }
            guard let profileID = page.profileID,
                  state.isIncognito || tabs.isProfileAvailable(profileID),
                  expected == profileID,
                  bridge.identity(row) == profileID else { return nil }
            return row.window
        }
        // The ordinary selected-owner route needs only the existing O(1)
        // membership/identity queries, not a catalog allocation over all tabs.
        if let active = registry.activeWindow,
           let product = products.values.first(where: { $0.state === active }),
           !product.preservesSavedRecord, !isURL || !active.isIncognito {
            if let native = target(product) { return (native, nil) }
            if active.isIncognito { return nil }
            if isURL, active.selectedItemID != nil, tabs.selectedSession(in: active)?.navigation == nil {
                return (-1, nil)
            }
        }
        guard let snapshot = bridge.readSnapshot() else { return nil }
        let liveGroups = Set(snapshot.windows.map(\.physical_group))
        let live = products.filter { liveGroups.contains($0.key) }.map(\.value)
        let zOrder = NSApp?.orderedWindows ?? []
        let regular = live.filter { !$0.state.isIncognito && $0.state.spaceID != nil &&
            registry.windows[$0.state.id] === $0.state && !$0.preservesSavedRecord }.sorted {
                let a = $0.shell.window.flatMap(zOrder.firstIndex(of:)) ?? .max
                let b = $1.shell.window.flatMap(zOrder.firstIndex(of:)) ?? .max
                return a == b ? $0.state.id.uuidString < $1.state.id.uuidString : a < b
            }
        if isURL {
            let opening = registry.windows.values.contains { state in
                !state.isIncognito && state.spaceID != nil &&
                !regular.contains(where: { $0.state === state })
            }
            switch ExternalLinkWindow(activeWindow: registry.activeWindowId,
                                      regularWindows: regular.map { $0.state.id }, windowOpening: opening) {
            case .existing(let id):
                guard let product = regular.first(where: { $0.state.id == id }) else { return nil }
                if let native = target(product) { return (native, nil) }
                if product.state.selectedItemID != nil && tabs.selectedSession(in: product.state)?.navigation == nil {
                    return (-1, nil)
                }
                // Chrome may already have selected a new tab/client while the
                // posted catalog callback has not yet reflected it in the model.
                if let group = products.first(where: { $0.value === product })?.key,
                   let actual = snapshot.windows.first(where: {
                       $0.physical_group == group && $0.selected_client == $0.window &&
                       $0.active_tab > 0 && $0.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 &&
                       $0.profileID != nil
                   }), let page = tabs.selectedSession(in: product.state)?.navigation as? ChromiumPageNavigation,
                   actual.window != page.nativeWindowID || actual.active_tab != page.nativeTabID {
                    return (-1, nil)
                }
                return nil
            case .opening: return (-1, nil)
            case .new:
                // A real normal owner can precede model/catalog admission. Do
                // not create a parallel window while that owner is on its way.
                let nativeOpening = snapshot.windows.contains { row in
                    row.kind == BARC_DISCOVERY_NORMAL.rawValue &&
                    row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 &&
                    row.profileID != nil && !isUtility(row.window)
                }
                return nativeOpening ? (-1, nil) : fallback(regularProfile)
            }
        }
        if let active = registry.activeWindow,
           let product = live.first(where: { $0.state === active }) {
            guard let native = target(product) else { return nil }
            return (native, nil)
        }
        if registry.activeWindow?.isIncognito == true { return nil }
        if let product = regular.first {
            guard let native = target(product) else { return nil }
            return (native, nil)
        }
        return fallback(regularProfile)

        func fallback(_ id: UUID?) -> (window: Int32, regularProfile: UUID?)? {
            guard let id, tabs.isProfileAvailable(id), tabs.tree.profiles.contains(where: { $0.id == id }),
                  tabs.orderedSpaces.contains(where: { tabs.tree.dataStoreID(for: $0.id) == id }) else { return nil }
            return (0, id)
        }
    }

    /// The existing routing policy supplies a space hint; it never mutates the
    /// selected model space merely to decide where an incoming request belongs.
    func incomingTarget(ruleSpace: UUID?, mini: Bool, regularProfile: UUID?)
        -> (window: Int32, profile: UUID?, space: UUID?, mini: Bool)? {
        if let ruleSpace, tabs.space(ruleSpace) != nil {
            guard let id = tabs.tree.dataStoreID(for: ruleSpace), tabs.isProfileAvailable(id),
                  let target = browserTarget(kind: Int32(BARC_APPLICATION_TARGET_URL.rawValue), regularProfile: id) else { return nil }
            return (target.window, id, ruleSpace, false)
        }
        if mini {
            if let state = registry.activeWindow,
               let product = products.values.first(where: { $0.state === state }),
               registry.windows[state.id] === state, !product.preservesSavedRecord,
               let session = tabs.selectedSession(in: state), let page = session.navigation as? ChromiumPageNavigation,
               host.isNativeSelection(page, in: state) || coveredByPeek(session, state), let id = page.profileID,
               let row = bridge.windowState(page.nativeWindowID), bridge.identity(row) == id,
               page.isPrivateSession == state.isIncognito,
               state.isIncognito || tabs.isProfileAvailable(id),
               row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 {
                return (row.window, nil, nil, true)
            }
            // A private source cannot be reconstructed after its owner ends.
            guard registry.activeWindow?.isIncognito != true,
                  let id = regularProfile, tabs.isProfileAvailable(id),
                  tabs.tree.profiles.contains(where: { $0.id == id }) else { return nil }
            return (0, id, nil, true)
        }
        guard let target = browserTarget(kind: Int32(BARC_APPLICATION_TARGET_URL.rawValue), regularProfile: regularProfile) else { return nil }
        if target.window == -1 { return (-1, nil, nil, false) }
        let state = products.values.first { product in
            guard let row = bridge.windowState(target.window) else { return false }
            return products[row.physical_group] === product
        }?.state
        let showing = state?.spaceID ?? tabs.orderedSpaces.first(where: {
            tabs.tree.dataStoreID(for: $0.id) == target.regularProfile
        })?.id
        guard let showing else { return nil }
        guard let space = ExternalLinkDestination.space(showing: showing,
            spaces: tabs.orderedSpaces.map(\.id), agentSpace: tabs.agentSpaceID) else {
            // Existing routing uses a mini when no ordinary space is eligible.
            return incomingTarget(ruleSpace: nil, mini: true, regularProfile: regularProfile)
        }
        guard let id = tabs.tree.dataStoreID(for: space), tabs.isProfileAvailable(id) else { return nil }
        return (target.window, id, space, false)
    }

    /// A native-created pending document is ready only after exact model and
    /// shell ownership has been published. This query never selects or loads it.
    func admittedApplicationPage(window: Int32, tab: Int32) -> Bool {
        admittedApplicationSession(window: window, tab: tab) != nil
    }

    func admittedApplicationSession(window: Int32, tab: Int32) -> PageSession? {
        guard let row = bridge.windowState(window), let product = products[row.physical_group],
              !isUtility(window), registry.windows[product.state.id] === product.state,
              let session = tabs.selectedSession(in: product.state), let selected = session.navigation as? ChromiumPageNavigation,
              host.isNativeSelection(selected, in: product.state) || coveredByPeek(session, product.state) else { return nil }
        return tabs.sessions.first { session in
            guard let page = session.navigation as? ChromiumPageNavigation,
                  page.nativeWindowID == window, page.nativeTabID == tab,
                  page.profileID == bridge.identity(row),
                  page.isPrivateSession == product.state.isIncognito else { return false }
            return tabs.isNativePageOwner(session, in: product.state) && host.canAdoptPage(page, in: product.state)
        }
    }

    /// Promote while the native transfer retains its last-tab source. The
    /// callback admits this exact session before Chromium can close that source.
    func promoteDetached(_ session: PageSession, spaceID requestedSpace: UUID? = nil,
                         peerInGroup: (Int32, Int32) -> Int32,
                         newPeer: (Int32) -> Int32,
                         close: (Int32) -> Int32) -> Bool {
        guard let page = session.navigation as? ChromiumPageNavigation,
              session.isDetached, let profile = session.profile, !page.isClosed,
              let snapshot = bridge.readSnapshot() else { return false }
        if let requestedSpace {
            guard !session.isPrivate, tabs.space(requestedSpace) != nil,
                  tabs.tree.dataStoreID(for: requestedSpace) == profile.id,
                  tabs.isProfileAvailable(profile.id) else { return false }
        }
        let source = page.nativeWindowID
        let matching = products.values.filter { product in
            registry.windows[product.state.id] === product.state &&
            product.state.isIncognito == session.isPrivate &&
            (!session.isPrivate || product.state.ephemeralProfile?.id == profile.id)
        }
        var product = matching.first(where: { $0.state === registry.activeWindow }) ?? matching.first
        var destination: Int32 = 0
        var created = false
        if let existing = product,
           let group = products.first(where: { $0.value === existing })?.key,
           let owner = snapshot.windows.first(where: { $0.physical_group == group &&
               $0.selected_client == $0.window && $0.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 }) {
            destination = snapshot.windows.first(where: { $0.physical_group == group &&
                bridge.identity($0) == profile.id &&
                ($0.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == session.isPrivate &&
                $0.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 })?.window ?? 0
            if destination == 0 { destination = peerInGroup(source, owner.window); created = destination > 0 }
        } else {
            destination = newPeer(source); created = destination > 0
            guard destination > 0, let row = bridge.windowState(destination), bridge.identity(row) == profile.id else { return false }
            let state = BrowserWindowState()
            if session.isPrivate { state.isIncognito = true; state.ephemeralProfile = profile }
            else {
                guard let space = requestedSpace ?? space(for: profile.id, opener: nil, in: state), tabs.isProfileAvailable(profile.id) else {
                    _ = close(destination); return false
                }
                state.spaceID = space
            }
            registry.register(state)
            tabs.attach(window: state, restoringSavedState: false)
            let shell = makeShell(state)
            guard registry.windows[state.id] === state,
                  host.registerWindow(state, nativeOwner: destination, shell: shell) else {
                registry.unregister(state.id); _ = close(destination); return false
            }
            let newProduct = ChromiumProductWindow(state: state, shell: shell)
            products[row.physical_group] = newProduct
            product = newProduct
        }
        let selectedSpace = product?.state.spaceID.flatMap { id in
            profile.isEphemeral || tabs.tree.dataStoreID(for: id) == profile.id ? id : nil
        }
        guard destination > 0, let product,
              let space = requestedSpace ?? selectedSpace ?? space(for: profile.id, opener: nil, in: product.state),
              session.navigation === page, page.nativeWindowID == source, session.isDetached else {
            if created && destination > 0 { _ = close(destination) }
            return false
        }
        let target = destination
        let accepted = host.promoteDetachedPage(page, profile: profile, to: target, in: product.state) { [weak self, weak session, weak page, weak product] in
            guard let self, let session, let page, let product,
                  self.registry.windows[product.state.id] === product.state,
                  self.host.acceptNativeSelection(page, in: product.state),
                  let id = self.tabs.adoptDetachedNativePage(session, through: self.host,
                      in: product.state, spaceID: space, select: false),
                  self.registry.windows[product.state.id] === product.state,
                  self.tabs.session(for: id) === session,
                  self.tabs.isNativePageOwner(session, in: product.state),
                  session.navigation === page, self.host.canAdoptPage(page, in: product.state) else { return false }
            _ = self.tabs.reflectNativeSelection(id, in: product.state)
            return self.registry.windows[product.state.id] === product.state &&
                self.tabs.session(for: id) === session && session.navigation === page &&
                self.tabs.isNativePageOwner(session, in: product.state) &&
                self.host.canAdoptPage(page, in: product.state)
        }
        // Only the helper-created still-empty client belongs to this attempt.
        // A newer close/transfer or publication must not be undone here.
        if !accepted && created, bridge.windowState(target) != nil,
           let current = bridge.readSnapshot(), !current.tabs.contains(where: { $0.window == target }) {
            _ = close(target)
        }
        return accepted
    }

    /// Derived model choices only: menu rendering must not instantiate profile
    /// stores, and a private page never offers a regular-profile destination.
    func miniDestinations(for session: PageSession) -> [ChromiumMiniDestination] {
        guard !session.isPrivate, let source = session.profile?.id else { return [] }
        return tabs.orderedSpaces.compactMap { space in
            guard let id = tabs.tree.dataStoreID(for: space.id), tabs.isProfileAvailable(id) else { return nil }
            return ChromiumMiniDestination(id: space.id, name: space.name,
                profileID: id, isCopy: id != source)
        }
    }

    /// Another profile means an explicit fresh URL copy, never a claimed live
    /// transfer. The original mini remains usable even if target startup fails.
    func openDetachedCopy(_ session: PageSession, in space: UUID,
                          open: SavedOpen, close: @escaping (Int32) -> Int32,
                          canPresent: @escaping () -> Bool) -> Bool {
        guard canPresent(), session.isDetached, !session.isPrivate,
              let page = session.navigation as? ChromiumPageNavigation, !page.isClosed,
              let source = session.profile?.id,
              let target = tabs.tree.dataStoreID(for: space), target != source,
              tabs.space(space) != nil, tabs.isProfileAvailable(target),
              let native = bridge.windowState(page.nativeWindowID),
              native.profile_kind == BARC_DISCOVERY_REGULAR.rawValue,
              bridge.identity(native) == source, native.active_tab == page.nativeTabID,
              native.selected_client == native.window,
              native.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0,
              let snapshot = bridge.readSnapshot() else { return false }
        let url = session.url
        let liveGroups = Set(snapshot.windows.filter {
            $0.kind == BARC_DISCOVERY_NORMAL.rawValue && $0.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0
        }.map(\.physical_group))
        let regular = products.filter { liveGroups.contains($0.key) }.map(\.value).filter {
            !$0.state.isIncognito && !$0.preservesSavedRecord && registry.windows[$0.state.id] === $0.state
        }
        if let product = regular.first(where: { $0.state === registry.activeWindow }) ?? regular.first {
            guard canPresent(), tabs.tree.dataStoreID(for: space) == target, tabs.isProfileAvailable(target) else { return false }
            return tabs.open(url: url, in: product.state, placement: .newTab, parent: .tabs(spaceID: space)) != nil
        }
        // Reuse the existing factory request/admission lifetime. No old saved
        // window is claimed, and its reserved blank becomes the actual copy.
        let state = BrowserWindowState(); state.spaceID = space
        registry.register(state)
        guard registry.windows[state.id] === state else { return false }
        tabs.attach(window: state, restoringSavedState: false)
        let current = { [weak self, weak state] in
            guard let self, let state else { return false }
            return canPresent() && self.registry.windows[state.id] === state &&
                self.tabs.space(space) != nil && self.tabs.tree.dataStoreID(for: space) == target &&
                self.tabs.isProfileAvailable(target)
        }
        let request = SavedRequest(self, state: state, profile: target, close: close,
                                   canPresent: current, initialURL: url)
        target.uuidString.withCString { uuid in
            open(uuid, BARC_PROFILE_BLANK, { status, native, pointer in
                MainActor.assumeIsolated {
                    guard let pointer else { return }
                    Unmanaged<SavedRequest>.fromOpaque(pointer).takeRetainedValue().complete(status, native)
                }
            }, Unmanaged.passRetained(request).toOpaque())
        }
        return registry.windows[state.id] === state
    }

    /// New Window as WebKit's `TabsController.attach` opens it: a saved window nobody has
    /// claimed, else the first space with its first tab selected. It adds no tab.
    @discardableResult
    func openNewWindow(open: SavedOpen, close: @escaping (Int32) -> Int32,
                       canPresent: @escaping () -> Bool) -> Bool {
        guard canPresent(), let state = prepareSavedWindow(nil) else { return false }
        guard let space = state.spaceID, let profile = tabs.profile(forSpace: space),
              tabs.isProfileAvailable(profile.id) else {
            registry.unregister(state.id)
            return false
        }
        let request = SavedRequest(self, state: state, profile: profile.id, close: close, canPresent: canPresent)
        profile.id.uuidString.withCString { uuid in
            open(uuid, BARC_PROFILE_BLANK, { status, native, pointer in
                MainActor.assumeIsolated {
                    guard let pointer else { return }
                    Unmanaged<SavedRequest>.fromOpaque(pointer).takeRetainedValue().complete(status, native)
                }
            }, Unmanaged.passRetained(request).toOpaque())
        }
        return registry.windows[state.id] === state
    }

    func shouldDetachModelWindow(_ state: BrowserWindowState) -> Bool {
        products.values.contains { $0.state === state && !$0.preservesSavedRecord }
    }

    /// First and additional restores share the exact existing record identity.
    /// Saved panes remain cold until their selected layout is admitted natively.
    func prepareInitialWindow() -> BrowserWindowState? {
        let records = tabs.unclaimedWindowRecords()
        // Without a deletion intent, retain attach's existing stale-record normalization.
        guard tabs.device.pendingProfileDeletion != nil else { return prepareSavedWindow(records.first) }
        if let eligible = records.first(where: savedProfileIsAvailable) {
            return prepareSavedWindow(eligible)
        }
        guard let intent = tabs.device.pendingProfileDeletion else {
            return records.isEmpty ? prepareSavedWindow(nil) : nil
        }
        // An unavailable saved target stays untouched. Recovery UI uses only
        // the explicitly persisted survivor, never another/default identity.
        guard tabs.isProfileAvailable(intent.survivor),
              let space = tabs.tree.orderedSpaces.first(where: {
                  !$0.isAgent && tabs.tree.dataStoreID(for: $0.id) == intent.survivor &&
                  tabs.profile(forSpace: $0.id)?.id == intent.survivor
              }) else { return nil }
        let state = BrowserWindowState()
        state.spaceID = space.id
        registry.register(state)
        guard registry.windows[state.id] === state else { return nil }
        tabs.attach(window: state, restoringSavedState: false)
        return state
    }

    private func savedProfileIsAvailable(_ record: WindowRecord) -> Bool {
        guard tabs.device.pendingProfileDeletion != nil else { return true }
        guard let space = record.spaceID else { return false }
        return tabs.profile(forSpace: space) != nil
    }

    private func prepareSavedWindow(_ record: WindowRecord?) -> BrowserWindowState? {
        if let record {
            guard registry.windows[record.id] == nil,
                  tabs.device.windows.contains(where: { $0.id == record.id }) else { return nil }
        }
        let state = BrowserWindowState(id: record?.id ?? UUID())
        registry.register(state)
        guard registry.windows[state.id] === state,
              record == nil || tabs.device.windows.contains(where: { $0.id == state.id }) else {
            if registry.windows[state.id] === state { registry.unregister(state.id) }
            return nil
        }
        tabs.attach(window: state)
        return registry.windows[state.id] === state ? state : nil
    }

    /// Bind the factory's exact reserved blank to an existing saved model, then
    /// present. True accepts the existing restore (ready or pending); completion
    /// reports actual native presentation. No parallel tab/profile registry exists.
    /// A saved split the window cannot show is dropped from it, and the window
    /// opens on its selected tab alone.
    func admitRestoredWindow(_ state: BrowserWindowState, native: Int32, profile: UUID,
                             show: Bool, canPresent: @escaping () -> Bool,
                             initialURL: URL? = nil,
                             initialItemCreated: (@MainActor (UUID) -> Void)? = nil,
                             completion: (@MainActor (NativeSplitOutcome) -> Void)? = nil) -> Bool {
        func current() -> Bool { restoredWindowIsCurrent(state, profile: profile, canPresent: canPresent) }
        guard current(), initialURL == nil || state.selectedItemID == nil,
              let row = bridge.windowState(native), eligibleRegularFactory(row, profile: profile),
              products[row.physical_group] == nil,
              let snapshot = bridge.readSnapshot(),
              let blank = snapshot.tabs.first(where: {
                  $0.window == native && $0.flags & BARC_DISCOVERY_TAB_APP_FACTORY.rawValue != 0
              })?.tab else { return false }
        let shell = makeShell(state)
        guard current(), let checked = bridge.windowState(native), checked.physical_group == row.physical_group,
              eligibleRegularFactory(checked, profile: profile), products[row.physical_group] == nil,
              host.registerWindow(state, nativeOwner: native, shell: shell, initialBlankTab: blank) else { return false }
        let product = ChromiumProductWindow(state: state, shell: shell, preservesSavedRecord: initialURL == nil)
        products[row.physical_group] = product
        if let initialURL {
            // Obtain the operation's item identity without starting a renderer.
            // Report it before selection can call out, including a failed Show.
            guard let item = tabs.open(url: initialURL, in: state, placement: .background) else { return false }
            initialItemCreated?(item)
            guard current(), state.selectedItemID == nil || state.selectedItemID == item,
                  state.split == nil, tabs.item(item)?.url == initialURL else { return false }
            if state.selectedItemID != item { tabs.select(item, in: state) }
        } else if let selected = state.selectedItemID {
            if !tabs.showsPageElsewhere(in: state) { tabs.select(selected, in: state) }
        } else if let space = state.spaceID { tabs.setSpace(space, in: state) }
        state.windowHandle = shell.window // Existing pending-frame authority.
        if finishRestoredPresentation(product, native: native, profile: profile,
                                      show: show, canPresent: canPresent)
            || presentWithoutSplit(product, native: native, profile: profile, show: show, canPresent: canPresent) {
            completion?(.admitted)
            return true
        }
        if current(), state.nativePresentationIsPreparing, !state.nativeSplitIsPreparing {
            let selected = state.selectedItemID, split = state.split
            // The selected page may still await its exact context policy. A
            // saved split starts only after that selection actually succeeds.
            return whenProductPresented(state) { [weak self, weak product] presented in
                guard let self, let product, self.products[row.physical_group] === product,
                      self.registry.windows[state.id] === state else { completion?(.refused); return }
                guard presented != nil else { completion?(.refused); return }
                guard canPresent(), !state.isIncognito, state.privateTree == nil,
                      state.spaceID.flatMap({ self.tabs.tree.dataStoreID(for: $0) }) == profile,
                      presented == native, state.selectedItemID == selected, state.split == split else {
                    completion?(.superseded)
                    // Startup can join the newer owner from that completion.
                    // Forward this actual settled event only after the join;
                    // never eagerly admit during cancellation's transient state.
                    if !state.nativePresentationIsPreparing {
                        state.nativePresentationDidSettle?(true)
                    }
                    return
                }
                let ready = self.finishRestoredPresentation(product, native: native, profile: profile,
                                                           show: show, canPresent: canPresent)
                completion?(ready ? .admitted : .refused)
            }
        }
        guard current(), state.nativeSplitIsPreparing, let record = state.split,
              let active = state.selectedItemID, record.contains(active) else { return false }
        // True is accepted-pending, not completed presentation. The existing
        // model request owns this completion; no polling or second restore queue.
        return tabs.whenNativeSplitPrepared(record, activeItemID: active, in: state) {
            [weak self, weak product] prepared in
            guard prepared != .superseded else { completion?(prepared); return }
            guard prepared == .refused else {
                guard let self, let product else { completion?(.refused); return }
                let ready = self.products[row.physical_group] === product &&
                    self.finishRestoredPresentation(product, native: native, profile: profile,
                                                   show: show, canPresent: canPresent)
                completion?(ready ? .admitted : .refused)
                return
            }
            // A window that is closing refuses its split from inside its unregistration, while it is still registered.
            DispatchQueue.main.async { [weak self, weak product] in
                guard let self, let product, self.products[row.physical_group] === product,
                      state.split == record, state.selectedItemID == active else { completion?(.refused); return }
                let ready = self.presentWithoutSplit(product, native: native, profile: profile, show: show, canPresent: canPresent)
                completion?(ready ? .admitted : .refused)
            }
        }
    }

    /// A saved split the window could not show leaves it, once its selected tab is shown; the
    /// window then opens on that tab alone.
    private func presentWithoutSplit(_ product: ChromiumProductWindow, native: Int32, profile: UUID,
                                     show: Bool, canPresent: () -> Bool) -> Bool {
        let state = product.state
        func current() -> Bool { restoredWindowIsCurrent(state, profile: profile, canPresent: canPresent) }
        guard current(), !state.nativePresentationIsPreparing, let record = state.split,
              let active = state.selectedItemID, record.contains(active),
              let page = tabs.selectedSession(in: state)?.navigation, host.isNativeSelection(page, in: state),
              tabs.reflectNativeSplit(nil, in: state, validateNative: current) else { return false }
        return finishRestoredPresentation(product, native: native, profile: profile, show: show, canPresent: canPresent)
    }

    private func restoredWindowIsCurrent(_ state: BrowserWindowState, profile: UUID, canPresent: () -> Bool) -> Bool {
        canPresent() && registry.windows[state.id] === state && !state.isIncognito && state.privateTree == nil &&
            state.spaceID.flatMap { tabs.tree.dataStoreID(for: $0) } == profile
    }

    private func finishRestoredPresentation(_ product: ChromiumProductWindow, native: Int32,
                                            profile: UUID, show: Bool, canPresent: () -> Bool) -> Bool {
        let state = product.state
        func current() -> Bool {
            canPresent() && registry.windows[state.id] === state && !state.isIncognito &&
            state.spaceID.flatMap { tabs.tree.dataStoreID(for: $0) } == profile
        }
        // An empty space, or a page another window holds, shows over the window's own client.
        let showsNoPage = { state.showsNativeEmptySpace || self.tabs.showsPageElsewhere(in: state) }
        if showsNoPage() {
            guard current(), host.emptySpaceClient(in: state, profile: profile, open: false) == native else { return false }
            if show, bridge.window_show(native) != 1 { return false }
            guard current(), showsNoPage() else { return false }
            product.preservesSavedRecord = false
            if !product.didNotifyStartupWarming {
                product.didNotifyStartupWarming = true
                didPresent(state)
            }
            return true
        }
        guard current(), let page = tabs.selectedSession(in: state)?.navigation as? ChromiumPageNavigation,
              page.nativeWindowID == native, page.profileID == profile, !page.isPrivateSession,
              host.isNativeSelection(page, in: state), modelLayoutPresented(in: state) else { return false }
        if show, bridge.window_show(native) != 1 { return false }
        guard current(), host.isNativeSelection(page, in: state),
              tabs.selectedSession(in: state)?.navigation === page else { return false }
        product.preservesSavedRecord = false
        if !product.didNotifyStartupWarming {
            product.didNotifyStartupWarming = true
            didPresent(state)
        }
        return current() && host.isNativeSelection(page, in: state) &&
            tabs.selectedSession(in: state)?.navigation === page
    }

    /// Cancellation can precede or follow per-page close-cancel delivery. Either
    /// source can retry the same bound page, never a new factory/load operation.
    func resumeRestoredWindows(canPresent: () -> Bool) {
        guard canPresent(), let snapshot = bridge.readSnapshot() else { return }
        for (group, product) in products where product.preservesSavedRecord {
            guard let row = snapshot.windows.first(where: { $0.physical_group == group && $0.selected_client == $0.window }),
                  let profile = row.profileID else { continue }
            _ = finishRestoredPresentation(product, native: row.window, profile: profile, show: true, canPresent: canPresent)
        }
    }

    private func modelLayoutPresented(in state: BrowserWindowState) -> Bool {
        guard let record = state.split, let active = state.selectedItemID, record.contains(active) else { return true }
        let pages = Dictionary(uniqueKeysWithValues: record.itemIDs.compactMap { id in
            tabs.session(for: id).map { (id, $0) }
        })
        return host.isSplit(record, pages: pages, activeItemID: active, in: state)
    }

    /// Join this existing product's actual admission after an initial restore
    /// was superseded. The selected logical client may differ from its factory.
    func whenProductPresented(_ state: BrowserWindowState,
                              completion: @escaping @MainActor (Int32?) -> Void) -> Bool {
        guard let pair = products.first(where: { $0.value.state === state }),
              registry.windows[state.id] === state, !state.isIncognito,
              pair.value.presentationCompletion == nil else { return false }
        var waiting = true
        pair.value.presentationCompletion = { native in
            waiting = false
            completion(native)
        }
        let group = pair.key
        state.nativePresentationDidSettle = { [weak self, weak state, weak product = pair.value] _ in
            guard waiting, let self, let state, let product else { return }
            if let page = self.tabs.selectedSession(in: state)?.navigation as? ChromiumPageNavigation {
                self.admitPreparedProduct(product, native: page.nativeWindowID, group: group)
            }
            if waiting, !state.nativePresentationIsPreparing, product.presentationCompletion != nil {
                self.finishProductPresentation(product, native: nil)
            }
        }
        // Called during cancellation, before the outer newer generation can be
        // installed. Only its actual outcome/catalog mutation may admit a page.
        return true
    }

    private func finishProductPresentation(_ product: ChromiumProductWindow, native: Int32?) {
        let completion = product.presentationCompletion
        product.presentationCompletion = nil
        product.state.nativePresentationDidSettle = nil
        completion?(native)
    }

    func cancelPendingProductPresentation() {
        let completions = products.values.compactMap { product in
            let completion = product.presentationCompletion
            product.presentationCompletion = nil
            product.state.nativePresentationDidSettle = nil
            return completion
        }
        completions.forEach { $0(nil) }
    }

    private func admitPreparedProduct(_ product: ChromiumProductWindow, native: Int32, group: UInt64) {
        guard let initial = bridge.windowState(native),
              product.presentationCompletion != nil ||
              initial.flags & BARC_DISCOVERY_AWAITING_ADMISSION.rawValue != 0 else { return }
        let state = product.state
        func current() -> Bool {
            let expectedProfile = state.isIncognito ? state.ephemeralProfile?.id :
                state.spaceID.flatMap { tabs.profile(forSpace: $0)?.id }
            guard products[group] === product, registry.windows[state.id] === state,
                  !state.nativePresentationIsPreparing, modelLayoutPresented(in: state),
                  let page = tabs.selectedSession(in: state)?.navigation as? ChromiumPageNavigation,
                  page.nativeWindowID == native, page.isPrivateSession == state.isIncognito,
                  let expectedProfile, expectedProfile == page.profileID,
                  host.isNativeSelection(page, in: state),
                  let row = bridge.windowState(native), row.physical_group == group,
                  bridge.identity(row) == expectedProfile,
                  row.active_tab == page.nativeTabID, row.selected_client == native,
                  row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 else { return false }
            return true
        }
        // Attaching the Bark root replays the engine's pending Show or ShowInactive.
        guard current(), let row = bridge.windowState(native),
              row.flags & BARC_DISCOVERY_AWAITING_ADMISSION.rawValue == 0 else { return }
        if !product.didNotifyStartupWarming, !state.isIncognito {
            product.didNotifyStartupWarming = true
            didPresent(state)
        }
        guard current() else { return }
        finishProductPresentation(product, native: native)
    }

    private func retireEndedRestore(_ state: BrowserWindowState) -> Bool {
        guard let pair = products.first(where: { $0.value.state === state }),
              let snapshot = bridge.readSnapshot(), !snapshot.windows.contains(where: { $0.physical_group == pair.key }),
              host.unregisterWindow(state, absentFrom: snapshot) else { return false }
        registry.unregister(state.id)
        products.removeValue(forKey: pair.key)
        finishProductPresentation(pair.value, native: nil)
        return true
    }

    private func eligibleRegularFactory(_ row: BarcDiscoveryWindow, profile: UUID) -> Bool {
        row.physical_group != 0 && row.kind == BARC_DISCOVERY_NORMAL.rawValue &&
        row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 &&
        row.profileID == profile
    }

    typealias SavedOpen = (UnsafePointer<CChar>?, barc_profile_destination, barc_profile_window_callback?, UnsafeMutableRawPointer?) -> Void
    @MainActor private final class SavedRequest {
        weak var admission: ChromiumCreatedPageAdmission?
        let state: BrowserWindowState
        let profile: UUID
        let registry: WindowRegistry
        let bridge: BarcBridge
        let host: ChromiumNativePageHost
        let close: (Int32) -> Int32
        let canPresent: () -> Bool
        let selectedItem: UUID?
        let split: SplitRecord?
        var reservedTab: Int32 = 0
        let initialURL: URL?
        var initialItem: UUID?
        init(_ admission: ChromiumCreatedPageAdmission, state: BrowserWindowState, profile: UUID,
             close: @escaping (Int32) -> Int32, canPresent: @escaping () -> Bool, initialURL: URL? = nil) {
            self.admission = admission; self.state = state; self.profile = profile
            self.registry = admission.registry; self.bridge = admission.bridge; self.host = admission.host
            self.close = close; self.canPresent = canPresent; self.initialURL = initialURL
            selectedItem = state.selectedItemID; split = state.split
        }
        func complete(_ status: barc_profile_status, _ native: Int32) {
            reservedTab = bridge.windowState(native)?.active_tab ?? 0
            if status == BARC_PROFILE_OK, let admission,
               admission.admitRestoredWindow(state, native: native, profile: profile,
                   show: true, canPresent: canPresent, initialURL: initialURL,
                   initialItemCreated: { [self] in initialItem = $0 }, completion: { [self] outcome in
                       if outcome == .refused { refuse(status, native) }
                   }) { return }
            refuse(status, native)
        }
        private func refuse(_ status: barc_profile_status, _ native: Int32) {
            guard state.split == split else { return }
            if let initialItem {
                // A copy can fail before native selection publishes. Claim only
                // its exact item (or the original empty selection), never the
                // arbitrary selection left by a newer intent.
                guard state.selectedItemID == selectedItem || state.selectedItemID == initialItem else { return }
                if let row = bridge.windowState(native), row.active_tab != reservedTab { return }
                if let url = admission?.tabs.item(initialItem)?.url, url != initialURL { return }
            } else {
                guard state.selectedItemID == selectedItem else { return }
            }
            if let admission, let product = admission.products.values.first(where: { $0.state === state }) {
                let ownedSession = initialItem.flatMap { admission.tabs.session(for: $0) } ??
                    admission.tabs.selectedSession(in: state)
                // Another window's page is not this window's to close.
                if let page = ownedSession?.navigation as? ChromiumPageNavigation, page.nativeWindowID == native,
                   page.nativeTabID != reservedTab { return }
                // Once registered, keep model/shell ownership while close is
                // pending or refused. Only actual group disappearance retires it.
                if status == BARC_PROFILE_OK, let row = bridge.windowState(native), row.profileID == profile,
                   host.canCloseUnadmittedWindow(native) {
                    let hasNativeCreatedTabs = bridge.readSnapshot()?.tabs.contains {
                        $0.window == native && $0.flags & BARC_DISCOVERY_TAB_APP_FACTORY.rawValue == 0
                    } == true
                    if !hasNativeCreatedTabs, let page = ownedSession?.navigation,
                       (page as? ChromiumPageNavigation)?.nativeWindowID == native {
                        host.closeUnadmittedWindow(page) { [self, weak admission] outcome in
                            guard let admission else { return }
                            if outcome == .cancelled {
                                _ = admission.finishRestoredPresentation(product, native: native, profile: profile,
                                                                         show: true, canPresent: canPresent)
                            }
                            _ = admission.retireEndedRestore(state)
                        }
                    } else if !hasNativeCreatedTabs { _ = close(native) }
                }
                _ = admission.retireEndedRestore(state)
                return
            }
            if status == BARC_PROFILE_OK, let row = bridge.windowState(native), row.profileID == profile,
               host.canCloseUnadmittedWindow(native) { _ = close(native) }
            // No host/product was published: unregister without normal detach,
            // leaving the original saved record available for retry.
            if registry.windows[state.id] === state { registry.unregister(state.id) }
            fputs(initialURL == nil ? "A saved browser window could not be restored. Its saved state was kept.\n" :
                  "The page copy could not be opened. Its mini window was kept.\n", stderr)
        }
    }

    func restoreSavedWindows(open: SavedOpen, close: @escaping (Int32) -> Int32,
                             only windowIDs: Set<UUID>? = nil,
                             canPresent: @escaping () -> Bool) {
        for record in tabs.unclaimedWindowRecords() where windowIDs?.contains(record.id) ?? true {
            guard canPresent(), registry.windows[record.id] == nil,
                  tabs.device.windows.contains(where: { $0.id == record.id }),
                  savedProfileIsAvailable(record) else { continue }
            guard let state = prepareSavedWindow(record) else { continue }
            guard let space = state.spaceID, let profile = tabs.profile(forSpace: space) else {
                registry.unregister(state.id)
                fputs("A saved unavailable-profile window could not be restored. Its saved state was kept.\n", stderr)
                continue
            }
            let request = SavedRequest(self, state: state, profile: profile.id, close: close, canPresent: canPresent)
            // C borrows this operation until callback; stopped UI delivery can
            // retain it until process shutdown, like other profile factories.
            profile.id.uuidString.withCString { uuid in
                open(uuid, BARC_PROFILE_BLANK, { status, native, pointer in
                    MainActor.assumeIsolated {
                        guard let pointer else { return }
                        Unmanaged<SavedRequest>.fromOpaque(pointer).takeRetainedValue().complete(status, native)
                    }
                }, Unmanaged.passRetained(request).toOpaque())
            }
        }
    }

    /// One explicit profile operation can retire its last native group. Reuse
    /// normal catalog retirement and saved-window admission, with exact IDs.
    func reloadProfileWindows(_ ids: Set<UUID>, open: SavedOpen,
                              close: @escaping (Int32) -> Int32,
                              canPresent: @escaping () -> Bool) {
        guard canPresent(), let snapshot = bridge.readSnapshot() else { return }
        apply(snapshot)
        guard canPresent() else { return }
        for id in ids {
            guard let state = registry.windows[id], !state.isIncognito,
                  let selected = state.selectedItemID,
                  tabs.selectedSession(in: state)?.navigation == nil else { continue }
            tabs.select(selected, in: state)
        }
        restoreSavedWindows(open: open, close: close, only: ids, canPresent: canPresent)
    }

    /// A factory callback explicitly hands off its exact blank; ordinary
    /// discovery continues excluding all still-unclaimed factory pages.
    func admitPrivateFactory(_ window: Int32, canPresent: () -> Bool) -> Bool {
        guard let row = bridge.windowState(window), bridge.privateSessionID(row) != nil,
              let snapshot = bridge.readSnapshot(), row.active_tab > 0 else { return false }
        apply(snapshot, privateFactoryTab: row.active_tab)
        guard let product = products[row.physical_group], canPresent(),
              let current = bridge.windowState(window), current.physical_group == row.physical_group,
              current.selected_client == window, current.active_tab == row.active_tab,
              bridge.privateSessionID(current) == product.state.ephemeralProfile?.id,
              let session = tabs.selectedSession(in: product.state),
              let page = session.navigation as? ChromiumPageNavigation,
              page.nativeWindowID == window, page.nativeTabID == row.active_tab,
              tabs.isNativePageOwner(session, in: product.state), host.isNativeSelection(page, in: product.state) else { return false }
        // The C private blank stays hidden. Showing is the final action after
        // actual model/header/selected-owner admission, never a guessed focus.
        guard bridge.window_show(window) == 1 else { return false }
        page.load(TabsController.homeURL)
        return true
    }

    typealias PrivateOpen = (barc_profile_window_callback?, UnsafeMutableRawPointer?) -> Void
    @MainActor private final class PrivateRequest {
        weak var admission: ChromiumCreatedPageAdmission?
        var cancelled = false
        let canPresent: () -> Bool
        let close: (Int32) -> Int32
        let bridge: BarcBridge
        let host: ChromiumNativePageHost
        init(_ admission: ChromiumCreatedPageAdmission, canPresent: @escaping () -> Bool,
             close: @escaping (Int32) -> Int32) {
            self.admission = admission; self.canPresent = canPresent; self.close = close; self.bridge = admission.bridge; self.host = admission.host
        }
        func complete(_ status: barc_profile_status, _ window: Int32) {
            guard status == BARC_PROFILE_OK, window > 0 else { return }
            if !cancelled, canPresent(), !cancelled, let admission, admission.admitPrivateFactory(window, canPresent: { !self.cancelled && self.canPresent() && !self.cancelled }) { return }
            // Only this verified late factory result can be closed. No selected
            // owner/default UUID lookup is allowed on refusal or cancellation.
            if let row = bridge.windowState(window), bridge.privateSessionID(row) != nil,
               host.canCloseUnadmittedWindow(window) { _ = close(window) }
        }
    }

    @discardableResult
    func openPrivateWindow(open: PrivateOpen, close: @escaping (Int32) -> Int32,
                           canPresent: @escaping () -> Bool) -> () -> Void {
        let request = PrivateRequest(self, canPresent: canPresent, close: close)
        // Retain this pending operation until its single callback, including
        // synchronous completion before cancellation is returned. If shutdown
        // stops UI task delivery, process teardown releases the retained state.
        open({ status, window, pointer in
            MainActor.assumeIsolated {
                guard let pointer else { return }
                Unmanaged<PrivateRequest>.fromOpaque(pointer).takeRetainedValue().complete(status, window)
            }
        }, Unmanaged.passRetained(request).toOpaque())
        return { request.cancelled = true }
    }

    func apply(_ snapshot: ChromiumDiscoverySnapshot, privateFactoryTab: Int32? = nil) {
        // Identity is immutable for a native logical Browser. Resolve private
        // UUIDs once per snapshot row, never once per tab/rendered sidebar row.
        let identities = Dictionary(uniqueKeysWithValues: snapshot.windows.compactMap { row in
            bridge.identity(row).map { (row.window, $0) }
        })
        func identity(_ row: BarcDiscoveryWindow) -> UUID? {
            if row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue { return row.profileID }
            return row.profile_kind == BARC_DISCOVERY_GUEST.rawValue ? identities[row.window] : nil
        }
        func eligible(_ row: BarcDiscoveryWindow) -> Bool {
            row.physical_group != 0 && row.kind == BARC_DISCOVERY_NORMAL.rawValue &&
            row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 && identity(row) != nil
        }
        let liveGroups = Set(snapshot.windows.map(\.physical_group))
        let utilityGroups = Set(snapshot.windows.filter { isUtility($0.window) }.map(\.physical_group))
        let rows = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.window, $0) })
        let selectedRows = Dictionary(uniqueKeysWithValues: snapshot.windows.filter { $0.selected_client == $0.window }.map { ($0.physical_group, $0) })
        var sessions = Dictionary(uniqueKeysWithValues: tabs.sessions.compactMap { session -> (Int32, PageSession)? in
            guard let page = session.navigation as? ChromiumPageNavigation, !page.isClosed else { return nil }
            return (page.nativeTabID, session)
        })
        let groupsByTab: [Int32: UInt64] = snapshot.tabs.contains { $0.flags & BARC_DISCOVERY_TAB_PEEK.rawValue != 0 }
            ? Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tab, rows[$0.window]?.physical_group ?? 0) }) : [:]
        let candidates = snapshot.tabs.filter { tab in
            guard tab.flags & BARC_DISCOVERY_TAB_APP_FACTORY.rawValue == 0 || sessions[tab.tab] != nil || tab.tab == privateFactoryTab,
                  let row = rows[tab.window] else { return false }
            if tab.flags & BARC_DISCOVERY_TAB_PEEK.rawValue != 0,
               sessions[tab.tab] == nil, groupsByTab[tab.peek_source_tab] == row.physical_group { return false }
            return eligible(row) && !utilityGroups.contains(row.physical_group)
        }
        let groupsWithPages = Set(candidates.compactMap { rows[$0.window]?.physical_group })
        for row in selectedRows.values where groupsWithPages.contains(row.physical_group) &&
            products[row.physical_group] == nil {
            guard eligible(row), !utilityGroups.contains(row.physical_group),
                  candidates.contains(where: { $0.window == row.window && $0.tab == row.active_tab }),
                  let profileID = identity(row),
                  let current = bridge.windowState(row.window), current.physical_group == row.physical_group,
                  current.selected_client == row.window, eligible(current) else { continue }
            let state = BrowserWindowState()
            if row.profile_kind == BARC_DISCOVERY_GUEST.rawValue {
                state.isIncognito = true
                state.ephemeralProfile = tabs.privateWindows.compactMap(\.ephemeralProfile)
                    .first(where: { $0.id == profileID }) ?? Profile.createEphemeral(id: profileID, engine: .chromium)
            } else {
                guard let space = space(for: profileID, opener: nil, in: state) else { continue }
                state.spaceID = space
            }
            registry.register(state)
            tabs.attach(window: state, restoringSavedState: false)
            let shell = makeShell(state)
            // Registration owns no native contents. Header admission remains
            // conditional on the host's authoritative live group/profile checks.
            guard host.registerWindow(state, nativeOwner: row.window, shell: shell) else {
                registry.unregister(state.id)
                continue
            }
            products[row.physical_group] = ChromiumProductWindow(state: state, shell: shell)
        }

        // Existing live pages retain their model/session across native moves.
        // An already admitted owner is a pure no-op in adoptNativePage.
        for tab in candidates {
            guard let session = sessions[tab.tab], let page = session.navigation as? ChromiumPageNavigation,
                  page.nativeWindowID == tab.window, let row = rows[tab.window],
                  let product = products[row.physical_group], let profile = session.profile,
                  let space = session.isPrivate ? product.state.spaceID : tabs.spaceID(of: session.itemID),
                  identity(row) == profile.id,
                  (row.profile_kind == BARC_DISCOVERY_GUEST.rawValue) == session.isPrivate else { continue }
            let isPeek = tab.flags & BARC_DISCOVERY_TAB_PEEK.rawValue != 0
            if !isPeek, tabs.isNativePageOwner(session, in: product.state), host.isBoundPage(page, in: product.state) { continue }
            let nativeAdmitted = host.canAdoptPage(page, in: product.state)
            var binding: ChromiumExistingPageBinding?
            if !nativeAdmitted {
                guard case .success(let admission) = host.bindExistingPage(nativeWindow: tab.window,
                    tab: tab.tab, profile: profile, in: product.state) else { continue }
                binding = admission
            }
            let commit = { [self] in
                tabs.adoptNativePage(page, through: host, in: product.state, spaceID: space, select: false) != nil
            }
            let accepted = isPeek ? host.admitMovedPeek(page, commit: commit) : commit()
            binding?.finish(adopted: accepted)
            if isPeek && accepted { didAdoptDetached(tab.tab) }
        }

        // Resolve newly created opener chains in this single callback. Each
        // successful pass consumes rows. An unmodeled/popup opener falls back
        // to this exact profile's existing space without altering the JS opener.
        let candidateIDs = Set(candidates.map(\.tab))
        var created: Set<Int32> = []
        var deferBatchOpeners = true
        var pending = candidates.filter { sessions[$0.tab] == nil }
        while !pending.isEmpty {
            var next: [BarcDiscoveryTab] = []
            var progressed = false
            for tab in pending {
                guard let row = rows[tab.window], let product = products[row.physical_group],
                      let profileID = identity(row),
                      let current = bridge.windowState(tab.window), current.physical_group == row.physical_group,
                      eligible(current), identity(current) == profileID else { continue }
                if deferBatchOpeners, tab.opener_tab != 0, sessions[tab.opener_tab] == nil,
                   candidateIDs.contains(tab.opener_tab) { next.append(tab); continue }
                let opener = sessions[tab.opener_tab].flatMap {
                    $0.profile?.id == profileID && $0.isPrivate == product.state.isIncognito ? $0 : nil
                }
                let requested = bridge.requestedSpace(window: tab.window, tab: tab.tab)
                let targetSpace: UUID?
                if requested.supplied {
                    targetSpace = requested.id.flatMap { id in
                        !product.state.isIncognito && tabs.space(id) != nil &&
                        tabs.tree.dataStoreID(for: id) == profileID && tabs.isProfileAvailable(profileID) ? id : nil
                    }
                } else {
                    targetSpace = space(for: profileID, opener: opener, in: product.state)
                }
                let detached = detachedPage(tab.tab)
                guard let space = targetSpace,
                      let profile = product.state.isIncognito ? product.state.ephemeralProfile : tabs.profile(forSpace: space),
                      detached == nil || (detached?.profile?.id == profileID && detached?.isPrivate == product.state.isIncognito &&
                          detached?.navigation is ChromiumPageNavigation),
                      case .success(let binding) = host.bindExistingPage(nativeWindow: tab.window,
                          tab: tab.tab, profile: profile, in: product.state,
                          existingPage: detached?.navigation as? ChromiumPageNavigation) else { continue }
                let parent = opener.flatMap { product.state.isIncognito && !tabs.isNativePageOwner($0, in: product.state) ? nil : $0.itemID }
                var admitted: PageSession?
                let commit = { [self] in
                    let item: UUID?
                    if let detached {
                        item = tabs.adoptDetachedNativePage(detached, through: host, in: product.state,
                            spaceID: space, from: parent, select: false)
                    } else {
                        item = tabs.adoptNativePage(binding.navigation, through: host, in: product.state,
                            spaceID: space, from: parent, select: false)
                    }
                    admitted = item.flatMap { tabs.session(for: $0) }
                    return registry.windows[product.state.id] === product.state &&
                        admitted?.navigation === binding.navigation &&
                        admitted.map { tabs.isNativePageOwner($0, in: product.state) } == true &&
                        host.canAdoptPage(binding.navigation, in: product.state)
                }
                let valid = tab.flags & BARC_DISCOVERY_TAB_PEEK.rawValue != 0
                    ? host.admitMovedPeek(binding.navigation, commit: commit) : commit()
                binding.finish(adopted: valid)
                if valid, let admitted {
                    sessions[tab.tab] = admitted
                    created.insert(tab.tab)
                    progressed = true
                    if detached === admitted { didAdoptDetached(tab.tab) }
                }
            }
            if !progressed {
                guard deferBatchOpeners, !next.isEmpty else { break }
                deferBatchOpeners = false
            }
            pending = next
        }

        for (group, product) in products where liveGroups.contains(group) && !utilityGroups.contains(group) {
            guard !product.state.nativeSpaceSwitchIsPending, let original = selectedRows[group],
                  let selected = bridge.windowState(original.window), selected.physical_group == group,
                  selected.selected_client == selected.window, eligible(selected),
                  let session = sessions[selected.presentedTab],
                  (session.navigation as? ChromiumPageNavigation)?.nativeWindowID == selected.window else { continue }
            // Reflection attaches the existing shell and publishes selection;
            // unlike ordinary selection it cannot select/focus/load in Chromium.
            let alreadyMirrored = !product.state.nativeSpaceSwitchIsUnresolved &&
                product.state.selectedItemID == session.itemID &&
                session.navigation.map { host.isNativeSelection($0, in: product.state) } == true
            // Chromium activates a neighbour when the active tab closes. While Nook
            // picks the next tab, only a page Chromium just opened, such as a link,
            // or the successor Nook named with the close takes the selection. A page
            // that closed itself reads closed here before its CLOSED reaches the model.
            let closedSelection = (tabs.selectedSession(in: product.state)?.navigation as? ChromiumPageNavigation)?.isClosed == true
            let independentSelection = host.replacedEmptySpaceSelection(in: product.state)
            if tabs.nativeSelectionIsSettling(in: product.state) || closedSelection,
               !created.contains(selected.active_tab), !tabs.isCloseSuccessor(session.itemID, in: product.state),
               !independentSelection {
                if let page = session.navigation { _ = host.acceptNativeSelection(page, in: product.state) }
                continue
            }
            guard alreadyMirrored || tabs.reflectNativeSelection(session.itemID, in: product.state),
                  let verified = bridge.windowState(selected.window), verified.physical_group == group,
                  verified.selected_client == selected.window, verified.presentedTab == selected.presentedTab else { continue }
            if independentSelection { host.setPageHidden(false, in: product.state) }
            product.state.windowHandle = product.shell.window
            if host.needsInitialSplitRestore(in: product.state) {
                tabs.restoreSavedNativeSplitIfNeeded(in: product.state) { [weak self, weak product] success in
                    guard success, let self, let product else { return }
                    self.admitPreparedProduct(product, native: selected.window, group: group)
                }
            }
            guard !product.state.nativeSplitIsPreparing, modelLayoutPresented(in: product.state) else { continue }
            // Selection reflection is not successful restored presentation.
            // A failed Show can still have pending/refused native close.
            admitPreparedProduct(product, native: selected.window, group: group)
        }
        // Admit any destination before retiring a last-tab source, so normal
        // detach removes its record rather than preserving a phantom last window.
        // Logical owner closure does not destroy a surviving physical group's shell.
        for (group, product) in products where !liveGroups.contains(group) {
            guard host.unregisterWindow(product.state, absentFrom: snapshot) else { continue }
            registry.unregister(product.state.id)
            products.removeValue(forKey: group)
            finishProductPresentation(product, native: nil)
        }
        // Re-read only live rows after admission/header callbacks. A selected
        // tab in a background or ShowInactive window is not physical activation.
        var active: BrowserWindowState?
        for row in selectedRows.values {
            guard let product = products[row.physical_group], !utilityGroups.contains(row.physical_group),
                  let current = bridge.windowState(row.window), current.physical_group == row.physical_group,
                  current.selected_client == row.window, eligible(current),
                  current.flags & BARC_DISCOVERY_PHYSICAL_ACTIVE.rawValue != 0 else { continue }
            active = product.state
            break
        }
        if let active {
            if registry.activeWindowId != active.id { registry.setActive(active) }
        }
        for (group, product) in products where liveGroups.contains(group) && !utilityGroups.contains(group) {
            host.closeSurplusClients(in: product.state, snapshot: snapshot)
        }
    }

    private func space(for profile: UUID, opener: PageSession?, in window: BrowserWindowState) -> UUID? {
        if window.isIncognito {
            guard window.ephemeralProfile?.id == profile else { return nil }
            // An opener in another private window retains its native relation;
            // only an opener in this window participates in the local tree.
            return window.spaceID
        }
        if let opener {
            guard opener.profile?.id == profile else { return nil }
            return tabs.spaceID(of: opener.itemID)
        }
        return tabs.profiles.first(where: { $0.id == profile })?.spaceIDs.first
    }
}
