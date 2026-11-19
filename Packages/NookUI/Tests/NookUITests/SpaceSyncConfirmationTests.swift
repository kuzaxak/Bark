// Licensed under GPL-3.0. See LICENSE.

import Foundation
import NookTabsCore
import Testing
@testable import NookUI

@MainActor
private final class Sync: SpaceSyncControls {
    var currentAccountClaim: SpaceSyncAccountClaim?
    let status = SpaceSyncStatus(availability: .available)
    let isSyncEnabled = true
    let cloudSpaces: [SpaceSyncCloudSpace] = []
    let cloudDevices: [String] = []
    var actions: [String] = []
    var onInvite: (() async -> SpaceSyncInviteResult)?

    func enableSync() {}
    func disableSync() {}
    func level(of spaceID: UUID) -> SpaceSyncLevel { .off }
    func setLevel(_ level: SpaceSyncLevel, for spaceID: UUID) {}
    func syncNow() {}
    func syncReport() -> String { "" }
    func invite(code: String) async -> SpaceSyncInviteResult {
        actions.append("invite " + code)
        return await onInvite?() ?? .failed(message: "Unexpected invite")
    }
    func joinSharedSync(link: String) { actions.append("join " + link) }
    func joinOffer(_ owner: String) {}
    func removeFromICloud(_ spaceID: UUID) { actions.append(spaceID.uuidString) }
    func stopSharing() { actions.append("stop") }
    func leaveSharedSync() { actions.append("leave") }
    func removeOldCopies() { actions.append("old") }
}

@MainActor
struct SpaceSyncConfirmationTests {
    @Test func callbacksRemainBoundToThePresentingAccountAndDataset() throws {
        let sync = Sync()
        let spaceID = UUID()
        let originalDataset = UUID()
        let otherDataset = UUID()
        let actions: [SpaceSyncConfirmation.Action] = [.removeSpace(spaceID), .stopSharing, .removeOldCopies, .leave]

        func claim(_ account: String, _ dataset: UUID) -> SpaceSyncAccountClaim? {
            SpaceSyncAccountClaim(availability: .available, dataset: dataset, account: account)
        }
        func presented(_ action: SpaceSyncConfirmation.Action) -> SpaceSyncConfirmation? {
            SpaceSyncConfirmation(action, title: "Title", button: "Confirm", message: "Warning", owner: sync)
        }

        for account in ["synthetic-new", "synthetic-original"] {
            sync.currentAccountClaim = claim("synthetic-original", originalDataset)
            let confirmations = try actions.map { action in try #require(presented(action)) }
            #expect(confirmations.allSatisfy { $0.canConfirm(using: sync) })

            sync.currentAccountClaim = nil
            #expect(presented(.leave) == nil)
            for confirmation in confirmations { confirmation.confirm(using: sync) }
            #expect(sync.actions.isEmpty)

            // Both a completed account switch and a same-account leave/rejoin
            // make old callbacks obsolete even when sharing is available again.
            sync.currentAccountClaim = claim(account, otherDataset)
            for confirmation in confirmations {
                #expect(!confirmation.canConfirm(using: sync))
                confirmation.confirm(using: sync)
            }
            #expect(sync.actions.isEmpty)
        }

        let replacement = Sync()
        replacement.currentAccountClaim = sync.currentAccountClaim
        for action in actions {
            let fresh = try #require(presented(action))
            fresh.confirm(using: replacement)
            #expect(replacement.actions.isEmpty)
            fresh.confirm(using: sync)
        }
        #expect(sync.actions == [spaceID.uuidString, "stop", "old", "leave"])
    }

    @Test func inviteAndJoinRefuseSubmissionUnderAReplacementAccountOrDataset() async throws {
        let sync = Sync()
        let original = UUID()
        let replacement = UUID()
        let link = "https://www.icloud.com/share/synthetic"
        sync.currentAccountClaim = SpaceSyncAccountClaim(availability: .available, dataset: original, account: "original")
        let presented = try #require(SpaceSyncDialogOwner(sync))

        for account in ["replacement", "original"] {
            sync.currentAccountClaim = SpaceSyncAccountClaim(availability: .available, dataset: replacement, account: account)
            presented.join(link: link, using: sync)
            let refused = await presented.invite(code: "old-dialog", using: { sync })
            #expect(refused == nil)
            #expect(sync.actions.isEmpty)
        }

        let current = try #require(SpaceSyncDialogOwner(sync))
        current.join(link: link, using: sync)
        #expect(sync.actions == ["join " + link])
    }

    @Test func inviteReplyAndClipboardRemainBoundToTheSubmittingAccount() async throws {
        let sync = Sync()
        let dataset = UUID()
        sync.currentAccountClaim = SpaceSyncAccountClaim(availability: .available, dataset: dataset, account: "original")
        let presented = try #require(SpaceSyncDialogOwner(sync))
        let link = try #require(URL(string: "https://www.icloud.com/share/synthetic"))
        let replacement = SpaceSyncAccountClaim(availability: .available, dataset: UUID(), account: "replacement")
        sync.onInvite = {
            await Task.yield()
            sync.currentAccountClaim = replacement
            return .invited(link: link)
        }
        let refused = await presented.invite(code: "pending", using: { sync })
        #expect(refused == nil)
        #expect(sync.actions == ["invite pending"])

        sync.onInvite = { .invited(link: link) }
        let current = try #require(SpaceSyncDialogOwner(sync))
        let accepted = await current.invite(code: "fresh", using: { sync })
        let result = try #require(accepted)
        var copied: [String] = []
        result.copyLink(using: sync) { copied.append($0) }
        #expect(copied == [link.absoluteString])

        // A success alert already on screen cannot copy across a later switch.
        sync.currentAccountClaim = SpaceSyncAccountClaim(availability: .available, dataset: UUID(), account: "replacement")
        result.copyLink(using: sync) { copied.append($0) }
        #expect(copied == [link.absoluteString])
        #expect(sync.actions == ["invite pending", "invite fresh"])
    }
}
