// Licensed under GPL-3.0. See LICENSE.
//
//  PeekManager.swift
//  Nook
//
//  Created by Jonathan Caudill on 24/09/2025.
//

import AppKit
import Foundation
import NookDesign
import NookTabsCore
import NookWeb
import SwiftUI

/// Peek: a link shown in a card over the tab that opened it, as a detached page that runs like a
/// tab and becomes one when moved to a tab or split. Each tab keeps its own Peek while another
/// tab shows, as in Arc.
@MainActor
@Observable
final class PeekManager {
    @MainActor @Observable fileprivate final class Entry {
        let page: PageSession
        let tab: UUID
        let windowID: UUID
        weak var window: BrowserWindowState?
        weak var source: PageSession?
        let native: Bool
        let nativeCreationAccepted: Bool
        @ObservationIgnored var header: NSView?
        @ObservationIgnored var actions: NSView?
        var presentation: (sourceWindow: Int32, sourceTab: Int32, peekWindow: Int32, peekTab: Int32, generation: UInt64)?
        init(page: PageSession, tab: UUID, window: BrowserWindowState, source: PageSession? = nil,
             nativeCreationAccepted: Bool = true) {
            self.page = page; self.tab = tab; self.windowID = window.id; self.window = window
            self.source = source; self.native = source != nil
            self.nativeCreationAccepted = nativeCreationAccepted
        }
    }
    /// Each tab's Peek, outside the tab tree until it moves to a tab.
    private var slots = PeekSlots<Entry>()
    /// Where in its window each Peek was opened from, as a fraction of the window: the card grows
    /// out of that point, as Arc's grows out of the link.
    @ObservationIgnored private var origins: [UUID: UnitPoint] = [:]

    @ObservationIgnored weak var browserManager: BrowserManager?
    @ObservationIgnored weak var nativeAdmission: ChromiumCreatedPageAdmission?

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
        // A tab's Peek is still drawn as the window leaves the tab: its picture is taken for the
        // Control-Tab card then, like the tab's own.
        browserManager.tabs.onLeavingTab = { [weak self] itemID, window in
            guard let self, let peek = self.slots.page(tab: itemID, window: window.id) else { return }
            self.hideNative(peek)
            peek.page.captureSwitcherSnapshot()
            // A Peek waits hidden with its tab; nothing would show a video playing in it.
            peek.page.webView?.pauseAllMediaPlayback(completionHandler: nil)
        }
        // A tab that lets go of its page, closed or unloaded, ends its Peeks with it.
        browserManager.tabs.onPageUnloaded = { [weak self] itemID in
            self?.tabClosed(itemID)
        }
    }

    func origin(of page: PageSession) -> UnitPoint {
        origins[page.itemID] ?? .center
    }

    /// The Peek over the tab `window` shows.
    func page(in window: BrowserWindowState) -> PageSession? {
        guard let tab = window.selectedItemID, let entry = slots.page(tab: tab, window: window.id),
              !entry.native || isNativePresented(entry) else { return nil }
        return entry.page
    }

    func page(tab: UUID, window: UUID) -> PageSession? {
        slots.page(tab: tab, window: window)?.page
    }

    func nativePage(tab: Int32) -> PageSession? {
        slots.values.first { entry in
            entry.native && (entry.page.navigation as? ChromiumPageNavigation)?.nativeTabID == tab
        }?.page
    }

    func coversNativeSource(_ source: PageSession, in window: BrowserWindowState) -> Bool {
        guard window.selectedItemID == source.itemID,
              let entry = slots.page(tab: source.itemID, window: window.id), entry.source === source else { return false }
        return isNativePresented(entry)
    }

    func completeNativeAdoption(tab: Int32) {
        guard let entry = slots.values.first(where: {
            $0.native && ($0.page.navigation as? ChromiumPageNavigation)?.nativeTabID == tab && !$0.page.isDetached
        }) else { return }
        remove(entry)
    }

    func presentExternalURL(_ url: URL, from source: PageSession?) {
        // A private page never falls back to the default persistent store.
        guard let browserManager, let source, let profile = source.profile,
              let window = source.detachedWindow ?? browserManager.tabs.window(for: source),
              // A link in a Peek opens over the same tab, the one the window shows.
              let tab = source.isDetached ? window.selectedItemID : source.itemID else { return }

        if source.navigation is ChromiumPageNavigation {
            presentNative(url: url, source: source, tab: tab, window: window)
            return
        }
        // The same link again closes Peek.
        if slots.page(tab: tab, window: window.id)?.page.url == url {
            dismiss(tab: tab, window: window.id)
            return
        }

        let page = browserManager.tabs.openDetached(url: url, profile: profile, in: window)
        if let nsWindow = window.windowHandle as? NSWindow, let content = nsWindow.contentView, content.bounds.width > 0 {
            let pointer = nsWindow.mouseLocationOutsideOfEventStream
            origins[page.itemID] = UnitPoint(x: pointer.x / content.bounds.width, y: 1 - pointer.y / content.bounds.height)
        }
        let windowID = window.id
        page.onClose = { [weak self] in self?.dismiss(tab: tab, window: windowID) }
        let replaced = withAnimation(NookDesign.Motion.spring) {
            slots.open(Entry(page: page, tab: tab, window: window), tab: tab, window: window.id)
        }
        if let replaced {
            end(replaced.page)
        }
    }

    func dismissPeek(in window: BrowserWindowState) {
        guard let tab = window.selectedItemID else { return }
        dismiss(tab: tab, window: window.id)
    }

    func moveToSplitView(in window: BrowserWindowState) {
        guard let browserManager, canEnterSplitView(in: window), let tab = window.selectedItemID else { return }
        if let entry = slots.page(tab: tab, window: window.id), entry.native,
           (browserManager.tabs.nativePageHost as? ChromiumNativePageHost)?.laysOutSplits(in: window) == true {
            let split = browserManager.splitManager.shownSplit(in: window)
            let record = split.map { $0.inserting(entry.page.itemID, beside: tab, after: true) }
                ?? SplitRecord([tab, entry.page.itemID])
            guard let record else { return }
            adopt(in: window, intoSplit: record)
            return
        }
        guard let itemID = adopt(in: window) else { return }
        // The adopted page is selected; pair it with the tab the Peek was over.
        if tab != itemID {
            browserManager.tabs.select(tab, in: window)
            browserManager.splitManager.enterSplit(with: itemID, in: window)
        }
    }

    func moveToNewTab(in window: BrowserWindowState) {
        adopt(in: window)
    }

    func canEnterSplitView(in window: BrowserWindowState) -> Bool {
        guard let browserManager, let tab = window.selectedItemID,
              let entry = slots.page(tab: tab, window: window.id),
              browserManager.splitManager.offersAddSplitView(in: window) else { return false }
        return !entry.native || isCurrent(entry)
    }

    func tabClosed(_ itemID: UUID) {
        for entry in slots.values where entry.tab == itemID { dismiss(entry) }
    }

    func windowClosed(_ windowID: UUID) {
        for entry in slots.values where entry.windowID == windowID { dismiss(entry) }
    }

    private func dismiss(tab: UUID, window: UUID) {
        guard let entry = slots.page(tab: tab, window: window) else { return }
        dismiss(entry)
    }

    private func remove(_ entry: Entry) {
        guard slots.page(tab: entry.tab, window: entry.windowID) === entry else { return }
        hideNative(entry)
        _ = withAnimation(NookDesign.Motion.spring) { slots.close(tab: entry.tab, window: entry.windowID) }
        origins[entry.page.itemID] = nil
    }

    private func dismiss(_ entry: Entry, completion: ((Bool) -> Void)? = nil) {
        guard entry.native else { remove(entry); end(entry.page); completion?(true); return }
        guard let navigation = entry.page.navigation as? ChromiumPageNavigation else {
            remove(entry); completion?(false); return
        }
        // Refused creation can mean a newer callback took this document. The
        // existing catalog must adopt it before any former source acts on it.
        guard entry.nativeCreationAccepted else { completion?(false); return }
        guard let source = entry.source, let window = entry.window,
              nativeAdmission?.ownsPeek(entry.page, source: source, in: window) == true else {
            completion?(false); return
        }
        guard let host = browserManager?.tabs.nativePageHost as? ChromiumNativePageHost else {
            completion?(false); return
        }
        let closed: @MainActor (PageCloseOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            // The native page already ended. PageSession receives its terminal
            // event after this callback; do not tear down or close it again.
            if outcome != .cancelled { self.remove(entry) }
            completion?(outcome == .closed)
        }
        if let shownNext = source.navigation as? ChromiumPageNavigation {
            host.closePage(navigation, showing: shownNext, completion: closed)
        } else {
            host.closePage(navigation, completion: closed)
        }
    }

    private func end(_ page: PageSession) {
        origins[page.itemID] = nil
        browserManager?.tabs.endDetached(page)
    }

    /// Moves the current tab's Peek into the tab tree, nested under that tab.
    @discardableResult
    private func adopt(in window: BrowserWindowState, intoSplit split: SplitRecord? = nil) -> UUID? {
        guard let browserManager, let tab = window.selectedItemID,
              let entry = slots.page(tab: tab, window: window.id) else { return nil }
        let page = entry.page
        if entry.native {
            guard let source = entry.source, isNativePresented(entry),
                  nativeAdmission?.promotePeek(page, source: source, in: window, intoSplit: split) == true else { return nil }
            remove(entry)
            return page.itemID
        }
        remove(entry)
        origins[page.itemID] = nil
        guard let itemID = browserManager.tabs.adopt(page, in: window, from: tab) else {
            end(page)
            return nil
        }
        return itemID
    }

    private func presentNative(url: URL, source: PageSession, tab: UUID, window: BrowserWindowState) {
        guard let navigation = source.navigation as? ChromiumPageNavigation,
              let request = navigation.pendingPeekRequestID, !source.isDetached else { return }
        if let old = slots.page(tab: tab, window: window.id) {
            let sameURL = old.page.url == url
            dismiss(old) { [weak self, weak source, weak window, weak navigation] closed in
                guard closed, !sameURL, let self, let source, let window, let navigation,
                      source.navigation === navigation, navigation.pendingPeekRequestID == request else { return }
                self.createNative(source: source, request: request, tab: tab, window: window)
            }
        } else {
            createNative(source: source, request: request, tab: tab, window: window)
        }
    }

    private func createNative(source: PageSession, request: Int32, tab: UUID, window: BrowserWindowState) {
        guard let browserManager, slots.page(tab: tab, window: window.id) == nil,
              let created = nativeAdmission?.createPeek(from: source, request: request, in: window) else { return }
        let page = created.page
        let entry = Entry(page: page, tab: tab, window: window, source: source,
                          nativeCreationAccepted: created.accepted)
        entry.header = NSHostingView(rootView: PeekNavigationBar(page: page, cornerRadius: NookDesign.Radius.xl)
            .environmentObject(browserManager))
        entry.actions = NSHostingView(rootView: NativePeekActions(
            canEnterSplit: { [weak self, weak entry] in
                guard let self, let entry, self.isCurrent(entry), let window = entry.window else { return false }
                return self.canEnterSplitView(in: window)
            }, dismiss: { [weak self, weak entry] in
                guard let self, let entry, self.isCurrent(entry) else { return }
                self.dismiss(entry)
            }, openAsTab: { [weak self, weak entry] in
                guard let self, let entry, self.isCurrent(entry), let window = entry.window else { return }
                self.moveToNewTab(in: window)
            }, openInSplit: { [weak self, weak entry] in
                guard let self, let entry, self.isCurrent(entry), let window = entry.window else { return }
                self.moveToSplitView(in: window)
            }))
        page.onClose = { [weak self, weak entry] in
            guard let self, let entry else { return }
            if entry.page.navigation == nil { self.remove(entry) }
            else { self.dismiss(entry) }
        }
        slots.open(entry, tab: tab, window: window.id)
        // A newer callback may already have moved/navigated the admitted page.
        // Native refusal clears its Peek role; catalog admission or the actual
        // terminal event owns its next transition, never a second close here.
        guard created.accepted else { return }
        refreshNativePresentation(in: window)
    }

    private func isCurrent(_ entry: Entry) -> Bool {
        guard let window = entry.window, window.selectedItemID == entry.tab,
              slots.page(tab: entry.tab, window: entry.windowID) === entry,
              browserManager?.windowRegistry?.windows[window.id] === window else { return false }
        return isNativePresented(entry)
    }

    /// Called by selection/catalog changes, never a polling timer. A hidden
    /// Peek stays in its source slot until the actual native owner ends.
    func refreshNativePresentation(in window: BrowserWindowState) {
        guard let tab = window.selectedItemID, let entry = slots.page(tab: tab, window: window.id),
              entry.native, entry.nativeCreationAccepted,
              let source = entry.source?.navigation as? ChromiumPageNavigation,
              let page = entry.page.navigation as? ChromiumPageNavigation,
              let host = browserManager?.tabs.nativePageHost as? ChromiumNativePageHost,
              let header = entry.header, let actions = entry.actions, !isNativePresented(entry) else { return }
        let generation = host.presentPeek(source: source, page: page, header: header, actions: actions, dismiss: { [weak self, weak entry] in
            guard let self, let entry, self.isCurrent(entry) else { return }
            self.dismiss(entry)
        }, in: window)
        if generation != 0 {
            entry.presentation = (source.nativeWindowID, source.nativeTabID, page.nativeWindowID, page.nativeTabID, generation)
        }
    }

    func reconcileNativeOwners() {
        for entry in slots.values where entry.native && entry.page.navigation == nil { remove(entry) }
    }

    private func isNativePresented(_ entry: Entry) -> Bool {
        guard let host = browserManager?.tabs.nativePageHost as? ChromiumNativePageHost, let window = entry.window,
              let p = entry.presentation, let header = entry.header, let actions = entry.actions else { return false }
        return host.isPeekPresented(sourceWindow: p.sourceWindow, sourceTab: p.sourceTab,
            peekWindow: p.peekWindow, peekTab: p.peekTab, generation: p.generation, header: header, actions: actions, in: window)
    }

    private func hideNative(_ entry: Entry) {
        guard let host = browserManager?.tabs.nativePageHost as? ChromiumNativePageHost,
              let window = entry.window, let p = entry.presentation,
              let header = entry.header, let actions = entry.actions else { return }
        entry.presentation = nil
        host.hidePeek(sourceWindow: p.sourceWindow, sourceTab: p.sourceTab, peekWindow: p.peekWindow,
            peekTab: p.peekTab, generation: p.generation, header: header, actions: actions, in: window)
    }
}

private struct NativePeekActions: View {
    let canEnterSplit: () -> Bool
    let dismiss: () -> Void
    let openAsTab: () -> Void
    let openInSplit: () -> Void
    var body: some View {
        PeekActionButtons(canEnterSplit: canEnterSplit(), dismiss: dismiss,
                          openAsTab: openAsTab, openInSplit: openInSplit)
    }
}
