// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore

public enum NativeSplitOutcome: Equatable {
    case admitted, refused, superseded
}

/// One window-scoped asynchronous admission, never a second saved layout/model.
@MainActor
final class NativeSplitPreparation {
    let id = UUID()
    let record: SplitRecord?
    let previous: SplitRecord?
    let active: UUID?
    let selectedBefore: UUID?
    let spaceBefore: UUID?
    let ordered: [PageSession]
    let pages: [UUID: PageSession]
    let profiles: [UUID: UUID]
    let liveAdmission: (() -> Bool)?
    let livePages: [UUID: any PageNavigation]?
    weak var preparing: PageSession?
    let selectionAtActiveSpace: UUID?
    var publishingSelection = false
    var published = false
    var cancelled = false
    var completions: [@MainActor (Bool) -> Void]
    init(record: SplitRecord?, previous: SplitRecord?, active: UUID?, window: BrowserWindowState,
         ordered: [PageSession], pages: [UUID: PageSession], selectionAtActiveSpace: UUID?,
         liveAdmission: (() -> Bool)?, completion: (@MainActor (Bool) -> Void)?) {
        self.record = record; self.previous = previous; self.active = active
        selectedBefore = window.selectedItemID; spaceBefore = window.spaceID
        self.ordered = ordered; self.pages = pages
        self.selectionAtActiveSpace = selectionAtActiveSpace
        self.liveAdmission = liveAdmission
        livePages = liveAdmission.map { _ in Dictionary(uniqueKeysWithValues:
            ordered.compactMap { page in page.navigation.map { (page.itemID, $0) } }) }
        profiles = Dictionary(uniqueKeysWithValues: ordered.compactMap { page in page.profile.map { (page.itemID, $0.id) } })
        completions = completion.map { [$0] } ?? []
    }
    func complete(_ succeeded: Bool) {
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(succeeded) }
    }
}

extension TabsController {
    /// Queue exact profile-bound live split admission. True means accepted for
    /// preparation; completion reports native admission. Saved layout changes
    /// only after success. Existing pages are never reconstructed/reloaded.
    /// liveAdmission supplies a one-shot live remainder guard: no session or
    /// native page is created, and the exact existing navigations must survive.
    @discardableResult
    public func presentNativeSplit(_ record: SplitRecord?, activeItemID: UUID?,
                                   in window: BrowserWindowState,
                                   liveAdmission: (() -> Bool)? = nil,
                                   completion: (@MainActor (Bool) -> Void)? = nil) -> Bool {
        let entryGeneration = window.nativeSelectionGeneration
        let entrySelection = window.selectedItemID, entrySpace = window.spaceID
        let entrySplit = window.split
        guard !isTerminating, let host = nativePageHost,
              windowRegistry.windows[window.id] === window,
              liveAdmission?() ?? true,
              liveAdmission == nil || (window.nativeSelectionGeneration == entryGeneration &&
                  window.selectedItemID == entrySelection && window.spaceID == entrySpace && window.split == entrySplit),
              nativePageHost === host, windowRegistry.windows[window.id] === window else { completion?(false); return false }
        if let pending = window.nativeSplitPreparation, pending.record == record, pending.active == activeItemID,
           (pending.liveAdmission == nil) == (liveAdmission == nil) {
            // Catalog drains caused by page creation must not restart this work.
            if let completion { pending.completions.append(completion) }
            return true
        }
        guard cancelNativeSplit(in: window) else { completion?(false); return false }
        let previous = window.split, selected = window.selectedItemID, space = window.spaceID
        if record == nil, let activeItemID, activeItemID != selected,
           session(for: activeItemID)?.navigation == nil { completion?(false); return false }
        let beforeGeneration = window.nativeSelectionGeneration
        var ordered: [PageSession] = []
        if let record {
            guard let activeItemID, record.contains(activeItemID) else { completion?(false); return false }
            for id in record.itemIDs {
                guard holds(id, in: window), item(id)?.isFolder == false,
                      let page = liveAdmission == nil ? ensureSession(for: id) : session(for: id),
                      !page.nativeIsEnding, liveAdmission == nil || page.navigation != nil else { completion?(false); return false }
                ordered.append(page)
            }
            guard ordered.allSatisfy({ page in
                guard let profile = page.profile,
                      profile.isEphemeral == window.isIncognito,
                      !window.isIncognito || profile.id == window.ephemeralProfile?.id else { return false }
                return page.navigation == nil || page.navigation?.profileID == profile.id
            }) else { completion?(false); return false }
        }
        guard window.split == previous, window.selectedItemID == selected, window.spaceID == space,
              window.nativeSelectionGeneration == beforeGeneration,
              nativePageHost === host else { completion?(false); return false }
        var pages = Dictionary(uniqueKeysWithValues: ordered.map { ($0.itemID, $0) })
        for id in (previous?.itemIDs ?? []) + (activeItemID.map { [$0] } ?? []) + (selected.map { [$0] } ?? []) {
            if let page = session(for: id) { pages[id] = page }
        }
        let request = NativeSplitPreparation(record: record, previous: previous, active: activeItemID,
            window: window, ordered: ordered, pages: pages,
            selectionAtActiveSpace: activeItemID.flatMap { tree(owner(of: window)).spaceID(of: $0) }
                .flatMap { window.selectedItemBySpace[$0] }, liveAdmission: liveAdmission, completion: completion)
        // Resolving Profile metadata while capturing the request can publish
        // observable name/icon changes. Never overwrite a newer admission.
        guard window.split == previous, window.selectedItemID == selected, window.spaceID == space,
              window.nativeSelectionGeneration == beforeGeneration, nativePageHost === host,
              windowRegistry.windows[window.id] === window else { request.complete(false); return false }
        let oldPage = window.nativeSelectionSession
        window.nativeSelectionGeneration = request.id
        window.nativeSelectionSession = nil
        window.nativeSplitPreparation = request
        oldPage?.cancelNativePreparation(in: window)
        guard nativeSplitCurrent(request, host: host, in: window) else {
            finishNativeSplit(request, succeeded: false, in: window); return true
        }
        prepareNativeSplit(request, index: 0, host: host, in: window)
        return true
    }

    /// Join only this already-running admission; never start/restart it. Used
    /// by the owner of a hidden restored window to finish that same request.
    @discardableResult
    public func whenNativeSplitPrepared(_ record: SplitRecord, activeItemID: UUID,
                                       in window: BrowserWindowState,
                                       completion: @escaping @MainActor (NativeSplitOutcome) -> Void) -> Bool {
        guard let request = window.nativeSplitPreparation, request.record == record,
              request.active == activeItemID, window.nativeSelectionGeneration == request.id else { return false }
        request.completions.append { [weak request] succeeded in
            guard let request else { completion(.superseded); return }
            completion(request.cancelled ? .superseded : (succeeded ? .admitted : .refused))
        }
        return true
    }

    @discardableResult
    func cancelNativeSplit(in window: BrowserWindowState) -> Bool {
        guard let request = window.nativeSplitPreparation else { return true }
        request.cancelled = true
        finishNativeSplit(request, succeeded: false, in: window)
        return window.nativeSelectionGeneration == nil && window.nativeSplitPreparation == nil
    }

    private func nativeSplitCurrent(_ request: NativeSplitPreparation, host: any NativePageHost,
                                    in window: BrowserWindowState) -> Bool {
        guard !isTerminating, nativePageHost === host, windowRegistry.windows[window.id] === window,
              window.nativeSplitPreparation === request, window.nativeSelectionGeneration == request.id,
              window.split == (request.published ? request.record : request.previous),
              request.liveAdmission?() ?? true,
              window.nativeSplitPreparation === request, window.nativeSelectionGeneration == request.id else { return false }
        let selected = window.selectedItemID
        let activeSpace = request.active.flatMap { tree(owner(of: window)).spaceID(of: $0) }
        // select(nativeAdmitted:) publishes space before its selected item. Only
        // this owned intermediate value is permitted; generation guards still
        // reject a nested/newer user selection.
        let publishingSpace = request.published && request.publishingSelection &&
            window.spaceID == activeSpace && selected == request.selectionAtActiveSpace
        guard selected == request.selectedBefore || (request.published && selected == request.active) ||
              publishingSpace else { return false }
        guard window.spaceID == request.spaceBefore || (request.published && window.spaceID == activeSpace) else { return false }
        let pagesCurrent = request.ordered.allSatisfy { page in
            session(for: page.itemID) === page && holds(page.itemID, in: window) &&
            item(page.itemID)?.isFolder == false && !page.nativeIsEnding && page.nativeRelease == nil &&
            page.profile?.id == request.profiles[page.itemID] &&
            (page.navigation == nil || page.navigation?.profileID == request.profiles[page.itemID]) &&
            (request.livePages == nil || (page.navigation != nil && page.navigation === request.livePages?[page.itemID]))
        }
        return pagesCurrent && window.nativeSplitPreparation === request &&
            window.nativeSelectionGeneration == request.id && nativePageHost === host &&
            windowRegistry.windows[window.id] === window
    }

    private func prepareNativeSplit(_ request: NativeSplitPreparation, index: Int,
                                    host: any NativePageHost, in window: BrowserWindowState) {
        guard nativeSplitCurrent(request, host: host, in: window) else {
            finishNativeSplit(request, succeeded: false, in: window); return
        }
        if index < request.ordered.count {
            let page = request.ordered[index]
            request.preparing = page
            window.nativeSelectionSession = page
            if request.livePages != nil {
                request.preparing = nil
                prepareNativeSplit(request, index: index + 1, host: host, in: window)
                return
            }
            page.ensureNativePage(in: window) { [weak self, weak window] prepared in
                guard let self, let window else { request.complete(false); return }
                guard prepared, self.nativeSplitCurrent(request, host: host, in: window) else {
                    self.finishNativeSplit(request, succeeded: false, in: window); return
                }
                request.preparing = nil
                self.prepareNativeSplit(request, index: index + 1, host: host, in: window)
            }
            return
        }
        let current = { self.nativeSplitCurrent(request, host: host, in: window) }
        if let active = request.active, let leaving = selectedSession(in: window), leaving.itemID != active {
            leaving.captureSwitcherSnapshot()
        }
        guard current(), host.applySplit(request.record, replacing: request.previous, pages: request.pages,
                activeItemID: request.active, in: window, isCurrent: current), current(),
              host.isSplit(request.record, pages: request.pages, activeItemID: request.active, in: window) else {
            finishNativeSplit(request, succeeded: false, in: window); return
        }
        request.published = true
        window.split = request.record
        guard current() else { finishNativeSplit(request, succeeded: false, in: window); return }
        for page in request.ordered {
            recordPageOwner(page.itemID, in: window)
            guard current() else { finishNativeSplit(request, succeeded: false, in: window); return }
        }
        if let active = request.active.flatMap({ request.pages[$0] }), active.navigation != nil {
            request.publishingSelection = true
            finishNativeAdoption(active, in: window, opener: nil, parent: nil,
                select: true, generation: request.id,
                validateNative: { current() && host.isSplit(request.record, pages: request.pages,
                    activeItemID: request.active, in: window) })
            request.publishingSelection = false
        } else {
            mirror(window)
        }
        let success = current() && host.isSplit(request.record, pages: request.pages,
            activeItemID: request.active, in: window)
        finishNativeSplit(request, succeeded: success, in: window)
    }

    private func finishNativeSplit(_ request: NativeSplitPreparation, succeeded: Bool,
                                   in window: BrowserWindowState) {
        let owns = window.nativeSplitPreparation === request
        if owns {
            window.nativeSplitPreparation = nil
            if window.nativeSelectionGeneration == request.id {
                window.nativeSelectionGeneration = nil
                window.nativeSelectionSession = nil
            }
        }
        // Clear borrowed callbacks before cancellation can synchronously reenter.
        let callbacks = request.completions
        request.completions.removeAll()
        if owns && !succeeded { request.preparing?.cancelNativePreparation(in: window) }
        callbacks.forEach { $0(succeeded) }
        if !request.cancelled, window.nativeSelectionGeneration == nil,
           window.nativeSplitPreparation == nil {
            window.nativePresentationDidSettle?(succeeded)
        }
    }
}

extension BrowserWindowState {
    public var nativeSplitIsPreparing: Bool { nativeSplitPreparation != nil }
    public var nativePresentationIsPreparing: Bool {
        nativeSelectionGeneration != nil || nativeSplitPreparation != nil
    }
}

extension TabsController {
    /// Reflect an actual native collection. Unsplit/absent is never inferred by
    /// the model: the concrete host must prove explicit removal before passing nil.
    @discardableResult
    public func reflectNativeSplit(_ record: SplitRecord?, in window: BrowserWindowState,
                                   validateNative: () -> Bool) -> Bool {
        guard !isTerminating, let host = nativePageHost,
              windowRegistry.windows[window.id] === window, validateNative() else { return false }
        if window.split == record { return validateNative() }
        guard cancelNativeSplit(in: window), validateNative() else { return false }
        if let record {
            for id in record.itemIDs {
                guard holds(id, in: window), let page = session(for: id)?.navigation,
                      host.canAdoptPage(page, in: window) else { return false }
            }
        }
        window.split = record
        guard windowRegistry.windows[window.id] === window, window.split == record,
              nativePageHost === host, validateNative() else { return false }
        mirror(window)
        return window.split == record && validateNative()
    }

    /// Restore only on an explicit selection or a fresh product's first show.
    /// Catalog absence by itself never loads parked/unselected saved panes.
    @discardableResult
    public func restoreSavedNativeSplitIfNeeded(in window: BrowserWindowState,
                                               completion: (@MainActor (Bool) -> Void)? = nil) -> Bool {
        guard !isTerminating,
              window.nativeSelectionGeneration == nil, window.nativeSplitPreparation == nil,
              let record = window.split, let active = window.selectedItemID, record.contains(active),
              let host = nativePageHost else { return false }
        let pages = Dictionary(uniqueKeysWithValues: record.itemIDs.compactMap { id in
            session(for: id).map { (id, $0) }
        })
        if host.isSplit(record, pages: pages, activeItemID: active, in: window) { return false }
        return presentNativeSplit(record, activeItemID: active, in: window, completion: completion)
    }
}
