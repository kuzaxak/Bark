// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore

/// Cancellation is only valid before native deletion was marked/destructive.
public enum ProfileDeletionOutcome {
    case deleted, pending
    /// Release the native scheduling reservation only after clearing the durable
    /// intent succeeds. False leaves the identity pending and unavailable.
    case cancelled(acknowledge: @MainActor () -> Bool)
    /// Every source owner accepted close. Native marking/wipe remains suspended
    /// until the model durably commits the exact assignment and source record.
    case closeAdmitted(continueCleanup: @MainActor (
        @escaping @MainActor (ProfileDeletionOutcome) -> Void
    ) -> Void)
}

public enum ProfileDeletionError: Error, Equatable { case unavailable, cancelled, persistenceFailed, pending }

public typealias ProfileDeletionAction = @MainActor (
    PendingProfileDeletion, _ reconcileOnly: Bool, _ canDelete: @escaping @MainActor () -> Bool,
    _ completion: @escaping @MainActor (ProfileDeletionOutcome) -> Void
) -> Void

