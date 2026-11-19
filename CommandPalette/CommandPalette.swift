// Licensed under GPL-3.0. See LICENSE.
//
//  CommandPalette.swift
//  Nook
//
//  Per-window command palette state and actions
//

import Foundation
import SwiftUI

/// The owner of an address edit at the instant it was invoked. A nil page
/// explicitly represents an empty space. An unavailable owner has no context.
@MainActor
struct AddressEditTarget {
    struct Context: Equatable {
        let window: ObjectIdentifier
        let space: UUID?
        let selection: UUID?
        let page: ObjectIdentifier?
        let navigation: ObjectIdentifier?
        let nativeWindow: Int32?
        let nativeTab: Int32?
        let document: UInt64?
        let profile: UUID?
        let address: URL?
    }

    let id = UUID()
    private let captured: Context
    private let current: () -> Context?

    init?(current: @escaping () -> Context?) {
        guard let captured = current(), captured.page != nil || captured.selection == nil else { return nil }
        self.captured = captured
        self.current = current
    }

    var address: String { captured.address?.absoluteString ?? "" }
    var isCurrent: Bool { current() == captured }
}

@MainActor
@Observable
class CommandPalette {
    /// Whether the command palette is visible
    var isVisible: Bool = false

    /// Text to prefill in the command palette
    var prefilledText: String = ""

    /// Whether pressing Return should navigate the current tab (vs creating new tab)
    var shouldNavigateCurrentTab: Bool = false

    private(set) var addressEdit: AddressEditTarget?
    var visibleAddressEditID: UUID? { isVisible ? addressEdit?.id : nil }
    @ObservationIgnored private var pendingPresentation: UUID?

    /// The empty right pane the bar fills, while it is open for Add Split View.
    var addSplit: AddSplit?

    /// The page area in global coordinates, so the bar can sit over the empty pane.
    var pageFrame: CGRect = .zero

    // MARK: - Actions

    /// Open the command palette with optional prefill text.
    func open(prefill: String = "", navigateCurrentTab: Bool = false, addSplit: AddSplit? = nil) {
        present(prefill: prefill, navigateCurrentTab: navigateCurrentTab, addSplit: addSplit, target: nil)
    }

    /// Retained WebKit toolbar path.
    func openWithCurrentURL(_ url: URL) {
        open(prefill: url.absoluteString, navigateCurrentTab: true)
    }

    func openAddressEdit(_ target: AddressEditTarget) {
        guard target.isCurrent else { return }
        present(prefill: target.address, navigateCurrentTab: true, addSplit: nil, target: target)
    }

    private func present(prefill: String, navigateCurrentTab: Bool, addSplit: AddSplit?, target: AddressEditTarget?) {
        prefilledText = prefill
        shouldNavigateCurrentTab = navigateCurrentTab
        addressEdit = target
        self.addSplit = addSplit
        let pending = UUID()
        pendingPresentation = pending
        DispatchQueue.main.async {
            guard self.pendingPresentation == pending else { return }
            guard self.addressEdit?.isCurrent != false else { self.close(); return }
            self.isVisible = true
        }
    }

    /// Close the command palette
    func close() {
        pendingPresentation = nil
        isVisible = false
        addressEdit = nil
        shouldNavigateCurrentTab = false
        prefilledText = ""
        addSplit = nil
    }

    /// Toggle the command palette visibility
    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }
}
