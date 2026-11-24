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
        let nativeCreationAccepted: Bool
        @ObservationIgnored var header: NSView?
        @ObservationIgnored var actions: NSView?
        var presentation: (sourceWindow: Int32, sourceTab: Int32, peekWindow: Int32, peekTab: Int32, generation: UInt64)?
        init(page: PageSession, tab: UUID, window: BrowserWindowState, source: PageSession,
             nativeCreationAccepted: Bool) {
            self.page = page; self.tab = tab; self.windowID = window.id; self.window = window
            self.source = source
            self.nativeCreationAccepted = nativeCreationAccepted
        }
    }
    /// Each tab's Peek, outside the tab tree until it moves to a tab.
    private var slots = PeekSlots<Entry>()
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
        }
        // A tab that lets go of its page, closed or unloaded, ends its Peeks with it.
        browserManager.tabs.onPageUnloaded = { [weak self] itemID in
            self?.tabClosed(itemID)
        }
    }

    /// The Peek over the tab `window` shows.
    func page(in window: BrowserWindowState) -> PageSession? {
        guard let tab = window.selectedItemID, let entry = slots.page(tab: tab, window: window.id),
              isNativePresented(entry) else { return nil }
        return entry.page
    }

    func page(tab: UUID, window: UUID) -> PageSession? {
        slots.page(tab: tab, window: window)?.page
    }

    func nativePage(tab: Int32) -> PageSession? {
        slots.values.first { entry in
            (entry.page.navigation as? ChromiumPageNavigation)?.nativeTabID == tab
        }?.page
    }

    func coversNativeSource(_ source: PageSession, in window: BrowserWindowState) -> Bool {
        guard window.selectedItemID == source.itemID,
              let entry = slots.page(tab: source.itemID, window: window.id), entry.source === source else { return false }
        return isNativePresented(entry)
    }

    /// `page` is the Peek `window` shows and Chromium's selected page there, while the window's
    /// layout still holds the tab under it.
    func isNativeSelection(_ page: PageSession, in window: BrowserWindowState) -> Bool {
        guard let tab = window.selectedItemID, let entry = slots.page(tab: tab, window: window.id),
              entry.page === page, isNativePresented(entry),
              let native = page.navigation as? ChromiumPageNavigation,
              let source = entry.source?.navigation as? ChromiumPageNavigation,
              let host = browserManager?.tabs.nativePageHost as? ChromiumNativePageHost else { return false }
        return host.isNativePeekSelection(native, source: source, in: window)
    }

    func completeNativeAdoption(tab: Int32) {
        guard let entry = slots.values.first(where: {
            ($0.page.navigation as? ChromiumPageNavigation)?.nativeTabID == tab && !$0.page.isDetached
        }) else { return }
        remove(entry)
    }

    func dismissPeek(in window: BrowserWindowState) {
        guard let tab = window.selectedItemID else { return }
        dismiss(tab: tab, window: window.id)
    }

    func moveToSplitView(in window: BrowserWindowState) {
        guard canEnterSplitView(in: window), let browserManager, let tab = window.selectedItemID,
              let entry = slots.page(tab: tab, window: window.id) else { return }
        let split = browserManager.splitManager.shownSplit(in: window)
        let record = split.map { $0.inserting(entry.page.itemID, beside: tab, after: true) }
            ?? SplitRecord([tab, entry.page.itemID])
        if let record { adopt(in: window, intoSplit: record) }
    }

    func moveToNewTab(in window: BrowserWindowState) {
        adopt(in: window)
    }

    func canEnterSplitView(in window: BrowserWindowState) -> Bool {
        guard let browserManager, let tab = window.selectedItemID,
              let entry = slots.page(tab: tab, window: window.id),
              browserManager.splitManager.offersAddSplitView(in: window),
              (browserManager.tabs.nativePageHost as? ChromiumNativePageHost)?.laysOutSplits(in: window) == true else { return false }
        return isCurrent(entry)
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
    }

    private func dismiss(_ entry: Entry, completion: ((Bool) -> Void)? = nil) {
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

    /// Moves the current tab's Peek into the tab tree, nested under that tab.
    private func adopt(in window: BrowserWindowState, intoSplit split: SplitRecord? = nil) {
        guard let tab = window.selectedItemID, let entry = slots.page(tab: tab, window: window.id),
              let source = entry.source, isNativePresented(entry),
              nativeAdmission?.promotePeek(entry.page, source: source, in: window, intoSplit: split) == true else { return }
        remove(entry)
    }

    func presentExternalURL(_ url: URL, from source: PageSession) {
        guard !source.isDetached, let navigation = source.navigation as? ChromiumPageNavigation,
              let request = navigation.pendingPeekRequestID, let tabs = browserManager?.tabs,
              let window = tabs.window(for: source), tabs.isNativePageOwner(source, in: window) else { return }
        let tab = source.itemID
        if let old = slots.page(tab: tab, window: window.id) {
            guard old.source === source else { return }
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
              entry.nativeCreationAccepted,
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
        for entry in slots.values where entry.page.navigation == nil { remove(entry) }
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
