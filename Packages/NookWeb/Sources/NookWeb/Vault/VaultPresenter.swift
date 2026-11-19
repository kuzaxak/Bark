// Licensed under GPL-3.0. See LICENSE.
//
//  VaultPresenter.swift
//  Nook
//
//  The native UI the Pawl Vault bridge needs from the app. Nothing reaches the vault for a
//  password, a one-time code or a signature without one of these answering first.
//

#if os(macOS)
import Foundation
import WebKit

public struct VaultPickerItem: Identifiable, Sendable {
    public enum Kind: Sendable {
        case login(id: String)
        case passkey(credentialId: String)
        /// The entry's one-time code, for a code field.
        case code(id: String)
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// The account: a login's username or a passkey's user name.
    public let account: String

    public var isPasskey: Bool {
        if case .passkey = kind { return true }
        return false
    }

    init(_ login: VaultLogin) {
        id = "login:" + login.id
        kind = .login(id: login.id)
        title = VaultPrompt.displayText(login.title)
        account = VaultPrompt.displayText(login.username)
    }

    init(code login: VaultLogin) {
        id = "code:" + login.id
        kind = .code(id: login.id)
        title = VaultPrompt.displayText(login.title)
        account = VaultPrompt.displayText(login.username)
    }

    init(_ passkey: VaultPasskey) {
        id = "passkey:" + passkey.credentialId
        kind = .passkey(credentialId: passkey.credentialId)
        title = VaultPrompt.displayText(passkey.title)
        account = VaultPrompt.displayText(passkey.userName)
    }
}

public enum VaultNativePickerResult {
    case selected(VaultPickerItem), cancelled, focusUnavailable
}

/// The action the user is authorizing for a validated website submission.
public enum VaultLoginOffer: Equatable, Sendable {
    case create, update, manageNew, manageExisting
}

@MainActor
public protocol VaultPresenter: AnyObject {
    /// Lists `items` in a popover pointing at `anchor`, in `webView`'s coordinates. `host` names
    /// the site asking. An empty list shows that the vault has nothing for it. `completion` gets
    /// the pick, or nil when the popover closes without one.
    func presentPicker(host: String, items: [VaultPickerItem], anchor: CGRect, in webView: NSView,
                       completion: @escaping (VaultPickerItem?) -> Void)
    /// Native picker selection may restore only its original owned view, at
    /// the user's direct action and while this exact request remains valid.
    func presentNativePicker(host: String, items: [VaultPickerItem], anchor: CGRect, in view: NSView,
                             validateSelection: @escaping @MainActor () -> Bool,
                             completion: @escaping (VaultNativePickerResult) -> Void)
    func ownsNativePicker(in view: NSView) -> Bool
    /// Closes a picker shown over `webView`, calling its completion with nil.
    func dismissPicker(in webView: NSView)
    /// The non-modal "Save password to Pawl Vault?" offer. `completion(true)` means Save.
    func offerSave(host: String, username: String, in webView: NSView, completion: @escaping (Bool) -> Void)
    /// Native consent belongs to the exact page that submitted the login.
    func offerNativeLogin(_ action: VaultLoginOffer, host: String, username: String, itemID: UUID,
                          in view: NSView, completion: @escaping (Bool) -> Void)
    func dismissSave(in view: NSView)
    /// Request-owned native creation consent; cancellation ends only this view's sheet/picker.
    func confirmNativePasskeyCreation(rpId: String, userName: String, in view: NSView,
                                      completion: @escaping (Bool) -> Void)
    func dismissNativePasskey(in view: NSView)
    func ownsNativePasskeyPresentation(in view: NSView, keyWindow: NSWindow) -> Bool
    /// Asks before the vault creates a passkey. `completion(true)` means go ahead.
    func confirmPasskeyCreation(rpId: String, userName: String, in webView: NSView,
                                completion: @escaping (Bool) -> Void)
}
#endif

#if os(macOS)
extension VaultPresenter {
    public func confirmNativePasskeyCreation(rpId: String, userName: String, in view: NSView,
                                             completion: @escaping (Bool) -> Void) { completion(false) }
    public func dismissNativePasskey(in view: NSView) { dismissPicker(in:view) }
    public func ownsNativePasskeyPresentation(in view: NSView, keyWindow: NSWindow) -> Bool { false }
    public func offerSave(host: String, username: String, in webView: NSView,
                          completion: @escaping (Bool) -> Void) { completion(false) }
    public func offerNativeLogin(_ action: VaultLoginOffer, host: String, username: String, itemID: UUID,
                                 in view: NSView, completion: @escaping (Bool) -> Void) { completion(false) }
    public func dismissSave(in view: NSView) {}
    public func presentNativePicker(host: String, items: [VaultPickerItem], anchor: CGRect, in view: NSView,
                                    validateSelection: @escaping @MainActor () -> Bool,
                                    completion: @escaping (VaultNativePickerResult) -> Void) {
        // An implementation without native focus restoration must fail closed.
        completion(.focusUnavailable)
    }
    public func ownsNativePicker(in view: NSView) -> Bool { false }
}
#endif
