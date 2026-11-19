// Licensed under GPL-3.0. See LICENSE.
//
//  TabsController+Agent.swift
//  NookWeb
//
//  The Agent space: where DevMCP agents browse, with the person's logins. Agent activity never
//  changes what a window shows; the person opens the space to watch, like any other.
//

import Foundation
import Observation
import os
import NookTabsCore

extension TabsController {
    public var agentSpaceID: UUID? { tree.agentSpace?.id }

    public func isInAgentSpace(_ itemID: UUID) -> Bool {
        guard let agent = agentSpaceID else { return false }
        return tree.spaceID(of: itemID) == agent
    }

    /// The Agent space, made on first use with the logins of `window`'s space.
    @discardableResult
    public func ensureAgentSpace(loginsFrom window: BrowserWindowState?) -> UUID? {
        if let existing = agentSpaceID { return existing }
        var made: UUID?
        perform(.main, "agentSpace", undoable: false) { tree in
            guard let result = tree.ensureAgentSpace(loginsFrom: window?.spaceID) else { throw TreeError.missingSpace }
            made = result.id
            return result.change
        }
        return made
    }

    /// The tab the agent works in: its last pick while it is still in the Agent space, else the
    /// space's first tab.
    public var agentItem: UUID? {
        guard let agent = agentSpaceID else { return nil }
        let order = displayOrder(inSpace: agent)
        if let current = agentItemID, order.contains(current) { return current }
        return order.first
    }

    /// Makes `itemID` the agent's tab. Windows showing the Agent space show it; the others only
    /// remember it for when the person opens the space. The page loads either way.
    func selectForAgent(_ itemID: UUID) {
        guard let agent = agentSpaceID, tree.spaceID(of: itemID) == agent else { return }
        agentItemID = itemID
        for other in regularWindows {
            if other.spaceID == agent {
                if other.selectedItemID != itemID { select(itemID, in: other) }
            } else {
                other.selectedItemBySpace[agent] = itemID
                other.emptiedSpaces.remove(agent)
                mirror(other)
            }
        }
        guard let session = ensureSession(for: itemID) else { return }
        session.loadWebViewIfNeeded()
        onAgentPage?(session)
    }
}

extension PageSession {
    /// A page in the Agent space: it opens no window, sheet or panel and records no history.
    public var isAgentPage: Bool { controller?.isInAgentSpace(itemID) == true }
}


extension TabsController {
    fileprivate var nativeAgentProfileID: UUID? {
        guard let login = tree.agentSpace?.agentLoginSpaceID,
              let source = tree.space(login), !source.isAgent,
              let profile = tree.dataStoreID(for: login), isProfileAvailable(profile) else { return nil }
        return profile
    }

    /// Read-only access for native tools: never materialize a cold page or borrow
    /// another window/profile's live document.
    public func existingNativeAgentPage(in window: BrowserWindowState) -> PageSession? {
        guard !isTerminating, !window.isIncognito, window.privateTree == nil,
              windowRegistry.windows[window.id] === window, let expected = nativeAgentProfileID,
              let id = agentItem, let page = session(for: id), page.controller === self,
              !page.isPrivate, !page.isDetached, !page.nativeIsEnding, isNativePageOwner(page, in: window),
              let profile = page.profile, !profile.isEphemeral, profile.id == expected,
              let navigation = page.navigation, navigation.profileID == expected,
              let host = nativePageHost, host.canAdoptPage(navigation, in: window) else { return nil }
        return page
    }

    /// Prepare the existing Agent item without selecting a tab or creating a
    /// window. The native host binds its exact persistent profile in this group.
    public func prepareNativeAgentPage(in window: BrowserWindowState) async -> PageSession? {
        guard !Task.isCancelled, !isTerminating,
              !window.isIncognito, window.privateTree == nil, windowRegistry.windows[window.id] === window,
              let expectedProfile = nativeAgentProfileID,
              let id = agentItem, let page = ensureSession(for: id), !page.isDetached,
              let profile = page.profile, !profile.isEphemeral,
              profile.id == expectedProfile, isProfileAvailable(profile.id), let host = nativePageHost else { return nil }
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler { @MainActor in
            let attempt = UUID()
            page.nativeAgentPreparationID = attempt
            var prepared: Bool?
            @MainActor func current() -> Bool {
                !cancelled.withLock({ $0 }) && !Task.isCancelled && !isTerminating && agentItem == id && session(for: id) === page &&
                    page.nativeAgentPreparationID == attempt && nativePageHost === host && page.profile?.id == profile.id &&
                    nativeAgentProfileID == profile.id && isProfileAvailable(profile.id) && windowRegistry.windows[window.id] === window && !window.isIncognito && window.privateTree == nil
            }
            defer {
                events.continuation.finish()
                if page.nativeAgentPreparationID == attempt {
                    page.nativeAgentPreparationID = nil
                    if page.nativeCreation?.backgroundAdmission != nil { page.cancelNativeCreation() }
                }
            }
            page.ensureNativePage(in: window, backgroundAdmission: { [weak self, weak page, weak window] in
                guard let self, let page, let window else { return false }
                // A newer Agent call can take over this same blank; foreground
                // preparation clears the background claim in ensureNativePage.
                return !cancelled.withLock({ $0 }) && page.nativeAgentPreparationID != nil && self.agentItem == id &&
                    self.session(for: id) === page && self.windowRegistry.windows[window.id] === window &&
                    page.profile?.id == profile.id && self.nativeAgentProfileID == profile.id && self.isProfileAvailable(profile.id)
            }) { ready in prepared = ready; events.continuation.yield(()) }
            events.continuation.yield(())
            for await _ in events.stream {
                let valid = withObservationTracking {
                    _ = windowRegistry.registrationRevision
                    _ = page.loadingState
                    return current()
                } onChange: { DispatchQueue.main.async { events.continuation.yield(()) } }
                guard valid else { return nil }
                guard let prepared else { continue }
                guard prepared, let navigation = page.navigation, !page.nativeIsEnding,
                      navigation.profileID == profile.id, host.canAdoptPage(navigation, in: window) else { return nil }
                if !isNativePageOwner(page, in: window) { recordPageOwner(id, in: window) }
                return current() && page.navigation === navigation ? page : nil
            }
            return nil
        } onCancel: {
            cancelled.withLock { $0 = true }
            events.continuation.finish()
        }
    }
}

extension PageSession {
    public var nativeAgentNavigationIsPending: Bool {
        isAgentPage && usesNativePageHost && !nativeStartupNavigationHasSettled
    }

    /// One bounded tool wait over actual navigation events. Cancellation drops
    /// only observation; it never stops or reloads a newer navigation.
    public func waitForNativeAgentNavigation(in window: BrowserWindowState, reload: Bool,
                                            while isCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        guard usesNativePageHost, isAgentPage, let controller, let navigation,
              controller.agentItem == itemID, !nativeIsEnding,
              controller.windowRegistry.windows[window.id] === window,
              let host = controller.nativePageHost else { return false }
        let attempt = UUID(), serial = nativeNavigationSerial
        nativeAgentWaitID = attempt
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let expected = serial &+ (reload || nativeNavigationPendingStart ? 1 : 0)
        func current() -> Bool {
            !Task.isCancelled && nativeAgentWaitID == attempt && self.navigation === navigation &&
                !nativeIsEnding && controller.agentItem == itemID && controller.session(for: itemID) === self &&
                controller.windowRegistry.windows[window.id] === window &&
                profile?.id == navigation.profileID && controller.nativeAgentProfileID == navigation.profileID && isCurrent() &&
                controller.nativePageHost === host && host.canAdoptPage(navigation, in: window)
        }
        defer {
            events.continuation.finish()
            if nativeAgentWaitID == attempt { nativeAgentWaitID = nil }
        }
        // Arm before dispatch: native callbacks can synchronously start/finish.
        var dispatched = !reload
        func watch() -> (Bool, UInt64, PageSession.LoadingState) {
            withObservationTracking {
                _ = controller.windowRegistry.registrationRevision
                _ = url
                _ = nativeNavigationFinishedWasReload
                return (current(), nativeNavigationSerial, loadingState)
            } onChange: { DispatchQueue.main.async { events.continuation.yield(()) } }
        }
        guard watch().0 else { return false }
        if reload {
            // Do not mistake an already pending navigation's finish for reload.
            guard nativeStartupNavigationHasSettled else { return false }
            nativeNavigationPendingStart = true
            dispatched = navigation.reload()
            guard dispatched else {
                if nativeAgentWaitID == attempt, nativeNavigationSerial == serial {
                    nativeNavigationPendingStart = false
                }
                return false
            }
        }
        events.continuation.yield(())
        for await _ in events.stream {
            let state = watch()
            guard state.0, dispatched, state.1 <= expected else { return false }
            switch state.2 {
            case .didFail, .didFailProvisionalNavigation: return false
            default:
                if case .idle = state.2, nativeStartupNavigationHasSettled { return false }
                if state.1 < expected { continue }
                if nativeStartupNavigationHasSettled {
                    if case .didFinish = state.2 { return !reload || nativeNavigationFinishedWasReload }
                    return false
                }
            }
        }
        return false
    }
}
