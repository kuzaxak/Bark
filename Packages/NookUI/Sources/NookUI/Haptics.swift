// Licensed under GPL-3.0. See LICENSE.
//
//  Haptics.swift
//  NookUI
//

import AppKit

public enum Haptics {
    /// The small click the sidebar plays when a selection snaps into place.
    @MainActor public static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
