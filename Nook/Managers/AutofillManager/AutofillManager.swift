// Licensed under GPL-3.0. See LICENSE.
//
//  AutofillManager.swift
//  Nook
//
//  The native side of Pawl Vault autofill: the account and passkey popover under a field, the
//  "Save password to Pawl Vault?" card over the page, and the confirmation before a passkey is
//  created. The password waiting on the card lives only in its closure and goes when the card does.
//

import AppKit
import SwiftUI
import NookWeb

@MainActor
@Observable
final class AutofillManager: NSObject, VaultPresenter, NSPopoverDelegate {
    struct SaveOffer: Identifiable {
        let id = UUID()
        let itemID: UUID
        weak var view: NSView?
        weak var window: NSWindow?
        let host: String
        let username: String
        let action: VaultLoginOffer
        fileprivate let respond: (Bool) -> Void
    }

    /// The pending save offer and the page it belongs to.
    private(set) var saveOffer: SaveOffer?

    @ObservationIgnored private var nativeCreation: (id: UUID, alert: NSAlert, view: NSView, owner: NSWindow, reply: (Bool) -> Void)?
    @ObservationIgnored private var popover: NSPopover?
    @ObservationIgnored private var pickerEscapeMonitor: Any?
    @ObservationIgnored private weak var popoverWebView: NSView?
    @ObservationIgnored private weak var pickerOwnerWindow: NSWindow?
    @ObservationIgnored private var nativePickerOpening = false
    @ObservationIgnored private var pickerCompletion: ((VaultNativePickerResult) -> Void)?
    @ObservationIgnored private var pickerShownAt = Date.distantPast
    @ObservationIgnored private var nativeSelectionCheck: (@MainActor () -> Bool)?
    @ObservationIgnored private var pickerGeneration = 0
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private static let saveOfferLifetime: Duration = .seconds(120)

    // MARK: - Picker

    func ownsNativePicker(in view: NSView) -> Bool {
        guard nativeSelectionCheck != nil, popoverWebView === view,
              let shown = popover, (shown.isShown || nativePickerOpening),
              let owner = pickerOwnerWindow, view.window === owner,
              let picker = shown.contentViewController?.view.window else { return false }
        return NSApp.keyWindow === picker || NSApp.keyWindow === owner
    }
    func presentNativePicker(host: String, items: [VaultPickerItem], anchor: CGRect, in view: NSView,
                             validateSelection: @escaping @MainActor () -> Bool,
                             completion: @escaping (VaultNativePickerResult) -> Void) {
        pickerGeneration += 1
        let generation = pickerGeneration
        closePicker(with: nil)
        guard generation == pickerGeneration else { completion(.cancelled); return }
        guard let window = view.window else { completion(.cancelled); return }
        guard window.isVisible, validateSelection(), generation == pickerGeneration,
              view.window === window else {
            completion(.focusUnavailable)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: VaultPickerView(host: host, items: items) { [weak self] item in self?.pick(item, generation:generation) })
        self.popover = popover
        popoverWebView = view
        pickerOwnerWindow = window
        pickerCompletion = completion
        nativeSelectionCheck = validateSelection
        pickerShownAt = .now
        nativePickerOpening = true
        popover.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        nativePickerOpening = false
        if self.popover === popover {
            // Chromium can retain keyboard focus in the page while the account list is visible.
            pickerEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak popover] event in
                MainActor.assumeIsolated {
                    guard event.keyCode == 53,
                          event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                          let self, let popover, self.popover === popover,
                          let view = self.popoverWebView, self.ownsNativePicker(in: view),
                          let target = event.window,
                          target === popover.contentViewController?.view.window ||
                              (target === view.window && target.attachedSheet == nil) else { return event }
                    self.closePicker(with: nil)
                    return nil
                }
            }
        }
    }

    func dismissPicker(in webView: NSView) {
        guard popoverWebView === webView else { return }
        closePicker(with: nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard (notification.object as? NSPopover) === popover else { return }
            closePicker(with: nil)
        }
    }

    /// A click or Return the page lined up before the popover appeared does not pick.
    private func pick(_ item: VaultPickerItem?, generation: Int) {
        guard generation == pickerGeneration else { return }
        if item != nil, !VaultPrompt.acceptsPick(shownAt: pickerShownAt, now: .now) { return }
        if item != nil {
            guard let view = popoverWebView, ownsNativePicker(in:view), nativeSelectionCheck?() == true else { closePicker(with:nil); return }
        }
        closePicker(with: item)
    }

    private func closePicker(with item: VaultPickerItem?) {
        if let pickerEscapeMonitor { NSEvent.removeMonitor(pickerEscapeMonitor) }
        pickerEscapeMonitor = nil
        let completion = pickerCompletion
        pickerCompletion = nil
        let shown = popover, view = popoverWebView, window = pickerOwnerWindow
        let pickerWindow = shown?.contentViewController?.view.window
        let check = nativeSelectionCheck, generation = pickerGeneration
        nativeSelectionCheck = nil
        popover = nil
        popoverWebView = nil
        pickerOwnerWindow = nil
        nativePickerOpening = false
        shown?.close()
        if let item {
            // Only the direct, still-current user choice may restore focus.
            // RPC completions never enter this path or activate a window.
            guard pickerGeneration == generation, popover == nil, let check, check(),
                  let view, let window, let pickerWindow, view.window === window,
                  NSApp.keyWindow === window || NSApp.keyWindow === pickerWindow else { completion?(.focusUnavailable); return }
            if NSApp.keyWindow === pickerWindow { window.makeKey() }
            guard pickerGeneration == generation, popover == nil, check(),
                  view.window === window, NSApp.keyWindow === window,
                  window.makeFirstResponder(view) else { completion?(.focusUnavailable); return }
            completion?(.selected(item))
        } else {
            completion?(.cancelled)
        }
    }

    // MARK: - Save offer

    func offerNativeLogin(_ action: VaultLoginOffer, host: String, username: String, itemID: UUID,
                          in view: NSView, completion: @escaping (Bool) -> Void) {
        // Remove old identity before its cancellation callback can reenter.
        saveGeneration &+= 1
        let generation = saveGeneration
        answerSaveOffer(false)
        guard saveGeneration == generation else { completion(false); return }
        let offer = SaveOffer(itemID: itemID, view: view, window: view.window, host: host,
                              username: username, action: action, respond: completion)
        saveOffer = offer
        let offerID = offer.id
        Task { [weak self] in
            try? await Task.sleep(for: Self.saveOfferLifetime)
            self?.answerSaveOffer(false,id:offerID)
        }
    }

    func dismissSave(in view: NSView) {
        if saveOffer?.view === view { answerSaveOffer(false) }
    }
    func answerSaveOffer(_ save: Bool, id: UUID? = nil) {
        if let id, saveOffer?.id != id { return }
        let offer = saveOffer
        saveOffer = nil
        offer?.respond(save)
    }

    // MARK: - Passkey creation

    func ownsNativePasskeyPresentation(in view: NSView, keyWindow: NSWindow) -> Bool {
        if let request = nativeCreation, request.view === view, view.window === request.owner,
           request.alert.window === keyWindow { return true }
        return ownsNativePicker(in:view) && popover?.contentViewController?.view.window === keyWindow
    }

    func dismissNativePasskey(in view: NSView) {
        // Detach exact sheet identity before closing a picker can reenter.
        let request = nativeCreation?.view === view ? nativeCreation : nil
        if request != nil { nativeCreation = nil }
        dismissPicker(in:view)
        guard let request else { return }
        if let parent = request.alert.window.sheetParent {
            parent.endSheet(request.alert.window,returnCode:.cancel)
        }
        request.reply(false)
    }
    func confirmNativePasskeyCreation(rpId: String, userName: String, in view: NSView, completion: @escaping (Bool) -> Void) {
        guard nativeCreation == nil, let window = view.window, window.isVisible,
              window.attachedSheet == nil, !view.isHiddenOrHasHiddenAncestor,
              NSApp.keyWindow == nil || NSApp.keyWindow === window else { completion(false); return }
        let id = UUID(), alert = NSAlert()
        alert.messageText = "Create a passkey for \(rpId)?"
        alert.informativeText = "Pawl Vault will save a passkey for \(userName)."
        alert.addButton(withTitle:"Continue").keyEquivalent = ""
        alert.addButton(withTitle:"Cancel")
        nativeCreation = (id,alert,view,window,completion)
        alert.beginSheetModal(for:window) { [weak self] result in
            guard let self, let request = self.nativeCreation, request.id == id else { return }
            self.nativeCreation = nil
            request.reply(result == .alertFirstButtonReturn && request.view.window === request.owner &&
                          !request.view.isHiddenOrHasHiddenAncestor &&
                          (NSApp.keyWindow == nil || NSApp.keyWindow === request.owner || NSApp.keyWindow === request.alert.window))
        }
    }
}
