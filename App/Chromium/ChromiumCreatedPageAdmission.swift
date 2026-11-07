import AppKit
import BarcChromium
import NookWeb
import NookTabsCore

/// One actual product window, sharing the existing model registry and sidebar.
/// The hosting view retains its window-local palette/organizer/hover state.
@MainActor
final class ChromiumProductWindow {
    let state: BrowserWindowState
    let shell: NSView
    /// A failed restore must not erase its already-saved window record.
    var preservesSavedRecord: Bool
    init(state: BrowserWindowState, shell: NSView, preservesSavedRecord: Bool = false) {
        self.state = state; self.shell = shell; self.preservesSavedRecord = preservesSavedRecord
    }
}

/// Admission of existing native pages, not a second tab model. Only the native
/// group -> existing product lifetime association survives a callback.
@MainActor
final class ChromiumCreatedPageAdmission {
    private let api: ChromiumDiscoveryAPI
    private let host: ChromiumNativePageHost
    private let tabs: TabsController
    private let registry: WindowRegistry
    private let isUtility: (Int32) -> Bool
    private let makeShell: (BrowserWindowState) -> NSView
    private var products: [UInt64: ChromiumProductWindow] = [:]

    init(api: ChromiumDiscoveryAPI, host: ChromiumNativePageHost, tabs: TabsController,
         registry: WindowRegistry, isUtility: @escaping (Int32) -> Bool,
         makeShell: @escaping (BrowserWindowState) -> NSView) {
        self.api = api; self.host = host; self.tabs = tabs; self.registry = registry
        self.isUtility = isUtility; self.makeShell = makeShell
    }

    func registerInitial(_ product: ChromiumProductWindow, nativeWindow: Int32) -> Bool {
        guard let row = api.windowState(nativeWindow), row.physical_group != 0,
              products[row.physical_group] == nil else { return false }
        products[row.physical_group] = product
        return true
    }

    func shouldDetachModelWindow(_ state: BrowserWindowState) -> Bool {
        products.values.contains { $0.state === state && !$0.preservesSavedRecord }
    }

    /// First and additional restores share the exact existing record identity.
    /// A saved split remains unclaimed until native split presentation exists.
    func prepareInitialWindow() -> BrowserWindowState? {
        prepareSavedWindow(tabs.unclaimedWindowRecords().first)
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
        guard state.split == nil else {
            registry.unregister(state.id)
            fputs("A saved split-view window cannot yet be restored in Chromium. Its saved state was kept.\n", stderr)
            return nil
        }
        return registry.windows[state.id] === state ? state : nil
    }

    /// Bind the factory's exact reserved blank to an existing saved model, then
    /// present. No new tab tree, profile registry or incoming-URL replay exists.
    func admitRestoredWindow(_ state: BrowserWindowState, native: Int32, profile: UUID,
                             show: Bool, canPresent: () -> Bool) -> Bool {
        func current() -> Bool {
            canPresent() && registry.windows[state.id] === state && !state.isIncognito &&
            state.privateTree == nil && state.split == nil &&
            state.spaceID.flatMap { tabs.tree.dataStoreID(for: $0) } == profile
        }
        guard current(), let row = api.windowState(native), eligibleRegularFactory(row, profile: profile),
              products[row.physical_group] == nil,
              let snapshot = api.readSnapshot(),
              let blank = snapshot.tabs.first(where: {
                  $0.window == native && $0.flags & BARC_DISCOVERY_TAB_APP_FACTORY.rawValue != 0
              })?.tab else { return false }
        let shell = makeShell(state)
        guard current(), let checked = api.windowState(native), checked.physical_group == row.physical_group,
              eligibleRegularFactory(checked, profile: profile), products[row.physical_group] == nil,
              host.registerWindow(state, nativeOwner: native, shell: shell, initialBlankTab: blank) else { return false }
        let product = ChromiumProductWindow(state: state, shell: shell, preservesSavedRecord: true)
        products[row.physical_group] = product
        if let selected = state.selectedItemID { tabs.select(selected, in: state) }
        else { _ = tabs.open(url: URL(string: "about:blank")!, in: state, placement: .newTab) }
        state.windowHandle = shell.window // Existing pending-frame authority.
        return finishRestoredPresentation(product, native: native, profile: profile,
                                          show: show, canPresent: canPresent)
    }

    private func finishRestoredPresentation(_ product: ChromiumProductWindow, native: Int32,
                                            profile: UUID, show: Bool, canPresent: () -> Bool) -> Bool {
        let state = product.state
        func current() -> Bool {
            canPresent() && registry.windows[state.id] === state && !state.isIncognito && state.split == nil &&
            state.spaceID.flatMap { tabs.tree.dataStoreID(for: $0) } == profile
        }
        guard current(), let page = tabs.selectedSession(in: state)?.navigation as? ChromiumPageNavigation,
              page.nativeWindowID == native, page.profileID == profile, !page.isPrivateSession,
              host.isNativeSelection(page, in: state) else { return false }
        if show, api.show(native) != 1 { return false }
        guard current(), host.isNativeSelection(page, in: state),
              tabs.selectedSession(in: state)?.navigation === page else { return false }
        product.preservesSavedRecord = false
        return true
    }

    /// Cancellation can precede or follow per-page close-cancel delivery. Either
    /// source can retry the same bound page, never a new factory/load operation.
    func resumeRestoredWindows(canPresent: () -> Bool) {
        guard canPresent(), let snapshot = api.readSnapshot() else { return }
        for (group, product) in products where product.preservesSavedRecord {
            guard let row = snapshot.windows.first(where: { $0.physical_group == group && $0.selected_client == $0.window }),
                  let profile = ChromiumDiscoveryAPI.profileID(row) else { continue }
            _ = finishRestoredPresentation(product, native: row.window, profile: profile, show: true, canPresent: canPresent)
        }
    }

    private func retireEndedRestore(_ state: BrowserWindowState) -> Bool {
        guard let pair = products.first(where: { $0.value.state === state }),
              let snapshot = api.readSnapshot(), !snapshot.windows.contains(where: { $0.physical_group == pair.key }),
              host.unregisterWindow(state, absentFrom: snapshot) else { return false }
        registry.unregister(state.id)
        products.removeValue(forKey: pair.key)
        return true
    }

    private func eligibleRegularFactory(_ row: BarcDiscoveryWindow, profile: UUID) -> Bool {
        row.physical_group != 0 && row.kind == BARC_DISCOVERY_NORMAL.rawValue &&
        row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 &&
        ChromiumDiscoveryAPI.profileID(row) == profile
    }

    typealias SavedCallback = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void
    typealias SavedOpen = @convention(c) (UnsafePointer<CChar>?, Int32, SavedCallback?, UnsafeMutableRawPointer?) -> Void
    @MainActor private final class SavedRequest {
        weak var admission: ChromiumCreatedPageAdmission?
        let state: BrowserWindowState
        let profile: UUID
        let registry: WindowRegistry
        let api: ChromiumDiscoveryAPI
        let host: ChromiumNativePageHost
        let close: (Int32) -> Int32
        let canPresent: () -> Bool
        init(_ admission: ChromiumCreatedPageAdmission, state: BrowserWindowState, profile: UUID,
             close: @escaping (Int32) -> Int32, canPresent: @escaping () -> Bool) {
            self.admission = admission; self.state = state; self.profile = profile
            self.registry = admission.registry; self.api = admission.api; self.host = admission.host
            self.close = close; self.canPresent = canPresent
        }
        func complete(_ status: Int32, _ native: Int32) {
            if status == 0, let admission,
               admission.admitRestoredWindow(state, native: native, profile: profile,
                                              show: true, canPresent: canPresent) { return }
            if let admission, let product = admission.products.values.first(where: { $0.state === state }) {
                // Once registered, keep model/shell ownership while close is
                // pending or refused. Only actual group disappearance retires it.
                if status == 0, let row = api.windowState(native), ChromiumDiscoveryAPI.profileID(row) == profile,
                   host.canCloseUnadmittedWindow(native) {
                    let hasNativeCreatedTabs = api.readSnapshot()?.tabs.contains {
                        $0.window == native && $0.flags & BARC_DISCOVERY_TAB_APP_FACTORY.rawValue == 0
                    } == true
                    if !hasNativeCreatedTabs, let page = admission.tabs.selectedSession(in: state)?.navigation,
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
            if status == 0, let row = api.windowState(native), ChromiumDiscoveryAPI.profileID(row) == profile,
               host.canCloseUnadmittedWindow(native) { _ = close(native) }
            // No host/product was published: unregister without normal detach,
            // leaving the original saved record available for retry.
            if registry.windows[state.id] === state { registry.unregister(state.id) }
            fputs("A saved browser window could not be restored. Its saved state was kept.\n", stderr)
        }
    }

    func restoreSavedWindows(open: SavedOpen, close: @escaping (Int32) -> Int32,
                             canPresent: @escaping () -> Bool) {
        for record in tabs.unclaimedWindowRecords() {
            guard canPresent(), registry.windows[record.id] == nil,
                  tabs.device.windows.contains(where: { $0.id == record.id }) else { continue }
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
                open(uuid, 5, { status, native, pointer in
                    MainActor.assumeIsolated {
                        guard let pointer else { return }
                        Unmanaged<SavedRequest>.fromOpaque(pointer).takeRetainedValue().complete(status, native)
                    }
                }, Unmanaged.passRetained(request).toOpaque())
            }
        }
    }

    /// A factory callback explicitly hands off its exact blank; ordinary
    /// discovery continues excluding all still-unclaimed factory pages.
    func admitPrivateFactory(_ window: Int32, canPresent: () -> Bool) -> Bool {
        guard let row = api.windowState(window), api.privateSessionID(row) != nil,
              let snapshot = api.readSnapshot(), row.active_tab > 0 else { return false }
        apply(snapshot, privateFactoryTab: row.active_tab)
        guard let product = products[row.physical_group], canPresent(),
              let current = api.windowState(window), current.physical_group == row.physical_group,
              current.selected_client == window, current.active_tab == row.active_tab,
              api.privateSessionID(current) == product.state.ephemeralProfile?.id,
              let session = tabs.selectedSession(in: product.state),
              let page = session.navigation as? ChromiumPageNavigation,
              page.nativeWindowID == window, page.nativeTabID == row.active_tab,
              tabs.isNativePageOwner(session, in: product.state), host.isNativeSelection(page, in: product.state) else { return false }
        // The C private blank stays hidden. Showing is the final action after
        // actual model/header/selected-owner admission, never a guessed focus.
        return api.show(window) == 1
    }

    typealias PrivateOpen = @convention(c) (@convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?) -> Void
    @MainActor private final class PrivateRequest {
        weak var admission: ChromiumCreatedPageAdmission?
        var cancelled = false
        let canPresent: () -> Bool
        let close: (Int32) -> Int32
        let api: ChromiumDiscoveryAPI
        let host: ChromiumNativePageHost
        init(_ admission: ChromiumCreatedPageAdmission, canPresent: @escaping () -> Bool,
             close: @escaping (Int32) -> Int32) {
            self.admission = admission; self.canPresent = canPresent; self.close = close; self.api = admission.api; self.host = admission.host
        }
        func complete(_ status: Int32, _ window: Int32) {
            guard status == 0, window > 0 else { return }
            if !cancelled, canPresent(), !cancelled, let admission, admission.admitPrivateFactory(window, canPresent: { !self.cancelled && self.canPresent() && !self.cancelled }) { return }
            // Only this verified late factory result can be closed. No selected
            // owner/default UUID lookup is allowed on refusal or cancellation.
            if let row = api.windowState(window), api.privateSessionID(row) != nil,
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
            api.identity(row).map { (row.window, $0) }
        })
        func identity(_ row: BarcDiscoveryWindow) -> UUID? {
            if row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue { return ChromiumDiscoveryAPI.profileID(row) }
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
        let candidates = snapshot.tabs.filter { tab in
            guard tab.flags & BARC_DISCOVERY_TAB_APP_FACTORY.rawValue == 0 || sessions[tab.tab] != nil || tab.tab == privateFactoryTab,
                  let row = rows[tab.window] else { return false }
            return eligible(row) && !utilityGroups.contains(row.physical_group)
        }
        let groupsWithPages = Set(candidates.compactMap { rows[$0.window]?.physical_group })
        for row in selectedRows.values where groupsWithPages.contains(row.physical_group) &&
            products[row.physical_group] == nil {
            guard eligible(row), !utilityGroups.contains(row.physical_group),
                  candidates.contains(where: { $0.window == row.window && $0.tab == row.active_tab }),
                  let profileID = identity(row),
                  let current = api.windowState(row.window), current.physical_group == row.physical_group,
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
            if tabs.isNativePageOwner(session, in: product.state) && host.isBoundPage(page, in: product.state) { continue }
            let nativeAdmitted = host.canAdoptPage(page, in: product.state)
            var binding: ChromiumExistingPageBinding?
            if !nativeAdmitted {
                guard case .success(let admission) = host.bindExistingPage(nativeWindow: tab.window,
                    tab: tab.tab, profile: profile, in: product.state) else { continue }
                binding = admission
            }
            let item = tabs.adoptNativePage(page, through: host, in: product.state, spaceID: space, select: false)
            binding?.finish(adopted: item != nil)
        }

        // Resolve newly created opener chains in this single callback. Each
        // successful pass consumes rows. An unmodeled/popup opener falls back
        // to this exact profile's existing space without altering the JS opener.
        let candidateIDs = Set(candidates.map(\.tab))
        var deferBatchOpeners = true
        var pending = candidates.filter { sessions[$0.tab] == nil }
        while !pending.isEmpty {
            var next: [BarcDiscoveryTab] = []
            var progressed = false
            for tab in pending {
                guard let row = rows[tab.window], let product = products[row.physical_group],
                      let profileID = identity(row),
                      let current = api.windowState(tab.window), current.physical_group == row.physical_group,
                      eligible(current), identity(current) == profileID else { continue }
                if deferBatchOpeners, tab.opener_tab != 0, sessions[tab.opener_tab] == nil,
                   candidateIDs.contains(tab.opener_tab) { next.append(tab); continue }
                let opener = sessions[tab.opener_tab].flatMap {
                    $0.profile?.id == profileID && $0.isPrivate == product.state.isIncognito ? $0 : nil
                }
                guard let space = space(for: profileID, opener: opener, in: product.state),
                      let profile = product.state.isIncognito ? product.state.ephemeralProfile : tabs.profile(forSpace: space),
                      case .success(let binding) = host.bindExistingPage(nativeWindow: tab.window,
                          tab: tab.tab, profile: profile, in: product.state) else { continue }
                let item = tabs.adoptNativePage(binding.navigation, through: host, in: product.state,
                    spaceID: space, from: opener.flatMap { product.state.isIncognito && !tabs.isNativePageOwner($0, in: product.state) ? nil : $0.itemID }, select: false)
                binding.finish(adopted: item != nil)
                if let item, let session = tabs.session(for: item) {
                    sessions[tab.tab] = session
                    progressed = true
                }
            }
            if !progressed {
                guard deferBatchOpeners, !next.isEmpty else { break }
                deferBatchOpeners = false
            }
            pending = next
        }

        for (group, product) in products where liveGroups.contains(group) && !utilityGroups.contains(group) {
            guard let original = selectedRows[group],
                  let selected = api.windowState(original.window), selected.physical_group == group,
                  selected.selected_client == selected.window, eligible(selected),
                  let session = sessions[selected.active_tab],
                  (session.navigation as? ChromiumPageNavigation)?.nativeWindowID == selected.window else { continue }
            // Reflection attaches the existing shell and publishes selection;
            // unlike ordinary selection it cannot select/focus/load in Chromium.
            let alreadyMirrored = product.state.selectedItemID == session.itemID &&
                session.navigation.map { host.isNativeSelection($0, in: product.state) } == true
            guard alreadyMirrored || tabs.reflectNativeSelection(session.itemID, in: product.state),
                  let verified = api.windowState(selected.window), verified.physical_group == group,
                  verified.selected_client == selected.window, verified.active_tab == selected.active_tab else { continue }
            product.state.windowHandle = product.shell.window
            // Selection reflection is not successful restored presentation.
            // A failed Show can still have pending/refused native close.
            if verified.flags & BARC_DISCOVERY_AWAITING_ADMISSION.rawValue != 0 {
                _ = api.admit(selected.window, Unmanaged.passUnretained(product.shell).toOpaque())
            }
        }
        // Admit any destination before retiring a last-tab source, so normal
        // detach removes its record rather than preserving a phantom last window.
        // Logical owner closure does not destroy a surviving physical group's shell.
        for (group, product) in products where !liveGroups.contains(group) {
            guard host.unregisterWindow(product.state, absentFrom: snapshot) else { continue }
            registry.unregister(product.state.id)
            products.removeValue(forKey: group)
        }
        // Re-read only live rows after admission/header callbacks. A selected
        // tab in a background or ShowInactive window is not physical activation.
        var active: BrowserWindowState?
        for row in selectedRows.values {
            guard let product = products[row.physical_group], !utilityGroups.contains(row.physical_group),
                  let current = api.windowState(row.window), current.physical_group == row.physical_group,
                  current.selected_client == row.window, eligible(current),
                  current.flags & BARC_DISCOVERY_PHYSICAL_ACTIVE.rawValue != 0 else { continue }
            active = product.state
            break
        }
        if let active {
            if registry.activeWindowId != active.id { registry.setActive(active) }
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
