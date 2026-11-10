// Licensed under GPL-3.0. See LICENSE.
//
//  ExitCommand.swift
//  NookUI
//
//  Escape cancels an inline rename.
//

import SwiftUI

extension View {
    @ViewBuilder
    func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        onExitCommand(perform: action)
    }
}
