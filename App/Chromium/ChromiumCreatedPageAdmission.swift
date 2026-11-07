import AppKit
import BarcChromium
import NookWeb

/// One actual product window, sharing the existing model registry and sidebar.
/// The hosting view retains its window-local palette/organizer/hover state.
@MainActor
final class ChromiumProductWindow {
    let state: BrowserWindowState
    let shell: NSView
    init(state: BrowserWindowState, shell: NSView) { self.state = state; self.shell = shell }
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

    func apply(_ snapshot: ChromiumDiscoverySnapshot) {
        let liveGroups = Set(snapshot.windows.map(\.physical_group))
        let utilityGroups = Set(snapshot.windows.filter { isUtility($0.window) }.map(\.physical_group))
        let rows = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.window, $0) })
        let selectedRows = Dictionary(uniqueKeysWithValues: snapshot.windows.filter { $0.selected_client == $0.window }.map { ($0.physical_group, $0) })
        var sessions = Dictionary(uniqueKeysWithValues: tabs.sessions.compactMap { session -> (Int32, PageSession)? in
            guard let page = session.navigation as? ChromiumPageNavigation, !page.isClosed else { return nil }
            return (page.nativeTabID, session)
        })
        let candidates = snapshot.tabs.filter { tab in
            guard tab.flags & BARC_DISCOVERY_TAB_APP_FACTORY.rawValue == 0 || sessions[tab.tab] != nil,
                  let row = rows[tab.window] else { return false }
            return eligible(row) && !utilityGroups.contains(row.physical_group)
        }
        let groupsWithPages = Set(candidates.compactMap { rows[$0.window]?.physical_group })
        for row in selectedRows.values where groupsWithPages.contains(row.physical_group) &&
            products[row.physical_group] == nil {
            guard eligible(row), !utilityGroups.contains(row.physical_group),
                  candidates.contains(where: { $0.window == row.window && $0.tab == row.active_tab }),
                  let profileID = ChromiumDiscoveryAPI.profileID(row),
                  let space = space(for: profileID, opener: nil),
                  let current = api.windowState(row.window), current.physical_group == row.physical_group,
                  current.selected_client == row.window, eligible(current) else { continue }
            let state = BrowserWindowState()
            state.spaceID = space
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
                  let space = tabs.spaceID(of: session.itemID),
                  ChromiumDiscoveryAPI.profileID(row) == profile.id else { continue }
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
                      let profileID = ChromiumDiscoveryAPI.profileID(row),
                      let current = api.windowState(tab.window), current.physical_group == row.physical_group,
                      eligible(current), ChromiumDiscoveryAPI.profileID(current) == profileID else { continue }
                if deferBatchOpeners, tab.opener_tab != 0, sessions[tab.opener_tab] == nil,
                   candidateIDs.contains(tab.opener_tab) { next.append(tab); continue }
                let opener = sessions[tab.opener_tab].flatMap { $0.profile?.id == profileID ? $0 : nil }
                guard let space = space(for: profileID, opener: opener),
                      let profile = tabs.profile(forSpace: space),
                      case .success(let binding) = host.bindExistingPage(nativeWindow: tab.window,
                          tab: tab.tab, profile: profile, in: product.state) else { continue }
                let item = tabs.adoptNativePage(binding.navigation, through: host, in: product.state,
                    spaceID: space, from: opener?.itemID, select: false)
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

    private func eligible(_ row: BarcDiscoveryWindow) -> Bool {
        row.physical_group != 0 && row.kind == BARC_DISCOVERY_NORMAL.rawValue &&
        row.profile_kind == BARC_DISCOVERY_REGULAR.rawValue &&
        row.flags & BARC_DISCOVERY_OWNER_ENDING.rawValue == 0 && ChromiumDiscoveryAPI.profileID(row) != nil
    }

    private func space(for profile: UUID, opener: PageSession?) -> UUID? {
        if let opener {
            guard opener.profile?.id == profile else { return nil }
            return tabs.spaceID(of: opener.itemID)
        }
        return tabs.profiles.first(where: { $0.id == profile })?.spaceIDs.first
    }
}
