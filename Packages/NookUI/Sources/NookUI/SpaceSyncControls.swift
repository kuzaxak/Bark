// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncControls.swift
//  NookUI
//
//  iCloud sync of spaces as Settings and the space menu see it. The app conforms with its
//  CloudKit engine.
//

import Foundation
import NookTabsCore

@MainActor public protocol SpaceSyncControls: AnyObject {
    var status: SpaceSyncStatus { get }
    var isSyncEnabled: Bool { get }
    var currentAccountClaim: SpaceSyncAccountClaim? { get }
    func enableSync()
    func disableSync()
    func level(of spaceID: UUID) -> SpaceSyncLevel
    func setLevel(_ level: SpaceSyncLevel, for spaceID: UUID)
    func syncNow()
    /// Every space record in the account's zone, with its state here.
    var cloudSpaces: [SpaceSyncCloudSpace] { get }
    /// The names of the Macs whose changes the account holds.
    var cloudDevices: [String] { get }
    /// Deletes the space's records from iCloud, so the Macs that sync it delete it, and turns
    /// it Off here, where it stays.
    func removeFromICloud(_ spaceID: UUID)
    /// What the last fetch did with each record: ids, types, levels and times only.
    func syncReport() -> String
    /// Shares this account's zone with the iCloud account whose invite code the person pasted,
    /// as its Mac's Settings shows it. Only invited accounts can join.
    func invite(code: String) async -> SpaceSyncInviteResult
    func stopSharing()
    /// Joins another account's shared zone from its pasted sharing link.
    func joinSharedSync(link: String)
    /// Leaves the joined zone: the spaces stay here, every one Off, back on this account's zone.
    func leaveSharedSync()
    /// Deletes the old copies of moved spaces from this account's own zone.
    func removeOldCopies()
    /// Joins, after asking, a zone this account already joined on another Mac.
    func joinOffer(_ owner: String)
}

extension SpaceSyncControls {
    public var currentAccountClaim: SpaceSyncAccountClaim? { nil }
}

@MainActor
struct SpaceSyncDialogOwner {
    private let claim: SpaceSyncAccountClaim
    private weak var owner: (any SpaceSyncControls)?

    init?(_ owner: any SpaceSyncControls) {
        guard let claim = owner.currentAccountClaim else { return nil }
        self.claim = claim
        self.owner = owner
    }

    func matches(_ current: (any SpaceSyncControls)?) -> Bool {
        guard let owner, let current else { return false }
        return owner === current && current.currentAccountClaim == claim
    }

    func join(link: String, using current: (any SpaceSyncControls)?) {
        guard matches(current) else { return }
        current?.joinSharedSync(link: link)
    }

    func invite(code: String, using current: () -> (any SpaceSyncControls)?) async -> SpaceSyncDialogInviteResult? {
        guard let controls = current(), matches(controls) else { return nil }
        let result = await controls.invite(code: code)
        guard matches(current()) else { return nil }
        return SpaceSyncDialogInviteResult(owner: self, value: result)
    }
}

@MainActor
struct SpaceSyncDialogInviteResult {
    let owner: SpaceSyncDialogOwner
    let value: SpaceSyncInviteResult

    func copyLink(using current: (any SpaceSyncControls)?, copy: (String) -> Void) {
        guard owner.matches(current), case .invited(let link) = value else { return }
        copy(link.absoluteString)
    }
}

@MainActor
struct SpaceSyncConfirmation {
    enum Action {
        case removeSpace(UUID), stopSharing, removeOldCopies, leave
    }

    let title: String
    let button: String
    let message: String
    private let action: Action
    private let owner: SpaceSyncDialogOwner

    init?(_ action: Action, title: String, button: String, message: String, owner: any SpaceSyncControls) {
        guard let owner = SpaceSyncDialogOwner(owner) else { return nil }
        self.action = action
        self.title = title
        self.button = button
        self.message = message
        self.owner = owner
    }

    func canConfirm(using current: (any SpaceSyncControls)?) -> Bool {
        owner.matches(current)
    }

    func confirm(using current: (any SpaceSyncControls)?) {
        guard let current, canConfirm(using: current) else { return }
        switch action {
        case .removeSpace(let id): current.removeFromICloud(id)
        case .stopSharing: current.stopSharing()
        case .removeOldCopies: current.removeOldCopies()
        case .leave: current.leaveSharedSync()
        }
    }
}

extension SpaceSyncLevel {
    public var title: String {
        switch self {
        case .off: return "Off"
        case .pinned: return "Favorites & Pinned"
        case .everything: return "Everything"
        }
    }

    public var symbol: String {
        switch self {
        case .off: return "icloud.slash"
        case .pinned: return "icloud"
        case .everything: return "icloud.fill"
        }
    }
}
