// Licensed under GPL-3.0. See LICENSE.
//
//  TabsController+Intents.swift
//  Nook
//
//  Every user-facing change to tabs, folders, spaces and window selection.
//

import Foundation
import NookTabsCore

extension TabsController {
    // MARK: - Open

    /// Creates a tab for `url`: at the top of `parent` when one is given; where a link from
    /// `opener`'s page goes (`childTabPosition`); else right below the window's selected tab
    /// (`newTabPosition`). `.newTab` selects it, `.background` leaves
    /// selection alone and loads the page only when it comes from `opener`, as Arc does with a
    /// Command-clicked link, `.replaceCurrent` loads `url` in the selected page.
    /// `title` stands in for the page title until the page loads.
    @discardableResult
    public func open(url: URL, in window: BrowserWindowState, placement: Placement, parent: Parent? = nil, from opener: UUID? = nil, title: String? = nil) -> UUID? {
        if placement == .replaceCurrent, let selected = window.selectedItemID, let session = ensureSession(for: selected) {
            session.load(url)
            select(selected, in: window)
            return selected
        }
        guard let position = parent.map({ ($0, UUID?.none) })
                ?? opener.flatMap({ childTabPosition(in: window, opener: $0) })
                ?? newTabPosition(in: window, after: window.selectedItemID)
        else { return nil }
        let id = UUID()
        let created = perform(owner(of: window), "open") {
            try $0.createTab(id: id, url: url, title: title ?? url.host ?? url.absoluteString, in: position.0, after: position.1)
        }
        guard created != nil else { return nil }
        if let opener { linked(id, from: opener, at: position.0, owner: owner(of: window)) }
        if placement != .background {
            select(id, in: window)
        } else if opener != nil, let session = ensureSession(for: id) {
            // This window's page, for its mini player, until another window selects it.
            if profileEngine == .chromium { recordPageOwner(id, in: window) }
            else { takeControl(id, in: window) }
            session.loadWebViewIfNeeded()
            onPageLoadedInBackground?(session)
        }
        return id
    }

    /// Where a new tab goes: right below the selected tab, or below its outermost folder with
    /// "Open new tabs ungrouped" on; else the top of the tabs section. A pinned tab or favorite
    /// keeps its section to itself. A new tab is no one's child, so trails are always climbed.
    func newTabPosition(in window: BrowserWindowState, space: UUID? = nil, after anchor: UUID?) -> (Parent, UUID?)? {
        guard let spaceID = space ?? window.spaceID else { return nil }
        return tree(owner(of: window)).newTabPosition(in: spaceID, after: anchor, climbingFolders: settings.newTabsAtTopLevel)
    }

    /// The item a Cmd+T tab goes after, for the command bar to say where it lands; nil when it
    /// goes to the top of Tabs.
    public func newTabAnchorTitle(in window: BrowserWindowState) -> String? {
        guard let (_, after) = newTabPosition(in: window, after: window.selectedItemID),
              let after, let item = item(after) else { return nil }
        return title(for: item)
    }

    /// Where a tab opened from `opener`'s page goes (`TabTree.linkTabPosition`): a child of a
    /// normal tab while nesting is on, else after the tabs already opened from it in the Tabs section.
    func childTabPosition(in window: BrowserWindowState, opener: UUID) -> (Parent, UUID?)? {
        let owner = owner(of: window)
        // An agent page's tabs stay in the Agent space whatever the window shows.
        guard let spaceID = isInAgentSpace(opener) ? agentSpaceID : window.spaceID else { return nil }
        return tree(owner).linkTabPosition(in: spaceID, opener: opener, nest: settings.nestLinkTabsUnderOpener, openers: openers(owner))
    }

    /// After a link tab is created: a child shows at once, even when its tab was collapsed; a
    /// sibling remembers its opener for Back.
    private func linked(_ id: UUID, from opener: UUID, at parent: Parent, owner: Owner) {
        if parent == .folder(itemID: opener) {
            openFolder(opener)
            return
        }
        switch owner {
        case .main: recordOpener(opener, of: id)
        case .privateWindow(let window): window.privateOpeners[id] = opener
        }
    }

    func openers(_ owner: Owner) -> [UUID: UUID] {
        switch owner {
        case .main: return device.openers ?? [:]
        case .privateWindow(let window): return window.privateOpeners
        }
    }

    /// Complete an admitted native adoption through the existing selection and
    /// opener bookkeeping, without repeating native selection or navigation.
    func finishNativeAdoption(_ session: PageSession, in window: BrowserWindowState,
                              opener: UUID?, parent: Parent?, select shouldSelect: Bool, generation: UUID?,
                              validateNative: (() -> Bool)? = nil) {
        if let opener, let parent { linked(session.itemID, from: opener, at: parent, owner: owner(of: window)) }
        if shouldSelect {
            select(session.itemID, in: window, leaving: selectedSession(in: window), nativeAdmitted: true, adoptionGeneration: generation, validateNative: validateNative)
        } else {
            recordPageOwner(session.itemID, in: window)
        }
    }

    // MARK: - Selection

    /// A palette selection's destination, when it would leave the window's current space.
    public func tabSwitchDestination(for itemID: UUID, in window: BrowserWindowState)
        -> (name: String, icon: String, profileName: String?)? {
        let source = tree(owner(of: window))
        guard let spaceID = selectionSpaceID(for: itemID, currentSpaceID: window.spaceID, in: source),
              spaceID != window.spaceID, let space = source.space(spaceID) else { return nil }
        let profileName = source.profile(ofSpace: spaceID)?.name
        return (space.name, space.icon, profileName == space.name ? nil : profileName)
    }

    private func selectionSpaceID(for itemID: UUID, currentSpaceID: UUID?, in source: TabTree) -> UUID? {
        guard let home = source.spaceID(of: itemID) else { return nil }
        // A favorite shared with the window's space opens there, without switching spaces.
        if case .favorites = source.section(of: itemID), let currentSpaceID,
           source.sharesFavorites(home, currentSpaceID) { return currentSpaceID }
        return home
    }

    public func select(_ itemID: UUID, in window: BrowserWindowState) {
        select(itemID, in: window, leaving: selectedSession(in: window))
    }

    /// `previous` is what the window showed before; a space switch has already moved on from it.
    private func select(_ itemID: UUID, in window: BrowserWindowState, leaving previous: PageSession?,
                        nativeAdmitted: Bool = false, showingAgentSpace: Bool = false,
                        adoptionGeneration: UUID? = nil,
                        validateNative: (() -> Bool)? = nil, preferredSpace: UUID? = nil) {
        func admissionIsCurrent() -> Bool {
            (adoptionGeneration == nil || (window.nativeSelectionGeneration == adoptionGeneration &&
                windowRegistry.windows[window.id] === window && item(itemID) != nil)) &&
            (validateNative?() ?? true)
        }
        guard admissionIsCurrent() else { return }
        let owner = owner(of: window)
        let source = tree(owner)
        guard let item = source.item(itemID) else { return }
        if item.isFolder {
            toggleFolder(itemID)
            return
        }
        if isInAgentSpace(itemID), window.spaceID != agentSpaceID, !showingAgentSpace {
            return selectForAgent(itemID)
        }
        if profileEngine == .chromium && !nativeAdmitted {
            // A split pane can lose activation to another pane of the same client.
            // Let Chromium settle the selection before routing page commands.
            let switchesPane = window.selectedItemID != itemID && window.split?.contains(itemID) == true
            if let host = nativePageHost as? any NativeSpaceSwitchHost,
               let space = selectionSpaceID(for: itemID, currentSpaceID: window.spaceID, in: source) {
                let changesSpace = !window.isIncognito && (space != window.spaceID || window.showsNativeEmptySpace)
                if changesSpace || switchesPane || window.nativeSpaceSwitchIsPending {
                    switchNativeSpace(space, itemID: itemID, in: window, through: host)
                    return
                }
            }
            prepareNativeSelection(itemID, in: window) { [weak self, weak window] in
                guard let self, let window else { return }
                self.select(itemID, in: window, leaving: self.selectedSession(in: window),
                            nativeAdmitted: true, showingAgentSpace: showingAgentSpace)
                if window.selectedItemID == itemID { self.restoreSavedNativeSplitIfNeeded(in: window) }
            }
            return
        }
        // An agent tab never pulls a window into the Agent space; the person opens it to watch.
        if isInAgentSpace(itemID) {
            guard window.spaceID == agentSpaceID || showingAgentSpace else { return selectForAgent(itemID) }
            agentItemID = itemID
        }
        let itemSpace = preferredSpace ?? selectionSpaceID(for: itemID, currentSpaceID: window.spaceID, in: source)
        let movedSpace = itemSpace.map { $0 != window.spaceID } ?? false
        guard let spaceID = itemSpace ?? window.spaceID else { return }
        if preferredSpace != nil {
            // An outcome supplies the space and its pane together. When the new
            // space becomes visible its remembered pane is already up to date.
            window.selectedItemBySpace[spaceID] = itemID
            guard admissionIsCurrent() else { return }
        }
        if let itemSpace, preferredSpace == nil || movedSpace { window.spaceID = itemSpace }
        if movedSpace { sessionDelegate?.windowSpaceChanged(window) }
        guard admissionIsCurrent() else { return }
        if preferredSpace == nil { window.selectedItemBySpace[spaceID] = itemID }
        guard admissionIsCurrent() else {
            // An observation callback can move a private page before this
            // setter returns. Never reclaim its newer owner or retain a stale
            // selection in a tree that no longer contains it.
            if window.isIncognito, window.privateTree?.item(itemID) == nil,
               window.selectedItemBySpace[spaceID] == itemID {
                window.selectedItemBySpace[spaceID] = nil
            }
            return
        }
        window.emptiedSpaces.remove(spaceID)
        if case .main = owner { markSeen([itemID] + (previous.map { [$0.itemID] } ?? [])) }
        // The latest window to select a page takes its live view; others show a placeholder.
        if profileEngine == .chromium { recordPageOwner(itemID, in: window) }
        else { takeControl(itemID, in: window) }
        guard admissionIsCurrent() else { return }
        var recent = window.recentItemsBySpace[spaceID, default: []]
        recent.removeAll { $0 == itemID }
        recent.append(itemID)
        window.recentItemsBySpace[spaceID] = recent.suffix(Self.recentLimit)

        if let session = ensureSession(for: itemID) {
            if let previous, previous !== session {
                onLeavingTab?(previous.itemID, window)
                guard admissionIsCurrent() else { return }
                if profileEngine != .chromium { previous.captureSwitcherSnapshot() }
                dropStaleSwitcherSnapshots()
            }
            session.loadWebViewIfNeeded()
            guard admissionIsCurrent() else { return }
            if session !== previous, !session.isPrivate {
                tabEvents?.tabActivated(new: session, previous: previous)
                guard admissionIsCurrent() else { return }
            }
            // The mini player goes by the frames' reports; ask again rather than wait for them.
            if let previous, previous !== session { previous.refreshMediaReports() }
            session.refreshMediaReports()
        }
        guard admissionIsCurrent() else { return }
        mirror(window)
        window.refreshCompositor()
    }

    /// Keeps switcher pictures only for each window's most recent tabs (what the card can show).
    private func dropStaleSwitcherSnapshots() {
        let keep = Set(allWindows.flatMap { recentItems(in: $0).prefix(TabSwitcherState.maxItems) })
        for session in sessions where (session.switcherSnapshot != nil || session.switcherCaptureInFlight != nil) && !keep.contains(session.itemID) {
            session.switcherSnapshot = nil
        }
    }

    /// This window's tabs in the space it shows, most recently chosen first, still open ones only.
    public func recentItems(in window: BrowserWindowState) -> [UUID] {
        guard let spaceID = window.spaceID else { return [] }
        let source = tree(owner(of: window))
        return (window.recentItemsBySpace[spaceID] ?? []).reversed().filter { source.item($0) != nil }
    }

    public func selectNext(in window: BrowserWindowState) {
        step(1, in: window)
    }

    public func selectPrevious(in window: BrowserWindowState) {
        step(-1, in: window)
    }

    private func step(_ offset: Int, in window: BrowserWindowState) {
        let order = displayOrder(in: window)
        guard !order.isEmpty else { return }
        let current = window.selectedItemID.flatMap { order.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + order.count) % order.count
        select(order[next], in: window)
    }

    /// 0-based over `displayOrder(in:)`.
    public func select(index: Int, in window: BrowserWindowState) {
        let order = displayOrder(in: window)
        guard order.indices.contains(index) else { return }
        select(order[index], in: window)
    }

    public func selectLast(in window: BrowserWindowState) {
        guard let last = displayOrder(in: window).last else { return }
        select(last, in: window)
    }

    /// Shows a space; its remembered selection (or first item) becomes selected. The space owns
    /// its login context, so this is also the data store, history and cookie switch.
    public func setSpace(_ spaceID: UUID, in window: BrowserWindowState) {
        let source = tree(owner(of: window))
        guard source.space(spaceID) != nil else { return }
        if profileEngine == .chromium {
            let order = displayOrder(inSpace: spaceID)
            if !window.isIncognito, let host = nativePageHost as? any NativeSpaceSwitchHost {
                let remembered = window.selectedItemBySpace[spaceID].flatMap { order.contains($0) ? $0 : nil }
                let destination = remembered ?? (window.emptiedSpaces.contains(spaceID) ? nil : order.first)
                switchNativeSpace(spaceID, itemID: destination, in: window, through: host)
                return
            }
            if let remembered = window.selectedItemBySpace[spaceID], order.contains(remembered) {
                select(remembered, in: window, leaving: selectedSession(in: window), showingAgentSpace: true)
            } else if !window.emptiedSpaces.contains(spaceID), let first = order.first {
                select(first, in: window, leaving: selectedSession(in: window), showingAgentSpace: true)
            } else {
                window.nativeSelectionGeneration = nil
                window.nativeSelectionSession?.cancelNativePreparation(in: window)
                window.nativeSelectionSession = nil
                window.nativeEmptySpaceID = spaceID
                let changed = window.spaceID != spaceID
                window.spaceID = spaceID
                window.selectedItemBySpace[spaceID] = nil
                if changed { sessionDelegate?.windowSpaceChanged(window) }
                mirror(window)
                window.refreshCompositor()
            }
            return
        }
        let previous = selectedSession(in: window)
        let changed = window.spaceID != spaceID
        window.spaceID = spaceID
        if changed { sessionDelegate?.windowSpaceChanged(window) }
        let order = displayOrder(in: window)
        if let remembered = window.selectedItemBySpace[spaceID], order.contains(remembered) {
            select(remembered, in: window, leaving: previous)
        } else if !window.emptiedSpaces.contains(spaceID), let first = order.first {
            select(first, in: window, leaving: previous)
        } else {
            window.selectedItemBySpace[spaceID] = nil
            mirror(window)
            window.refreshCompositor()
        }
    }

    private func canSelect(_ profile: Profile, forSpace spaceID: UUID, in window: BrowserWindowState) -> Bool {
        nativeProfile(profile.id, matches: spaceID, in: window) &&
            (window.isIncognito ? window.ephemeralProfile === profile : isProfileAvailable(profile.id))
    }

    private func switchNativeSpace(_ spaceID: UUID, itemID: UUID?, in window: BrowserWindowState,
                                   through host: any NativeSpaceSwitchHost) {
        guard !isTerminating, windowRegistry.windows[window.id] === window,
              let profile = window.isIncognito ? window.ephemeralProfile : profile(forSpace: spaceID),
              canSelect(profile, forSpace: spaceID, in: window) else { return }
        let generation = UUID()
        window.nativeSpaceSwitch = (generation, spaceID)
        guard cancelNativeSplit(in: window), window.nativeSpaceSwitch?.generation == generation,
              windowRegistry.windows[window.id] === window else { return }
        let previous = window.nativeSelectionSession
        window.nativeSelectionGeneration = generation
        window.nativeSelectionSession = nil

        let current = { [weak self, weak window, weak host] in
            guard let self, let window, let host else { return false }
            return window.nativeSelectionGeneration == generation && self.windowRegistry.windows[window.id] === window &&
                !self.isTerminating && self.nativePageHost === host
        }

        let settle = { [weak self, weak window, weak host] (outcome: NativeSpaceSwitchOutcome) in
            guard let self, let window, let host, current() else { return }
            @MainActor func publishEmpty(_ destination: UUID) {
                let changed = window.spaceID != destination
                window.nativeEmptySpaceID = destination
                guard current() else { return }
                window.selectedItemBySpace[destination] = nil
                guard current() else { return }
                if changed { window.spaceID = destination }
                guard current() else { return }
                if changed { self.sessionDelegate?.windowSpaceChanged(window) }
                guard current() else { return }
                self.mirror(window)
                window.refreshCompositor()
            }

            let source = self.tree(self.owner(of: window))
            var presented = false
            var selected: PageSession?
            var destination = spaceID
            var applied = false
            let finalSelection: NativeSpaceSwitchSelection?
            switch outcome {
            case .applied(let navigation):
                finalSelection = nil
                if self.canSelect(profile, forSpace: spaceID, in: window) {
                    applied = true
                    if let itemID, let navigation, let page = self.session(for: itemID), page.navigation === navigation,
                       self.selectionSpaceID(for: itemID, currentSpaceID: spaceID, in: source) == spaceID {
                        selected = page
                    } else if itemID == nil && navigation == nil {
                        publishEmpty(spaceID)
                        presented = true
                    }
                }
            case .superseded(let selection), .refused(retained: .some(let selection)):
                finalSelection = selection
            case .refused(retained: nil), .closed, .unresolved:
                finalSelection = nil
            }
            switch finalSelection {
            case .page(let navigation):
                if let previous = self.selectedSession(in: window), previous.navigation === navigation,
                   host.isNativeSelection(navigation, in: window) {
                    // A refusal can retain a favorite or pane in a space that
                    // differs from its home. Both IDs are already correct.
                    presented = true
                } else {
                    selected = self.sessions.first { $0.navigation === navigation }
                    if let page = selected, let space = self.selectionSpaceID(for: page.itemID,
                        currentSpaceID: window.spaceID, in: source) {
                        destination = space
                    } else { selected = nil }
                }
            case .empty(let profileID):
                let candidates = self.userSpaces(for: window).filter { self.nativeProfile(profileID, matches: $0.id, in: window) }
                if let empty = candidates.first(where: { $0.id == window.spaceID })?.id ??
                    (candidates.count == 1 ? candidates.first?.id : nil) {
                    if window.spaceID != empty || !window.showsNativeEmptySpace { publishEmpty(empty) }
                    presented = true
                }
            case nil:
                break
            }
            if let selected, let navigation = selected.navigation,
               self.nativeProfile(navigation.profileID, matches: destination, in: window),
               host.isNativeSelection(navigation, in: window), current() {
                self.select(selected.itemID, in: window, leaving: self.selectedSession(in: window),
                            nativeAdmitted: true, showingAgentSpace: true, adoptionGeneration: generation,
                            validateNative: { current() && host.isNativeSelection(navigation, in: window) },
                            preferredSpace: destination)
                presented = window.selectedItemID == selected.itemID && window.spaceID == destination &&
                    host.isNativeSelection(navigation, in: window)
            }
            guard current() else { return }
            if case .refused(retained: nil) = outcome {
                // Preparation or the bridge rejected this before selecting.
            } else {
                window.nativeSpaceSwitchIsUnresolved = !presented
            }
            guard current() else { return }
            window.nativeSpaceSwitch = nil
            window.nativeSelectionGeneration = nil
            window.nativeSelectionSession = nil
            if applied && presented, let selected, window.selectedItemID == selected.itemID {
                selected.resumeStagedNativeSearch()
                if window.nativeSelectionGeneration == nil && window.selectedItemID == selected.itemID {
                    self.restoreSavedNativeSplitIfNeeded(in: window)
                }
            }
            if window.nativeSelectionGeneration == nil {
                window.nativePresentationDidSettle?(presented)
            }
        }

        if previous?.itemID != itemID { previous?.cancelNativePreparation(in: window) }
        guard current() else { return }
        let submit = { [weak self, weak window, weak host] (page: (any PageNavigation)?) in
            guard let self, let window, let host, current() else { return }
            let source = self.tree(self.owner(of: window))
            guard self.canSelect(profile, forSpace: spaceID, in: window),
                  itemID.map({ self.selectionSpaceID(for: $0, currentSpaceID: spaceID, in: source) == spaceID }) ?? true else {
                settle(.refused(retained: nil)); return
            }
            if let leaving = self.selectedSession(in: window), leaving.navigation !== page {
                leaving.captureSwitcherSnapshot()
            }
            guard current() else { return }
            // Once submitted, the window owns the result even if its requested
            // page retires before the engine can report the final selection.
            window.nativeSelectionSession = nil
            host.switchSpace(to: profile, page: page, in: window, isCurrent: current, completion: settle)
        }
        guard let itemID else { submit(nil); return }
        guard let page = ensureSession(for: itemID), page.profile?.id == profile.id else {
            settle(.refused(retained: nil)); return
        }
        guard current() else { return }
        window.nativeSelectionSession = page
        page.ensureNativePage(in: window) { [weak self, weak page] prepared in
            guard let self, current() else { return }
            guard prepared, let page, self.session(for: itemID) === page,
                  page.profile?.id == profile.id, let navigation = page.navigation else {
                settle(.refused(retained: nil)); return
            }
            submit(navigation)
        }
    }

    /// False when there is no next space, the window being on the last one or the Agent space.
    @discardableResult
    public func selectNextSpace(in window: BrowserWindowState) -> Bool {
        stepSpace(1, in: window)
    }

    @discardableResult
    public func selectPreviousSpace(in window: BrowserWindowState) -> Bool {
        stepSpace(-1, in: window)
    }

    /// 0-based over the window's switchable spaces, the Agent space left out.
    public func selectSpace(at index: Int, in window: BrowserWindowState) {
        let spaces = userSpaces(for: window)
        guard spaces.indices.contains(index) else { return }
        setSpace(spaces[index].id, in: window)
    }

    /// The spaces a person switches between: the Agent space is reached only from its sidebar row.
    public func userSpaces(for window: BrowserWindowState) -> [SpaceRecord] {
        switchableSpaces(for: window).filter { !$0.isAgent }
    }

    private func stepSpace(_ offset: Int, in window: BrowserWindowState) -> Bool {
        let spaces = userSpaces(for: window)
        let pending = window.pendingNativeSpaceID.flatMap { id in spaces.firstIndex { $0.id == id } }
        guard let current = pending ?? spaces.firstIndex(where: { $0.id == window.spaceID }) else { return false }
        let next = current + offset
        guard spaces.indices.contains(next) else { return false }
        setSpace(spaces[next].id, in: window)
        return true
    }

    // MARK: - Close

    /// A bookmark (a pinned tab, a favorite, or a tab inside a folder) ends its page and keeps
    /// the item. A normal tab, and any folder, is removed into the reopen history.
    public func close(_ itemID: UUID) {
        close(itemID, returningTo: nil)
    }

    private func close(_ itemID: UUID, returningTo opener: ((BrowserWindowState) -> UUID?)?) {
        guard !profileChangeLocksItem(itemID) else { return }
        guard let owner = owner(ofItem: itemID) else { return }
        let source = tree(owner)
        guard let item = source.item(itemID) else { return }
        let expectedSubtree = Set(source.subtree(of: itemID))
        let closingIDs = item.isFolder ? Array(expectedSubtree) : [itemID]
        if releaseNativePagesBeforeMutation(closingIDs, preferredSuccessor: opener, then: { [weak self] in
            guard let self, Set(self.tree(owner).subtree(of: itemID)) == expectedSubtree else { return }
            self.close(itemID, returningTo: opener)
        }) { return }
        if source.keepsItemOnClose(itemID) {
            // The page it showed, so Reopen Closed Tab can bring it back in place.
            var page = pendingSearchPage(for: itemID)
                ?? session(for: itemID).map { OpenPage(url: $0.storableURL, title: $0.title) }
            if page == nil, case .main = owner { page = device.openPages[itemID] }
            moveSelectionOff([itemID], preferredSuccessor: opener)
            endSession(itemID)
            if let page, let section = source.section(of: itemID) {
                let entry = ClosedEntry(items: [item], section: section, closedAt: Date(), endedPage: page)
                switch owner {
                case .main:
                    recordClosed(entry)
                case .privateWindow(let window):
                    window.privateClosed.append(entry)
                    if window.privateClosed.count > DeviceState.closedLimit { window.privateClosed.removeFirst() }
                }
            }
            save()
            return
        }
        // A tab with a trail closes alone; its children move up into its place.
        remove(itemID, promotingChildren: !item.isFolder, preferredSuccessor: opener)
    }

    /// Deletes an item and its subtree from the sidebar, pinned tabs and favorites included.
    /// Pages end; reopening the closed entry puts it back in its place.
    public func remove(_ itemID: UUID) {
        remove(itemID, promotingChildren: false)
    }

    /// `archiving` files the closed entry with the archive sweep's, apart from the person's closes.
    func remove(_ itemID: UUID, promotingChildren: Bool, archiving: Bool = false,
                preferredSuccessor: ((BrowserWindowState) -> UUID?)? = nil) {
        guard let owner = owner(ofItem: itemID) else { return }
        let ids = promotingChildren ? [itemID] : tree(owner).subtree(of: itemID)
        if releaseNativePagesBeforeMutation(ids, preferredSuccessor: preferredSuccessor, then: { [weak self] in
            guard let self else { return }
            let current = promotingChildren ? [itemID] : self.tree(owner).subtree(of: itemID)
            guard Set(current) == Set(ids) else { return }
            self.remove(itemID, promotingChildren: promotingChildren, archiving: archiving,
                        preferredSuccessor: preferredSuccessor)
        }) { return }
        if let item = tree(owner).item(itemID) { dismissFromLiveFolder(item) }
        moveSelectionOff(Set(ids), preferredSuccessor: preferredSuccessor)
        let pendingPages = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            pendingSearchPage(for: id).map { (id, $0) }
        })
        var closedEntry: ClosedEntry?
        let change = perform(owner, "remove") { tree in
            let result = try tree.close(itemID, promotingChildren: promotingChildren)
            closedEntry = result.closed
            return result.change
        }
        guard change != nil, var closedEntry else { return }
        closedEntry.pendingPages = pendingPages.isEmpty ? nil : pendingPages
        for id in ids { endSession(id) }
        switch owner {
        case .main:
            recordClosed(closedEntry, archived: archiving)
        case .privateWindow(let window):
            window.privateClosed.append(closedEntry)
            if window.privateClosed.count > DeviceState.closedLimit { window.privateClosed.removeFirst() }
        }
    }

    public func close(_ itemIDs: [UUID]) {
        guard !itemIDs.contains(where: profileChangeLocksItem) else { return }
        for id in itemIDs { close(id) }
    }

    public func closeSelected(in window: BrowserWindowState) {
        guard let selected = window.selectedItemID else { return }
        close(selected)
    }

    /// The tab whose page opened `itemID`, which Back returns to once the page has no history:
    /// its trail parent, else the recorded opener of a link tab placed as a sibling.
    public func opener(of itemID: UUID) -> UUID? {
        guard let owner = owner(ofItem: itemID) else { return nil }
        return tree(owner).opener(of: itemID, recorded: openers(owner))
    }

    /// Back with no page left: shows the tab that opened `itemID` and closes it, as Safari and
    /// Zen do. Reopen Closed Tab brings it back.
    public func returnToOpener(_ itemID: UUID, in window: BrowserWindowState) {
        guard let opener = opener(of: itemID) else { return }
        guard profileEngine == .chromium else {
            select(opener, in: window)
            close(itemID)
            return
        }
        // On the SDK, Back can ask the current document to leave. Keep its pane
        // active through that question, with the opener only a close successor.
        guard window.selectedItemID == itemID, let space = window.spaceID,
              windowRegistry.windows[window.id] === window,
              pageOwnerWindow(of: itemID) === window,
              window.nativeSelectionGeneration == nil else { return }
        close(itemID, returningTo: { [weak self, weak window] candidate in
            guard let self, let window, candidate === window,
                  self.windowRegistry.windows[window.id] === window,
                  window.spaceID == space, window.selectedItemID == itemID,
                  self.pageOwnerWindow(of: itemID) === window, window.nativeSelectionGeneration == nil,
                  self.opener(of: itemID) == opener,
                  self.canUseCloseSuccessor(opener, in: window) else { return nil }
            return opener
        })
    }

    /// Restores the newest closed entry and selects it. A private window reopens from its own
    /// in-memory history.
    public func reopenLastClosed(in window: BrowserWindowState) {
        let owner = owner(of: window)
        let isPrivate = window.privateTree != nil
        guard let entry = isPrivate ? window.privateClosed.last : device.newestClosed,
              let fallbackSpace = window.spaceID ?? tree(owner).orderedSpaces.first?.id else { return }
        // A pinned tab or favorite whose page was closed: reopen that page on the same item.
        if let page = entry.endedPage, let root = entry.items.first, tree(owner).item(root.id) != nil {
            if isPrivate {
                window.privateClosed.removeLast()
            } else {
                dropLastClosed()
                // A tab in a Tabs-section folder keeps its page as its own URL.
                if tree.scope(of: root.id) == .synced || page.pendingSearch != nil { setOpenPage(root.id, page) }
            }
            if let query = page.pendingSearch {
                ensureSession(for: root.id)?.stageNativeSearch(query, persist: false)
            }
            select(root.id, in: window)
            save()
            return
        }
        guard perform(owner, "reopen", { try $0.reopen(entry, fallback: .tabs(spaceID: fallbackSpace)) }) != nil else { return }
        if isPrivate {
            window.privateClosed.removeLast()
        } else {
            dropLastClosed()
        }
        let restored = entry.items.map(\.id)
        for (id, page) in entry.pendingPages ?? [:] where restored.contains(id) {
            if isPrivate {
                if let query = page.pendingSearch { ensureSession(for: id)?.stageNativeSearch(query, persist: false) }
            } else if page.pendingSearch != nil { setOpenPage(id, page) }
        }
        // Older entries for the same items (a page close, then a delete) must not restore them twice.
        if !isPrivate { dropClosed(containing: Set(restored)) }
        for host in entry.items where host.isFolder || entry.items.contains(where: { $0.parent == .folder(itemID: host.id) }) {
            openFolder(host.id)
        }
        if let firstTab = restored.first(where: { tree(owner).item($0)?.isFolder == false }) {
            select(firstTab, in: window)
        }
    }

    static let recentLimit = 30

    /// Before items disappear (or a pinned tab's page ends), every window selecting one returns
    /// to the item it selected before, else the next item in display order, else the previous.
    private func moveSelectionOff(_ ids: Set<UUID>,
                                  preferredSuccessor: ((BrowserWindowState) -> UUID?)? = nil) {
        for window in allWindows {
            for space in window.recentItemsBySpace.keys {
                window.recentItemsBySpace[space]?.removeAll { ids.contains($0) }
            }
            let preferred = preferredSuccessor?(window)
            // An ordinary selection may still be preparing while Back's close completes.
            let keepPendingSelection = preferredSuccessor != nil && window.nativeSelectionGeneration != nil
                && window.nativeSelectionSession.map { !ids.contains($0.itemID) } == true
            if let split = window.split, split.itemIDs.contains(where: ids.contains) {
                window.split = split.itemIDs.filter(ids.contains).reduce(split) { $0?.removing($1) }
                // A pane's tab going while the split shows: a neighbouring pane takes the selection.
                let openerPane = preferred.flatMap { split.contains($0) ? $0 : nil }
                if !keepPendingSelection, let selected = window.selectedItemID, ids.contains(selected),
                   let index = split.itemIDs.firstIndex(of: selected), let next = openerPane ?? (split.itemIDs[(index + 1)...] + split.itemIDs[..<index].reversed()).first(where: {
                       !ids.contains($0) && canUseCloseSuccessor($0, in: window, previouslyShownIn: split)
                   }) {
                    select(next, in: window)
                    for (space, item) in window.selectedItemBySpace where ids.contains(item) {
                        window.selectedItemBySpace[space] = nil
                    }
                    continue
                }
                if let selected = window.selectedItemID, !ids.contains(selected) {
                    mirror(window)
                    window.refreshCompositor()
                }
            }
            guard let selected = window.selectedItemID, ids.contains(selected), let spaceID = window.spaceID else {
                for (space, item) in window.selectedItemBySpace where ids.contains(item) {
                    window.selectedItemBySpace[space] = nil
                }
                continue
            }
            let next = preferred ?? successor(in: window, leaving: ids)
            for (space, item) in window.selectedItemBySpace where ids.contains(item) {
                window.selectedItemBySpace[space] = nil
            }
            if keepPendingSelection {
                mirror(window)
                window.refreshCompositor()
            } else if let next {
                select(next, in: window)
            } else {
                window.selectedItemBySpace[spaceID] = nil
                window.emptiedSpaces.insert(spaceID)
                if profileEngine == .chromium { window.nativeEmptySpaceID = spaceID }
                mirror(window)
                window.refreshCompositor()
            }
        }
    }

    func canUseCloseSuccessor(_ itemID: UUID, in window: BrowserWindowState,
                              previouslyShownIn split: SplitRecord? = nil) -> Bool {
        guard profileEngine == .chromium else { return true }
        let source = tree(owner(of: window))
        guard let space = window.spaceID,
              let destination = selectionSpaceID(for: itemID, currentSpaceID: space, in: source),
              destination == space || split?.contains(itemID) == true,
              !isPageShownElsewhere(itemID, from: window) else { return false }
        return !hasOtherNativePageOwner(itemID, than: window)
    }

    /// The tab a window shows when its selected one goes: its most recent open tab in the
    /// space, else the next in display order, else the previous.
    func successor(in window: BrowserWindowState, leaving ids: Set<UUID>) -> UUID? {
        guard let selected = window.selectedItemID, let spaceID = window.spaceID else { return nil }
        let order = displayOrder(in: window)
        let index = order.firstIndex(of: selected) ?? 0
        // Recent items stay eligible inside collapsed folders; ones moved to another space do not.
        let source = tree(owner(of: window))
        // Only open tabs qualify: every tab in the tabs section, and pinned tabs or favorites
        // whose page is still open. With none left the window shows the empty space.
        let isOpen: (UUID) -> Bool = { id in
            // A reopened page is recorded before its session exists.
            !source.isBookmark(id) || self.session(for: id) != nil || self.device.openPages[id] != nil
        }
        let recent = (window.recentItemsBySpace[spaceID] ?? []).reversed().filter { id in
            guard !ids.contains(id), let item = source.item(id), !item.isFolder, isOpen(id) else { return false }
            return source.spaceID(of: id) == spaceID
        }
        let candidates = recent
            + order.dropFirst(index + 1).filter { !ids.contains($0) && isOpen($0) }
            + order.prefix(index).reversed().filter { !ids.contains($0) && isOpen($0) }
        return candidates.first { canUseCloseSuccessor($0, in: window) }
    }

    // MARK: - Move

    public func move(_ itemID: UUID, to parent: Parent, after: UUID?) {
        guard let owner = owner(ofItem: itemID) else { return }
        // A tab leaving its space leaves every window showing it there on another tab of that space.
        let source = tree(owner)
        let newSpace: UUID? = {
            if case .folder(let hostID) = parent { return source.spaceID(of: hostID) }
            return parent.spaceID
        }()
        if case .main = owner, let newSpace, let profile = source.dataStoreID(for: newSpace),
           releaseNativePages(of: itemID, leavingFor: profile, then: { [weak self] in
               self?.move(itemID, to: parent, after: after)
           }) { return }
        if let oldSpace = source.spaceID(of: itemID), let newSpace, oldSpace != newSpace {
            moveSelectionOff(Set(source.subtree(of: itemID)))
        }
        let current = session(for: itemID)
        let wasSynced = tree(owner).scope(of: itemID) == .synced
        let currentURL = current?.storableURL ?? (wasSynced ? device.openPages[itemID]?.url : nil)
        // Extensions see the move against the window list the tab was in.
        // ponytail: only the moved item is reported, not tabs inside a moved folder.
        let oldWindow = webKitTabEvents == nil ? nil : regularWindows.first { displayOrder(in: $0).contains(itemID) }
        let oldIndex = oldWindow.flatMap { displayOrder(in: $0).firstIndex(of: itemID) }
        let before = tree(owner).item(itemID)
        guard perform(owner, "move", { try $0.move(itemID, to: parent, after: after, currentURL: currentURL) }) != nil else { return }
        if let before, before.parent != parent { dismissFromLiveFolder(before) }
        guard case .main = owner else { return }
        let isSynced = tree.scope(of: itemID) == .synced
        if current != nil {
            webKitTabEvents?.tabMoved(itemID: itemID, from: oldIndex, in: oldWindow, pinnedChanged: wasSynced != isSynced)
        }
        if wasSynced, !isSynced {
            for id in tree.subtree(of: itemID) where device.openPages[id]?.pendingSearch == nil { setOpenPage(id, nil) }
        } else if !wasSynced, isSynced {
            for id in tree.subtree(of: itemID) {
                guard let page = session(for: id), tree.item(id)?.isFolder == false else { continue }
                setOpenPage(id, pendingSearchPage(for: id) ?? OpenPage(url: page.storableURL, title: page.title))
            }
            if case .pinned = tree.section(of: itemID) {
                onTabsPinned?(tree.subtree(of: itemID).filter { tree.item($0)?.isFolder == false })
            }
        }
        unloadPagesOnWrongDataStore(tree.subtree(of: itemID))
        for window in regularWindows { window.refreshCompositor() }
    }

    public func drop(_ itemID: UUID, section: Parent, rows: [Row], index: Int, intoFolder: Bool) {
        let source = treeHolding(section)
        let target = source.dropTarget(section: section, rows: rows, index: index, intoFolder: intoFolder, dragged: itemID)
        if case .folder(let folderID) = target.parent { openFolder(folderID) }
        move(itemID, to: target.parent, after: target.after)
    }

    /// Appends to a pinned section (`.pinned`) or favorites (`.favorites`).
    public func pin(_ itemID: UUID, to parent: Parent) {
        move(itemID, to: parent, after: children(of: parent).last?.id)
    }

    /// Cmd+D: a normal tab becomes a bookmark at the end of Pinned; a bookmark (pinned, a
    /// favorite or inside a folder) becomes a normal tab at the top of Tabs. A shared favorite
    /// goes to the Tabs of the window's space.
    public func toggleBookmark(_ itemID: UUID, in window: BrowserWindowState? = nil) {
        guard let owner = owner(ofItem: itemID),
              let target = tree(owner).bookmarkTogglePosition(of: itemID) else { return }
        if case .tabs = target.0, let spaceID = sharedFavoriteSpace(of: itemID, in: window) {
            move(itemID, to: .tabs(spaceID: spaceID), after: nil)
            return
        }
        move(itemID, to: target.0, after: target.1)
    }

    /// The window's space when `itemID` is a favorite stored under another space it shares with.
    private func sharedFavoriteSpace(of itemID: UUID, in window: BrowserWindowState?) -> UUID? {
        guard let window, let current = window.spaceID, let owner = owner(ofItem: itemID) else { return nil }
        let source = tree(owner)
        guard case .favorites(let home) = source.section(of: itemID), home != current,
              source.sharesFavorites(home, current) else { return nil }
        return current
    }

    /// A tab the person chose to keep: pinned, a favorite, or inside a folder.
    public func isBookmark(_ itemID: UUID) -> Bool {
        owner(ofItem: itemID).map { tree($0).isBookmark(itemID) } ?? false
    }

    /// Moves a pinned tab or favorite to the top of its space's tabs section; a shared favorite
    /// to the top of the tabs of `window`'s space.
    public func unpin(_ itemID: UUID, in window: BrowserWindowState? = nil) {
        let spaceID = sharedFavoriteSpace(of: itemID, in: window)
            ?? self.spaceID(of: itemID)
            ?? allWindows.first(where: { $0.selectedItemID == itemID })?.spaceID
        guard let spaceID else { return }
        move(itemID, to: .tabs(spaceID: spaceID), after: nil)
    }

    public func rename(_ itemID: UUID, _ customTitle: String?) {
        guard let owner = owner(ofItem: itemID) else { return }
        perform(owner, "rename") { try $0.rename(itemID, customTitle: customTitle) }
    }

    /// A copy of a tab showing its current page, right after it under the same parent: a pinned
    /// tab's copy is pinned, a copy in a folder stays in it. The copy is selected.
    @discardableResult
    public func duplicate(_ itemID: UUID, in window: BrowserWindowState) -> UUID? {
        guard let owner = owner(ofItem: itemID), let item = tree(owner).item(itemID),
              case .tab(let url, let pageTitle) = item.kind else { return nil }
        let page = session(for: itemID)
        let id = UUID()
        guard perform(owner, "duplicate", {
            try $0.duplicate(itemID, as: id, url: page?.storableURL ?? url, title: page?.title ?? pageTitle)
        }) != nil else { return nil }
        select(id, in: window)
        return id
    }

    // MARK: - Home URL

    /// Loads a synced tab's home URL in its page.
    public func resetToHome(_ itemID: UUID) {
        guard let item = item(itemID), let home = item.url, let owner = owner(ofItem: itemID),
              tree(owner).scope(of: itemID) == .synced else { return }
        if let page = session(for: itemID) {
            page.load(home)
        } else if case .main = owner {
            setOpenPage(itemID, nil)
        }
    }

    /// Makes a synced tab's current page its home URL.
    public func setHomeToCurrent(_ itemID: UUID) {
        guard let current = session(for: itemID)?.storableURL ?? device.openPages[itemID]?.url else { return }
        setHome(itemID, url: current)
    }

    public func setHome(_ itemID: UUID, url: URL) {
        guard let owner = owner(ofItem: itemID) else { return }
        perform(owner, "setHome") { try $0.setURL(itemID, url) }
    }

    // MARK: - Folders

    @discardableResult
    public func createFolder(title: String, in parent: Parent, after: UUID?) -> UUID? {
        let owner: TabsController.Owner?
        switch parent {
        case .favorites(let spaceID), .pinned(let spaceID), .tabs(let spaceID): owner = self.owner(ofSpace: spaceID)
        case .folder(let folderID): owner = self.owner(ofItem: folderID)
        }
        guard let owner else { return nil }
        let id = UUID()
        guard perform(owner, "createFolder", { try $0.createFolder(id: id, title: title, in: parent, after: after) }) != nil else {
            return nil
        }
        openFolder(id)
        return id
    }

    public func toggleFolder(_ folderID: UUID) {
        if isOpen(folder: folderID) {
            setFolder(folderID, open: false)
        } else {
            setFolder(folderID, open: true)
        }
    }

    public func setAllFolders(open: Bool, space spaceID: UUID) {
        guard let owner = owner(ofSpace: spaceID) else { return }
        let source = tree(owner)
        let roots = source.children(of: .pinned(spaceID: spaceID)) + source.children(of: .tabs(spaceID: spaceID))
        for root in roots {
            for id in source.subtree(of: root.id) where source.item(id)?.isFolder == true || source.hasChildren(id) {
                setFolder(id, open: open)
            }
        }
    }

    public func openFolder(_ folderID: UUID) {
        setFolder(folderID, open: true)
    }

    /// Shows an item in the sidebar: its space, every folder above it (and it, when a folder)
    /// open, and the sidebar scrolled to it.
    public func reveal(_ itemID: UUID, in window: BrowserWindowState) {
        let source = tree(owner(of: window))
        guard let item = source.item(itemID) else { return }
        if let spaceID = source.spaceID(of: itemID), spaceID != window.spaceID { setSpace(spaceID, in: window) }
        var parent = item.parent
        while case .folder(let hostID) = parent, let host = source.item(hostID) {
            openFolder(hostID)
            parent = host.parent
        }
        if item.isFolder { openFolder(itemID) }
        window.sidebarRevealItemID = itemID
    }

    // MARK: - Spaces

    /// A new space in a new profile with an empty website data store, so it starts logged out.
    /// `sharingLoginsWith` puts it in that space's profile instead.
    @discardableResult
    public func createSpace(name: String, icon: String, accentHex: String, after: UUID?, sharingLoginsWith: UUID? = nil, profileName: String? = nil) -> UUID? {
        let id = UUID()
        let store = sharingLoginsWith.flatMap { tree.dataStoreID(for: $0) }
        guard perform(.main, "createSpace", {
            $0.createSpace(id: id, name: name, icon: icon, accentHex: accentHex, after: after, dataStoreID: store,
                           profileName: store == nil ? profileName : nil)
        }) != nil else { return nil }
        return id
    }

    /// The Agent space keeps its name and look, so it never passes for an ordinary space.
    public func updateSpace(_ spaceID: UUID, name: String?, icon: String?, accentHex: String?) {
        guard let owner = owner(ofSpace: spaceID), spaceID != agentSpaceID else { return }
        perform(owner, "updateSpace") { try $0.updateSpace(spaceID, name: name, icon: icon, accentHex: accentHex) }
    }

    /// The engine id a space searches with: its profile's choice, else the app's default. The
    /// Agent space searches like the profile it borrows logins from.
    public func searchEngineId(forSpace spaceID: UUID?) -> String {
        let store = spaceID.flatMap { tree.dataStoreID(for: $0) }
        return tree.profiles.first { $0.id == store }?.searchEngineId ?? settings.searchEngineId
    }

    /// The query template searches from a space use.
    public func searchTemplate(forSpace spaceID: UUID?) -> String {
        settings.searchTemplate(for: searchEngineId(forSpace: spaceID))
    }

    /// Not undoable: the editor writes on every drag step, and each would be an undo entry.
    public func setTheme(_ theme: SpaceTheme, forSpace spaceID: UUID) {
        guard let owner = owner(ofSpace: spaceID), spaceID != agentSpaceID else { return }
        perform(owner, "setTheme", undoable: false) { try $0.setTheme(spaceID, theme: theme) }
    }

    func moveSpace(_ spaceID: UUID, after: UUID?) {
        guard let owner = owner(ofSpace: spaceID) else { return }
        perform(owner, "moveSpace") { try $0.moveSpace(spaceID, after: after) }
    }

    /// A saved space other than the Agent space; private windows' spaces are never saved.
    public func canExportSpace(_ spaceID: UUID) -> Bool {
        tree.space(spaceID).map { !$0.isAgent } ?? false
    }

    /// The space as a `.nookspace` file holds it; nil when `canExportSpace` is false.
    public func spaceFile(_ spaceID: UUID, appVersion: String) -> SpaceFile? {
        tree.spaceSnapshot(spaceID).map { SpaceFile(space: $0, appVersion: appVersion) }
    }

    /// Adds a file's space as a new last space in the profile whose store is `storeID`. Its tabs
    /// stay unloaded and no window's selection changes.
    public func importSpace(_ file: SpaceFile, intoProfile storeID: UUID) -> SpaceImportReport? {
        var report: SpaceImportReport?
        let kept = device.keptProfiles ?? []
        guard perform(.main, "importSpace", { tree in
            let result = try tree.importSpace(file.space, intoProfile: storeID, kept: kept)
            report = result.report
            return result.change
        }) != nil else { return nil }
        return report
    }

    // MARK: - Profiles

    /// The profiles of the spaces, then the kept ones no space uses.
    public var profiles: [ProfileSummary] { tree.profiles(keeping: device.keptProfiles ?? []) }

    /// The profile moving `spaceID` to `storeID` leaves with no space, which the person keeps or deletes.
    public func profileLeftEmpty(byMoving spaceID: UUID, to storeID: UUID?) -> ProfileSummary? {
        tree.profileLeftEmpty(byMoving: spaceID, to: storeID)
    }

    /// Moves a space into the profile with store `storeID`, or a new one when nil. Its pages
    /// reload on the new store. The profile it leaves, once no space uses it, is kept with its
    /// website data and history when `keepingLeftProfile`, else deleted with them.
    public func setProfile(_ spaceID: UUID, to storeID: UUID?, name: String? = nil, keepingLeftProfile: Bool = false,
                           completion: (@MainActor (Result<Void, ProfileDeletionError>) -> Void)? = nil) {
        if profileEngine == .chromium {
            reassignNativeSpace(spaceID, destination: storeID, name: name, keepSource: keepingLeftProfile,
                                completion: completion ?? { _ in })
            return
        }
        let kept = device.keptProfiles ?? []
        guard case .main? = owner(ofSpace: spaceID), let old = profile(forSpace: spaceID),
              let left = tree.profile(ofSpace: spaceID),
              perform(.main, "setProfile", { try $0.setProfile(spaceID, to: storeID, name: name, kept: kept) }) != nil
        else { completion?(.failure(.unavailable)); return }
        unloadPagesOnWrongDataStore(items(inSpace: spaceID).map(\.id))
        if let agent = agentSpaceID { unloadPagesOnWrongDataStore(items(inSpace: agent).map(\.id)) }
        for window in regularWindows where window.spaceID == spaceID { sessionDelegate?.windowSpaceChanged(window) }
        if !tree.orderedSpaces.contains(where: { tree.dataStoreID(for: $0.id) == old.id }) {
            if keepingLeftProfile {
                keepProfile(left)
            } else {
                forgetProfile(old.id)
                Task { await clearDeletedWebKitProfileData(of: old) }
            }
        }
        completion?(.success(()))
    }

    /// Deletes a kept profile with its logins, cookies and history.
    public func deleteKeptProfile(_ storeID: UUID) {
        // Do not remove the identity/history while native website data remains.
        guard profileEngine == .webKit else { return }
        guard device.keptProfiles?.contains(where: { $0.id == storeID }) == true,
              let store = profile(forStore: storeID) else { return }
        forgetProfile(storeID)
        Task { await clearDeletedWebKitProfileData(of: store) }
    }

    private func clearDeletedWebKitProfileData(of profile: Profile) async {
        guard let storage = profile.webKitStorage else { return }
        await storage.clearDeletedProfileData()
        await translationCaches.erase(profile: profile.id)
    }

    public func renameProfile(_ storeID: UUID, to name: String) {
        if updateKeptProfile(storeID, { $0.name = name }) { return }
        perform(.main, "renameProfile") { try $0.renameProfile(storeID, to: name) }
    }

    /// The engine the profile's spaces search with; nil follows the app's default.
    public func setSearchEngine(_ engineId: String?, forProfile storeID: UUID) {
        if updateKeptProfile(storeID, { $0.searchEngineId = engineId }) { return }
        perform(.main, "setSearchEngine") { try $0.setSearchEngine(profile: storeID, engineId: engineId) }
    }

    /// A native page cannot change profile: it closes, then the move runs, and it loads in the
    /// new profile when next selected. A close the page refuses leaves the tab where it was.
    private func releaseNativePages(of itemID: UUID, leavingFor profile: UUID,
                                    then move: @escaping @MainActor () -> Void) -> Bool {
        guard profileEngine == .chromium, !profileChangeLocksItem(itemID) else { return false }
        let leaving = tree.subtree(of: itemID).filter { session(for: $0)?.profile?.id != profile }
        return releaseNativePagesBeforeMutation(leaving) { [weak self] in
            guard let self else { return }
            for id in leaving { self.session(for: id)?.unload() }
            move()
        }
    }

    /// Pages whose item now belongs to another space reload on that space's data store.
    private func unloadPagesOnWrongDataStore(_ ids: [UUID]) {
        for id in ids {
            guard let page = session(for: id), let view = page.primaryWebView, let dataStore = page.profile?.webKitStorage?.dataStore,
                  view.configuration.websiteDataStore !== dataStore else { continue }
            unload(id)
        }
    }

    /// Deletes a space; its items go to the reopen history and its website data is cleared
    /// unless another space shares it, or kept in Profiles with `keepingLeftProfile`. Chromium
    /// keeps the profile of a last space, as Arc does. Windows showing it move to another space.
    public func deleteSpace(_ spaceID: UUID, keepingLeftProfile: Bool = false) {
        deleteSpace(spaceID, keepingLeftProfile: keepingLeftProfile, admitsLiveClose: true)
    }

    private func deleteSpace(_ spaceID: UUID, keepingLeftProfile: Bool, admitsLiveClose: Bool) {
        guard let owner = owner(ofSpace: spaceID) else { return }
        if case .main = owner, profileEngine == .chromium, let refusal = nativeSpaceDeletionRefusal(spaceID) {
            onSpaceDeletionNotice?(refusal)
            return
        }
        if profileEngine == .chromium {
            let source = tree(owner)
            let keepsFavorites = source.favoriteSpaces(sharedWith: spaceID).contains { $0 != spaceID }
            let closing = ((keepsFavorites ? [] : source.children(of: .favorites(spaceID: spaceID)))
                           + source.children(of: .pinned(spaceID: spaceID))
                           + source.children(of: .tabs(spaceID: spaceID)))
                .flatMap { source.subtree(of: $0.id) }
            if admitsLiveClose {
                if releaseNativePagesBeforeMutation(closing, then: { [weak self] in
                    self?.deleteSpace(spaceID, keepingLeftProfile: keepingLeftProfile)
                }) { return }
            } else if closing.contains(where: { session(for: $0)?.requiresNativeResourceRelease == true }) {
                return
            }
        }
        // Favorites other spaces still show move to one of them instead of closing.
        if let heir = tree(owner).favoriteSpaces(sharedWith: spaceID).first(where: { $0 != spaceID }) {
            for favorite in tree(owner).children(of: .favorites(spaceID: spaceID)) {
                move(favorite.id, to: .favorites(spaceID: heir), after: tree(owner).children(of: .favorites(spaceID: heir)).last?.id)
            }
        }
        let source = tree(owner)
        let ids = (source.children(of: .favorites(spaceID: spaceID))
                   + source.children(of: .pinned(spaceID: spaceID))
                   + source.children(of: .tabs(spaceID: spaceID)))
            .flatMap { source.subtree(of: $0.id) }
        // Read while the space still exists. The Agent space's data store is borrowed from the
        // person's space, so it is never cleared, and its tabs stay out of the reopen history.
        let isAgent = source.space(spaceID)?.isAgent == true
        let deleted = isAgent ? nil : profile(forSpace: spaceID)
        let left = source.profile(ofSpace: spaceID)
        var closed: [ClosedEntry] = []
        guard perform(owner, "deleteSpace", { tree in
            let result = try tree.deleteSpace(spaceID)
            closed = result.closed
            return result.change
        }) != nil else {
            onSpaceDeletionNotice?("This space couldn’t be deleted.")
            return
        }
        for id in ids { endSession(id) }
        if case .main = owner, !isAgent {
            for entry in closed { recordClosed(entry) }
        }
        let spaces = tree(owner).orderedSpaces
        let remaining = spaces.filter { !$0.isAgent } + spaces.filter(\.isAgent)
        for window in allWindows where window.spaceID == spaceID {
            window.selectedItemBySpace[spaceID] = nil
            if let next = remaining.first {
                window.spaceID = nil
                setSpace(next.id, in: window)
            }
        }
        if case .main = owner, let profile = deleted,
           !tree.orderedSpaces.contains(where: { tree.dataStoreID(for: $0.id) == profile.id }) {
            if keepingLeftProfile || profileEngine == .chromium, let left {
                keepProfile(left)
            } else {
                // Its cookies and logins go with it, since no other space uses this data store.
                forgetProfile(profile.id)
                Task { await clearDeletedWebKitProfileData(of: profile) }
            }
            // The Agent space may have borrowed its logins from this one.
            if let agent = agentSpaceID { unloadPagesOnWrongDataStore(items(inSpace: agent).map(\.id)) }
        }
    }

    /// The last space that is not the Agent space, which the tree never deletes.
    public func isLastRegularSpace(_ spaceID: UUID) -> Bool {
        guard let owner = owner(ofSpace: spaceID) else { return false }
        let source = tree(owner)
        return source.space(spaceID)?.isAgent == false && !source.orderedSpaces.contains { $0.id != spaceID && !$0.isAgent }
    }

    /// Why Chromium keeps a space, checked before any of its pages closes.
    private func nativeSpaceDeletionRefusal(_ spaceID: UUID) -> String? {
        if profileChangeHolds(spaceID) {
            return "This space can’t be deleted while its profile is changing. Finish or retry that in Settings > Profiles."
        }
        return isLastRegularSpace(spaceID) ? "You cannot delete the last remaining space." : nil
    }

    /// A pending profile change owns its spaces and its destination until it finishes.
    private func profileChangeHolds(_ spaceID: UUID) -> Bool {
        guard let pending = device.pendingProfileDeletion else { return false }
        if pending.change?.spaceIDs.contains(spaceID) == true { return true }
        guard let store = tree.dataStoreID(for: spaceID) else { return false }
        return (store == pending.survivor || store == pending.target)
            && tree.profile(ofSpace: spaceID)?.spaceIDs == [spaceID]
    }

    // MARK: - Unload

    /// Releases an item's web views; selection first moves off windows showing it.
    public func unload(_ itemID: UUID) {
        guard !profileChangeLocksItem(itemID) else { return }
        guard let page = session(for: itemID) else { return }
        if isVisibleInAnyWindow(itemID) { moveSelectionOff([itemID]) }
        page.unload()
    }

    /// Retention policy shared by automatic and bulk unloading.
    public func inactiveUnloadProtectionReason(for page: PageSession) -> InactiveUnloadProtection? {
        if isOnScreen(page.itemID) { return .visible }
        if page.hasPlayingAudio || page.hasAudioContent { return .audio }
        if page.hasPiPActive { return .pictureInPicture }
        if isInMiniPlayer(page.itemID) { return .miniPlayer }
        switch section(of: page.itemID) {
        case .pinned, .favorites: return .pinned
        default: break
        }
        // Chromium's current bridge does not establish capture, uploads or unsaved work.
        if profileEngine == .chromium { return .unknownNativeActivity }
        var views = webViews?.allWebViews(for: page.itemID) ?? []
        if let primary = page.primaryWebView { views.append(primary) }
        for view in views {
            if view.cameraCaptureState != .none { return .camera }
            if view.microphoneCaptureState != .none { return .microphone }
        }
        return nil
    }

    @discardableResult
    public func unloadAllHidden() -> InactiveUnloadResult {
        var result = InactiveUnloadResult()
        for page in sessions where !page.isUnloaded {
            if let reason = inactiveUnloadProtectionReason(for: page) {
                result.retained[reason, default: 0] += 1
                continue
            }
            // The current policy only admits WebKit releases, which are synchronous.
            page.unload()
            if page.isUnloaded { result.unloaded += 1 }
            else { result.notReleased += 1 }
        }
        return result
    }

    // MARK: - External Undo

    /// Apply remote metadata only when no live Chromium resource would be
    /// closed or moved to another profile. A normal local close can unblock it.
    public func applyNativeSpaceSync(_ inbound: SpaceSyncInbound) -> Bool {
        guard profileEngine == .chromium, !isReadOnly, !isTerminating else { return false }
        if inbound.isEmpty { return persistSyncedTree() }
        var proposed = tree
        let changed = proposed.apply(inbound.change)
        guard profileDeletionAllows(proposed, changed: changed) else { return false }

        var deleting: [UUID] = []
        for id in inbound.deletedSpaces {
            guard proposed.space(id) != nil else { continue }
            // A remote deletion cannot remove this Mac's final regular space.
            guard proposed.orderedSpaces.contains(where: { $0.id != id && !$0.isAgent }) else { continue }
            guard !profileChangeHolds(id) else { return false }
            if let heir = proposed.favoriteSpaces(sharedWith: id).first(where: { $0 != id }) {
                do {
                    for favorite in proposed.children(of: .favorites(spaceID: id)) {
                        try proposed.move(favorite.id, to: .favorites(spaceID: heir),
                                          after: proposed.children(of: .favorites(spaceID: heir)).last?.id)
                    }
                } catch { return false }
            }
            do {
                let deletion = try proposed.deleteSpace(id)
                guard profileDeletionAllows(proposed, changed: deletion.change) else { return false }
            } catch { return false }
            deleting.append(id)
        }
        guard nativeEditIsAdmissible(proposed, owner: .main) else { return false }

        if !inbound.change.isEmpty {
            let departing = Set(tree.items.keys.filter {
                tree.item($0) != nil && tree.spaceID(of: $0) != proposed.spaceID(of: $0)
            })
            applyExternalChange(inbound.change, movingSelectionOff: departing)
            guard inbound.change.spaces.allSatisfy({ tree.spaces[$0.key] == $0.value }),
                  inbound.change.items.allSatisfy({ tree.items[$0.key] == $0.value }) else { return false }
        }
        for id in deleting { deleteSpace(id, keepingLeftProfile: true, admitsLiveClose: false) }
        guard deleting.allSatisfy({ tree.space($0) == nil }) else { return false }
        return persistSyncedTree()
    }

    /// Applies a change built elsewhere (the tab organizer's undo) to the main tree.
    public func apply(_ change: Change) {
        applyExternalChange(change)
    }

    private func applyExternalChange(_ change: Change, movingSelectionOff departing: Set<UUID> = []) {
        if profileEngine == .chromium {
            var proposed = tree
            let touched = proposed.apply(change)
            guard profileDeletionAllows(proposed, changed: touched) else { return }
            guard !nativeOwnershipChanged(by: touched, in: proposed) || nativeEditIsAdmissible(proposed, owner: .main) else { return }
        }
        let before = Set(tree.items.keys.filter { tree.item($0) != nil })
        moveSelectionOff(departing.union(change.items.compactMap { id, value in
            value == nil || value?.deletedAt != nil ? id : nil
        }))
        guard perform(.main, "apply", undoable: false, { tree in tree.apply(change) }) != nil else { return }
        for id in before where tree.item(id) == nil { endSession(id) }
        // Items the change brought back must not also reopen from the history.
        let restored = Set(change.items.keys.filter { !before.contains($0) && tree.item($0) != nil })
        dropClosed(containing: restored)
        for window in regularWindows { window.refreshCompositor() }
        save()
    }
}

/// Retention reasons, including an explicit boundary for engines without activity reporting.
public enum InactiveUnloadProtection: String, Hashable {
    case visible, audio, pictureInPicture, miniPlayer, camera, microphone, pinned, unknownNativeActivity
}

/// Counts of live tabs considered by a bulk action. Already unloaded tabs are absent.
public struct InactiveUnloadResult: Equatable {
    public fileprivate(set) var unloaded = 0
    public fileprivate(set) var retained: [InactiveUnloadProtection: Int] = [:]
    public fileprivate(set) var notReleased = 0

    public var kept: Int { retained.values.reduce(notReleased, +) }
}
