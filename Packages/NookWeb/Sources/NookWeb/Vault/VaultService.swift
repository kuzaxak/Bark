// Licensed under GPL-3.0. See LICENSE.
//
//  VaultService.swift
//  Nook
//
//  The app-wide side of the Pawl Vault bridge: the setting, the socket client, the status
//  Settings shows, and the per-web-view bridges. Status comes from `hello`, asked when the
//  setting turns on, at most every few seconds on navigation, and before every passkey request.
//  The bridges also carry passkey requests to USB security keys while that setting is on.
//

#if os(macOS)
import Foundation
import NookSettings
import Observation
import WebKit
import AppKit

protocol VaultRequests: Sendable {
    func send<C: VaultCall>(_ call: C) async throws -> C.Reply
    func disconnect() async
}
extension VaultClient: VaultRequests {}

/// Browser-originated focused-field capability. No renderer-selected origin,
/// profile, frame ID or selector is accepted from the application.
public struct VaultNativeFocus {
    public let token: UInt64
    public let origin: String
    public let isCode: Bool
    public weak var view: NSView?
    public weak var window: NSWindow?
    public let anchor: CGRect
    public init(token: UInt64, origin: String, isCode: Bool, view: NSView, anchor: CGRect) {
        self.token = token; self.origin = origin; self.isCode = isCode
        self.view = view; self.window = view.window; self.anchor = anchor
    }
}
/// Chromium-owned, validated submission. Redirects may replace its document;
/// the exact native submission/owner token, rather than the current URL, authorizes saving.
public struct VaultNativeSubmission {
    public let token: UInt64
    public let origin, username, password: String
    public weak var view: NSView?
    public private(set) weak var window: NSWindow?
    public init(token: UInt64, origin: String, username: String, password: String, view: NSView) {
        self.token = token; self.origin = origin; self.username = username; self.password = password
        self.view = view; self.window = view.window
    }
}
/// A Chromium request-owned ceremony selected in the native provider chooser.
/// Arguments are browser-generated CTAP data; no renderer-origin/profile claims.
public struct VaultNativePasskeyRequest {
    public let token: UInt64
    public let operation: Int32
    public let arguments: String
    public weak var view: NSView?
    public private(set) weak var window: NSWindow?
    public init(token: UInt64, operation: Int32, arguments: String, view: NSView) {
        self.token = token; self.operation = operation; self.arguments = arguments
        self.view = view; self.window = view.window
    }
}
@MainActor
public protocol VaultNativePage: AnyObject {
    var vaultProfileID: UUID? { get }
    func observeVaultPasskeys(_ callback: (@MainActor (VaultNativePasskeyRequest?) -> Void)?)
    func vaultPasskeyIsCurrent(_ token: UInt64) -> Bool
    func completeVaultPasskey(_ token: UInt64, result: String?) -> Bool
    func observeVaultSave(_ callback: (@MainActor (VaultNativeSubmission?) -> Void)?)
    func vaultSaveIsCurrent(_ token: UInt64) -> Bool
    func cancelVaultSave(_ token: UInt64)
    func observeVault(_ callback: (@MainActor (VaultNativeFocus?) -> Void)?)
    func vaultFieldIsCurrent(_ token: UInt64) -> Bool
    func cancelVaultFocus(_ token: UInt64)
    func vaultFocusIsCurrent(_ token: UInt64) -> Bool
    /// One user-authorized fill; the native owner consumes the capability.
    func fillVault(_ token: UInt64, username: String, secret: String) -> Bool
}

extension VaultNativePage {
    public func observeVaultPasskeys(_ callback: (@MainActor (VaultNativePasskeyRequest?) -> Void)?) {}
    public func vaultPasskeyIsCurrent(_ token: UInt64) -> Bool { false }
    public func completeVaultPasskey(_ token: UInt64, result: String?) -> Bool { false }
    public func observeVaultSave(_ callback: (@MainActor (VaultNativeSubmission?) -> Void)?) {}
    public func vaultSaveIsCurrent(_ token: UInt64) -> Bool { false }
    public func cancelVaultSave(_ token: UInt64) {}
}

@MainActor
@Observable
public final class VaultService {
    /// The last `hello`'s answer; nil while the setting is off or before the first answer.
    public private(set) var status: VaultStatus? {
        didSet {
            guard oldValue != status else { return }
            if (oldValue == .connected) != (status == .connected) { VaultBridge.syncAll() }
            NotificationCenter.default.post(name: Self.nativeStateChanged, object: self)
        }
    }
    fileprivate static let nativeStateChanged = Notification.Name("NookVaultNativeStateChanged")

    @ObservationIgnored public weak var presenter: VaultPresenter?
    @ObservationIgnored public weak var securityKeyPresenter: SecurityKeyPresenter?
    @ObservationIgnored let client: any VaultRequests
    @ObservationIgnored private let openPawlApplication: @MainActor () -> Bool
    @ObservationIgnored fileprivate let passkeyKeyWindow: @MainActor () -> NSWindow?
    @ObservationIgnored private let settings: NookSettingsService
    @ObservationIgnored private var lastNavigationRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var settingObserver: NSObjectProtocol?
    @ObservationIgnored private var securityKeysObserver: NSObjectProtocol?

    @ObservationIgnored fileprivate var supportsConditionalLoginWrites = false

    /// The bundled Public Suffix List, read on the first passkey request.
    static let suffixes: PublicSuffixList = {
        let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat", subdirectory: "Resources")
        return PublicSuffixList(text: url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
    }()

    /// Set by Chromium engines that select one password provider for their process lifetime.
    public let pawlEnabledAtLaunch: Bool?

    public convenience init(settings: NookSettingsService, pawlEnabledAtLaunch: Bool? = nil) {
        self.init(settings: settings, client: VaultClient(), pawlEnabledAtLaunch: pawlEnabledAtLaunch,
                  openPawlApplication: VaultClient.openInstalledPawl)
    }

    init(settings: NookSettingsService, client: any VaultRequests, pawlEnabledAtLaunch: Bool? = nil,
         passkeyKeyWindow: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow },
         openPawlApplication: @escaping @MainActor () -> Bool = { false }) {
        self.settings = settings
        self.client = client
        self.passkeyKeyWindow = passkeyKeyWindow
        self.openPawlApplication = openPawlApplication
        self.pawlEnabledAtLaunch = pawlEnabledAtLaunch
        if pawlEnabledAtLaunch == nil {
            settingObserver = NotificationCenter.default.addObserver(
                forName: NookSettingsService.pawlVaultEnabledDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingChanged() }
            }
        }
        securityKeysObserver = NotificationCenter.default.addObserver(
            forName: NookSettingsService.securityKeysEnabledDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { VaultBridge.syncAll() }
        }
        if isEnabled { Task { await refresh() } }
    }

    public var isEnabled: Bool { pawlEnabledAtLaunch ?? settings.pawlVaultEnabled }

    /// Opens the installed vault at the person's request.
    public func openPawlVault() -> Bool { isEnabled && openPawlApplication() }

    public var securityKeysEnabled: Bool { settings.securityKeysEnabled }

    /// Paired and unlocked as of the last `hello`.
    public var isConnected: Bool { isEnabled && status == .connected }

    /// Asks the vault for its status and swaps the passkey scripts on every page when the
    /// answer changes whether passkeys go to the vault.
    @discardableResult
    public func refresh(profile: String? = nil) async -> VaultStatus? {
        guard isEnabled else { return nil }
        let answer: VaultStatus
        var conditionalWrites = false
        do {
            let hello = try await client.send(VaultHello(profile: profile))
            answer = VaultStatus(hello)
            conditionalWrites = hello.capabilities?.contains(VaultPrepareLoginWrite.capability) == true
        } catch let error as VaultClientError {
            answer = VaultStatus(error)
        } catch {
            answer = .notRunning
        }
        guard isEnabled else { return nil }
        supportsConditionalLoginWrites = answer == .connected && conditionalWrites
        status = answer
        return answer
    }

    func send<C: VaultCall>(_ call: C) async throws -> C.Reply {
        do { return try await client.send(call) }
        catch {
            recordRequestFailure(error)
            throw error
        }
    }

    fileprivate func recordRequestFailure(_ error: Error) {
        guard isEnabled, let error = error as? VaultClientError else { return }
        switch error {
        case .server(.locked, _), .server(.unpaired, _):
            status = VaultStatus(error)
        case .server:
            break
        default:
            status = VaultStatus(error)
        }
    }

    /// Native attachments retain only their own request/picker lifetime.
    public func attach(to page: any VaultNativePage, session: PageSession) -> @MainActor () -> Void {
        let attachment = NativeVaultAttachment(service: self, page: page, session: session)
        attachment.start()
        return { attachment.stop() }
    }

    // MARK: - Page hooks

    /// Installs the bridge on a page's web view. Agent pages never reach the vault.
    public func attach(to webView: WKWebView, session: PageSession) {
        guard !session.isAgentPage else { return }
        VaultBridge.install(on: webView, session: session, service: self)
    }

    public static func detach(from controller: WKUserContentController) {
        VaultBridge.uninstall(from: controller)
    }

    /// A main-frame navigation is starting: refresh the status for the pages after this one.
    public func navigationStarted() {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        if let last = lastNavigationRefresh, now - last < .seconds(3) { return }
        lastNavigationRefresh = now
        Task { await refresh() }
    }

    /// A new document committed in `webView`: requests and pickers from the old one end.
    public func pageCommitted(in webView: WKWebView) {
        VaultBridge.bridge(for: webView)?.pageCommitted(origin: webView.url.flatMap(WebAuthnPolicy.origin(of:)))
    }

    /// The web content process ended: the page's requests, pickers and sheets end with it.
    public func pageEnded(in webView: WKWebView) {
        VaultBridge.bridge(for: webView)?.documentChanged()
    }

    private func settingChanged() {
        if isEnabled {
            Task { await refresh() }
        } else {
            status = nil
            Task { await client.disconnect() }
        }
        VaultBridge.syncAll()
        NotificationCenter.default.post(name: Self.nativeStateChanged, object: self)
    }
}
@MainActor
private final class NativeVaultAttachment {
    weak var service: VaultService?
    weak var page: (any VaultNativePage)?
    weak var session: PageSession?
    private var observer: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var inactiveObserver: NSObjectProtocol?
    private var focus: VaultNativeFocus?
    private var generation: UInt64 = 0
    private var pickerView: NSView?
    private var stopped = false
    private var awaitingSecret = false
    private var submission: VaultNativeSubmission?
    private var saveGeneration: UInt64 = 0
    private var saveTask: Task<Void, Never>?
    private var saveObserving = false
    private var passkeysObserving = false
    private var passkeyTask: Task<Void,Never>?
    private var passkey: VaultNativePasskeyRequest?
    private var passkeyGeneration: UInt64 = 0
    private var passkeyObservers: [NSObjectProtocol] = []
    private weak var passkeyView: NSView?
    private weak var saveView: NSView?
    init(service: VaultService, page: any VaultNativePage, session: PageSession) {
        self.service = service; self.page = page; self.session = session
    }
    isolated deinit {
        saveTask?.cancel()
        if !stopped {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
            page?.observeVault(nil)
            page?.observeVaultSave(nil)
            page?.observeVaultPasskeys(nil)
            clearPasskeyObservers()
            if let view = passkeyView { service?.presenter?.dismissNativePasskey(in:view) }
            if let view = saveView { service?.presenter?.dismissSave(in: view) }
            if let view = pickerView { service?.presenter?.dismissPicker(in: view) }
        }
    }
    func start() {
        observer = NotificationCenter.default.addObserver(forName: VaultService.nativeStateChanged,
            object: service, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        sync()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        cancel()
        cancelSave()
        cancelPasskey()
        page?.observeVaultPasskeys(nil)
        page?.observeVaultSave(nil)
        page?.observeVault(nil)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        page = nil; session = nil; service = nil
    }
    private func sync() {
        guard !stopped else { return }
        cancel(showRetry: true)
        if service?.isEnabled == true {
            page?.observeVault { [weak self] focus in self?.focused(focus) }
        } else {
            page?.observeVault(nil)
        }
        let shouldObservePasskeys = service?.isConnected == true
        if passkeysObserving != shouldObservePasskeys {
            passkeysObserving = shouldObservePasskeys
            if shouldObservePasskeys {
                page?.observeVaultPasskeys { [weak self] request in self?.requested(request) }
            } else {
                cancelPasskey(); page?.observeVaultPasskeys(nil)
            }
        }
        let shouldObserveSave = service?.isConnected == true
        if saveObserving != shouldObserveSave {
            saveObserving = shouldObserveSave
            if shouldObserveSave {
                page?.observeVaultSave { [weak self] submission in self?.offered(submission) }
            } else {
                cancelSave()
                page?.observeVaultSave(nil)
            }
        }
    }
    private func passkeyOwnerCurrent(_ request: VaultNativePasskeyRequest, _ generation: UInt64) -> Bool {
        guard !stopped, passkeyGeneration == generation, passkey?.token == request.token,
              let service, service.isConnected, let page, let session,
              !session.isAgentPage, !session.nativeIsEnding,
              session.navigation === page as AnyObject,
              session.profile?.id == page.vaultProfileID, page.vaultProfileID != nil,
              let view = request.view, let window = request.window,
              view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
        return page.vaultPasskeyIsCurrent(request.token)
    }
    private func passkeyCurrent(_ request: VaultNativePasskeyRequest, _ generation: UInt64) -> Bool {
        guard passkeyOwnerCurrent(request, generation), let view = request.view else { return false }
        guard let key = service?.passkeyKeyWindow(), key !== request.window else { return true }
        return service?.presenter?.ownsNativePasskeyPresentation(in: view, keyWindow: key) == true
    }

    private func waitForPasskeyHost(_ request: VaultNativePasskeyRequest, _ generation: UInt64,
                                    resume: @escaping @MainActor () -> Void) -> Bool {
        guard let window = request.window, let service else { return false }
        let key = service.passkeyKeyWindow()
        let transient = key != nil && key !== window ? key : window.attachedSheet
        guard let transient, transient !== window,
              transient.sheetParent === window || transient.parent === window else { return false }

        // Chromium has closed its chooser before dispatching. AppKit can still
        // be returning key focus to the owner. Only this exact transient can
        // delay presentation. The consent itself still requires the owner.
        let center = NotificationCenter.default
        let advance: @MainActor @Sendable () -> Void = { [weak self, weak service, weak window] in
            guard let self, let service, let window, self.passkeyGeneration == generation else { return }
            guard self.passkeyOwnerCurrent(request, generation) else { self.cancelPasskey(); return }
            if service.passkeyKeyWindow() === window, window.attachedSheet == nil {
                self.clearPasskeyObservers()
                resume()
            }
        }
        passkeyObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self, weak window, weak transient] notification in
                MainActor.assumeIsolated {
                    guard let self, self.passkeyGeneration == generation,
                          let key = notification.object as? NSWindow else { return }
                    if key === window { advance() }
                    else if key !== transient { self.cancelPasskey() }
                }
            })
        passkeyObservers.append(center.addObserver(forName: NSWindow.didEndSheetNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { advance() } })
        passkeyObservers.append(center.addObserver(forName: NSWindow.didUpdateNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { advance() } })
        passkeyObservers.append(center.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.passkeyGeneration == generation else { return }
                    self.cancelPasskey()
                }
            })
        return true
    }
    private func requireCurrentPasskey(_ request: VaultNativePasskeyRequest, _ generation: UInt64) -> Bool {
        guard passkeyCurrent(request,generation) else {
            if passkeyGeneration == generation { cancelPasskey() }
            return false
        }
        return true
    }
    private func trackPasskeyWindow(_ request: VaultNativePasskeyRequest, _ generation: UInt64) {
        guard let window = request.window else { return }
        let center = NotificationCenter.default
        passkeyObservers.append(center.addObserver(forName:NSWindow.didBecomeKeyNotification,
            object:nil,queue:.main) { [weak self] notice in
                MainActor.assumeIsolated {
                    guard let self, self.passkeyGeneration == generation, let key = notice.object as? NSWindow,
                          let request = self.passkey, let view = request.view else { return }
                    if key !== request.window &&
                        self.service?.presenter?.ownsNativePasskeyPresentation(in:view,keyWindow:key) != true {
                        self.cancelPasskey()
                    }
                }
            })
        passkeyObservers.append(center.addObserver(forName:NSWindow.willCloseNotification,
            object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.passkeyGeneration == generation else { return }
                    self.cancelPasskey()
                }
            })
        passkeyObservers.append(center.addObserver(forName:NSWindow.didUpdateNotification,
            object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.passkeyGeneration == generation, let request = self.passkey else { return }
                    _ = self.requireCurrentPasskey(request,generation)
                }
            })
    }
    private func clearPasskeyObservers() {
        passkeyObservers.forEach(NotificationCenter.default.removeObserver)
        passkeyObservers.removeAll()
    }
    private func cancelPasskey() {
        passkeyGeneration &+= 1
        let task = passkeyTask; passkeyTask = nil; task?.cancel()
        let old = passkey; passkey = nil
        let view = passkeyView; passkeyView = nil
        clearPasskeyObservers()
        if let view { service?.presenter?.dismissNativePasskey(in:view) }
        if let old { _ = page?.completeVaultPasskey(old.token,result:nil) }
    }
    private func finishPasskey(_ request: VaultNativePasskeyRequest, _ generation: UInt64, _ result: [String:Any]) {
        guard passkeyCurrent(request,generation), let page,
              let data = try? JSONSerialization.data(withJSONObject:result),
              let json = String(data:data,encoding:.utf8) else {
            if passkeyGeneration == generation { cancelPasskey() }; return
        }
        // Consume before native completion can publish a cancellation/new request.
        passkey = nil; passkeyView = nil; passkeyTask = nil; passkeyGeneration &+= 1
        clearPasskeyObservers()
        if !page.completeVaultPasskey(request.token,result:json) {
            _ = page.completeVaultPasskey(request.token,result:nil)
        }
    }
    private func requested(_ request: VaultNativePasskeyRequest?) {
        guard request?.token != passkey?.token else { return }
        cancelPasskey()
        guard let request else { return }
        passkey = request
        let generation = passkeyGeneration
        guard let service else { cancelPasskey(); return }
        if service.client is VerificationVault { VerificationVault.record("Bark verification vault: passkey requested") }
        guard request.arguments.utf8.count <= 65536,
              let data = request.arguments.data(using:.utf8),
              let args = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let rp = args["rpId"] as? String, !rp.isEmpty,
              let origin = args["origin"] as? String,
              let originURL = URL(string:origin),
              WebAuthnPolicy.isAllowedOrigin(scheme:originURL.scheme ?? "",host:originURL.host ?? ""),
              let hash = args["clientDataHash"] as? String, Base64URL.decode(hash)?.count == 32,
              let profile = page?.vaultProfileID?.uuidString else { cancelPasskey(); return }
        guard passkeyOwnerCurrent(request, generation) else {
            if service.client is VerificationVault { VerificationVault.record("Bark verification vault: passkey owner stale") }
            cancelPasskey()
            return
        }
        if waitForPasskeyHost(request, generation, resume: { [weak self] in
            self?.presentPasskey(request, generation, args: args, rp: rp, origin: origin, hash: hash, profile: profile)
        }) { return }
        presentPasskey(request, generation, args: args, rp: rp, origin: origin, hash: hash, profile: profile)
    }

    private func presentPasskey(_ request: VaultNativePasskeyRequest, _ generation: UInt64,
                                args: [String: Any], rp: String, origin: String, hash: String, profile: String) {
        guard let service, let presenter = service.presenter, let view = request.view,
              passkeyCurrent(request, generation) else {
            if service?.client is VerificationVault { VerificationVault.record("Bark verification vault: passkey host inactive") }
            cancelPasskey()
            return
        }
        cancel() // Retire an unrelated field picker before ceremony consent.
        guard requireCurrentPasskey(request,generation) else { return }
        passkeyView = view
        trackPasskeyWindow(request,generation)
        if request.operation == 0 {
            guard let name = args["rpName"] as? String, let user = args["user"] as? [String:String],
                  let id = user["id"], let userID = Base64URL.decode(id), (1...64).contains(userID.count),
                  let userName = user["name"], let displayName = user["displayName"],
                  args["pubKeyCredParams"] as? [Int] == [-7],
                  let excluded = args["excludeCredentials"] as? [String] else { cancelPasskey(); return }
            let call = VaultRegister(rpId:rp,rpName:name,user:.init(id:id,name:userName,displayName:displayName),
                clientDataHash:hash,pubKeyCredParams:[-7],excludeCredentials:excluded,origin:origin,profile:profile)
            if service.client is VerificationVault { VerificationVault.record("Bark verification vault: passkey consent requested") }
            presenter.confirmNativePasskeyCreation(rpId:VaultPrompt.displayText(rp),userName:VaultPrompt.displayText(userName),
                in:view) { [weak self] accepted in
                guard let self, self.requireCurrentPasskey(request,generation) else { return }
                guard accepted else { self.cancelPasskey(); return }
                self.passkeyTask = Task { [weak self] in
                    guard let self, self.requireCurrentPasskey(request,generation) else { return }
                    do {
                        let result = try await service.send(call)
                        self.finishPasskey(request,generation,["credentialId":result.credentialId,
                            "attestationObject":result.attestationObject,"authenticatorData":result.authenticatorData,
                            "publicKeyAlgorithm":result.publicKeyAlgorithm])
                    } catch { if self.passkeyGeneration == generation { self.cancelPasskey() } }
                }
            }
        } else if request.operation == 1 {
            guard let allowed = args["allowCredentials"] as? [String] else { cancelPasskey(); return }
            passkeyTask = Task { [weak self] in
                guard let self, self.requireCurrentPasskey(request,generation) else { return }
                do {
                    let matches = try await service.send(VaultPasskeys(rpId:rp,allowCredentials:allowed,profile:profile)).passkeys
                    guard self.requireCurrentPasskey(request,generation) else { return }
                    let items = matches.filter { allowed.isEmpty || allowed.contains($0.credentialId) }.map(VaultPickerItem.init)
                    guard !items.isEmpty else { self.cancelPasskey(); return }
                    self.passkeyTask = nil
                    presenter.presentNativePicker(host:VaultPrompt.displayText(rp),items:items,
                        anchor:CGRect(x:view.bounds.midX,y:view.isFlipped ? 0 : max(0,view.bounds.height - 1),width:1,height:1),
                        in:view,validateSelection:{ [weak self] in self?.passkeyCurrent(request,generation) == true }) { [weak self] result in
                        guard let self, self.requireCurrentPasskey(request,generation) else { return }
                        guard case .selected(let item) = result, case .passkey(let credential) = item.kind,
                              items.contains(where: { $0.id == item.id }),
                              (allowed.isEmpty || allowed.contains(credential)) else { self.cancelPasskey(); return }
                        self.passkeyTask = Task { [weak self] in
                            guard let self, self.requireCurrentPasskey(request,generation) else { return }
                            do {
                                let result = try await service.send(VaultAssert(rpId:rp,credentialId:credential,
                                    clientDataHash:hash,userVerification:"required",origin:origin,profile:profile))
                                if allowed.isEmpty {
                                    guard let handle = result.userHandle, let bytes = Base64URL.decode(handle),
                                          !bytes.isEmpty, bytes.count <= 64 else {
                                        if self.passkeyGeneration == generation { self.cancelPasskey() }; return
                                    }
                                }
                                var encoded: [String:Any] = ["credentialId":result.credentialId,
                                    "authenticatorData":result.authenticatorData,"signature":result.signature]
                                if let handle = result.userHandle { encoded["userHandle"] = handle }
                                self.finishPasskey(request,generation,encoded)
                            } catch { if self.passkeyGeneration == generation { self.cancelPasskey() } }
                        }
                    }
                } catch {
                    if self.passkeyGeneration == generation { self.cancelPasskey() }
                }
            }
        } else { cancelPasskey() }
    }
    private func saveCurrent(_ offer: VaultNativeSubmission, _ generation: UInt64) -> Bool {
        guard !stopped, saveGeneration == generation, submission?.token == offer.token,
              let service, service.isConnected, let page, let session,
              !session.isAgentPage, !session.isPrivate, session.profile?.isEphemeral == false, !session.nativeIsEnding,
              session.navigation === page as AnyObject,
              session.profile?.id == page.vaultProfileID, page.vaultProfileID != nil,
              let view = offer.view, let window = offer.window, view.window === window,
              !view.isHiddenOrHasHiddenAncestor else { return false }
        return page.vaultSaveIsCurrent(offer.token)
    }
    private func requireCurrentSave(_ offer: VaultNativeSubmission, _ generation: UInt64) -> Bool {
        guard saveCurrent(offer,generation) else {
            if saveGeneration == generation { cancelSave() }
            return false
        }
        return true
    }
    private func cancelSave() {
        saveGeneration &+= 1
        saveTask?.cancel()
        saveTask = nil
        let old = submission; submission = nil
        let view = saveView; saveView = nil
        if let view { service?.presenter?.dismissSave(in: view) }
        if let old { page?.cancelVaultSave(old.token) }
    }
    private func offered(_ offer: VaultNativeSubmission?) {
        guard offer?.token != submission?.token else { return }
        cancelSave()
        guard let offer, let service, let session, let view = offer.view,
              let url = URL(string:offer.origin), WebAuthnPolicy.isAllowedOrigin(scheme:url.scheme ?? "",host:url.host ?? ""),
              !offer.username.isEmpty, !offer.password.isEmpty else { return }
        guard !session.isAgentPage, !session.isPrivate, session.profile?.isEphemeral == false else {
            page?.cancelVaultSave(offer.token)
            return
        }
        submission = offer
        let generation = saveGeneration
        guard saveCurrent(offer,generation) else { cancelSave(); return }
        let profile = page?.vaultProfileID?.uuidString
        let itemID = session.itemID
        saveTask = Task { [weak self] in
            do {
                let action: VaultLoginOffer
                var ticket: String?
                if service.supportsConditionalLoginWrites {
                    let plan = try await service.send(VaultPrepareLoginWrite(origin: offer.origin, username: offer.username,
                                                                           profile: profile))
                    switch plan.disposition {
                    case .ambiguous:
                        action = .manageExisting
                    case .create, .update:
                        guard let prepared = plan.ticket, !prepared.isEmpty else { throw VaultClientError.malformedResponse }
                        ticket = prepared
                        action = plan.disposition == .create ? .create : .update
                    }
                } else {
                    // A v1 save can overwrite an entry added after lookup. Only offer to open the vault.
                    let logins = try await service.send(VaultLogins(origin: offer.origin, profile: profile)).logins
                    action = logins.contains { $0.username == offer.username } ? .manageExisting : .manageNew
                }
                guard let self, self.requireCurrentSave(offer, generation) else { return }
                guard let presenter = service.presenter else { self.cancelSave(); return }
                self.saveView = view
                var answered = false
                presenter.offerNativeLogin(action, host: url.host ?? "", username: VaultPrompt.displayText(offer.username),
                                           itemID: itemID, in: view) { [weak self] accepted in
                    guard !answered else { return }
                    answered = true
                    guard let self, self.requireCurrentSave(offer, generation) else { return }
                    guard accepted else { self.cancelSave(); return }
                    if let ticket {
                        self.commit(offer, ticket: ticket, profile: profile, generation: generation)
                    } else {
                        if !service.openPawlVault(), self.saveCurrent(offer, generation) {
                            self.session?.nativeVaultNotice = action == .manageNew
                                ? "Open Pawl Vault directly to save this login."
                                : "Open Pawl Vault directly to update this password."
                        }
                        if self.saveGeneration == generation { self.cancelSave() }
                    }
                }
            } catch {
                guard let self, self.requireCurrentSave(offer, generation) else { return }
                self.session?.nativeVaultNotice = "Open Pawl Vault to manage this login."
                self.cancelSave()
            }
        }
    }

    private func commit(_ offer: VaultNativeSubmission, ticket: String, profile: String?, generation: UInt64) {
        saveTask = Task { [weak self] in
            guard let self, let service = self.service, self.requireCurrentSave(offer, generation) else { return }
            let write = VaultCommitLoginWrite(origin: offer.origin, username: offer.username, profile: profile,
                                              password: offer.password, ticket: ticket)
            do {
                let reply = try await service.client.send(write)
                guard self.requireCurrentSave(offer, generation) else { return }
                if reply.outcome == .conflict {
                    self.session?.nativeVaultNotice = "Review this login in Pawl Vault before saving again."
                }
            } catch {
                // Report uncertain delivery to the original page before a disconnect retires its offer.
                if self.saveCurrent(offer, generation) {
                    switch error as? VaultClientError {
                    case .server(.denied, _):
                        self.session?.nativeVaultNotice = "Pawl Vault declined to save this login."
                    case .server(.locked, _):
                        self.session?.nativeVaultNotice = "Unlock Pawl Vault to save this login."
                    default:
                        self.session?.nativeVaultNotice = "Save unconfirmed. Check this login in Pawl Vault."
                    }
                }
                service.recordRequestFailure(error)
            }
            if self.saveGeneration == generation { self.cancelSave() }
        }
    }

    private func cancel(showRetry: Bool = false) {
        let old = focus
        if showRetry, awaitingSecret, let old, let page, let session, !session.nativeIsEnding,
           session.navigation === page as AnyObject, session.profile?.id == page.vaultProfileID,
           old.view?.window === old.window, page.vaultFieldIsCurrent(old.token) {
            session.nativeVaultNotice = "Pawl Vault fill cancelled. Focus the field to try again."
        }
        generation &+= 1
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
        keyObserver = nil; inactiveObserver = nil
        awaitingSecret = false
        focus = nil
        if let old { page?.cancelVaultFocus(old.token) }
        let view = pickerView; pickerView = nil
        if let view { service?.presenter?.dismissPicker(in: view) }
    }
    private func current(_ focus: VaultNativeFocus, _ generation: UInt64, foreground: Bool = true) -> Bool {
        guard !stopped, self.generation == generation, self.focus?.token == focus.token,
              let service, service.isEnabled, let page, let session,
              !session.isAgentPage, !session.nativeIsEnding,
              session.navigation === page as AnyObject,
              session.profile?.id == page.vaultProfileID, page.vaultProfileID != nil,
              let view = focus.view, let window = focus.window,
              view.window === window, !view.isHiddenOrHasHiddenAncestor,
              page.vaultFieldIsCurrent(focus.token),
              !foreground || page.vaultFocusIsCurrent(focus.token) else { return false }
        return true
    }
    private func trackFocusWindows(_ focus: VaultNativeFocus) {
        guard focus.window != nil else { return }
        let generation = generation
        // These existing AppKit events invalidate this request, never focus or
        // retry it. Own picker key transitions are the sole scoped exception.
        keyObserver = NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,
            object:nil,queue:.main) { [weak self] notice in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.focus?.token == focus.token,
                          let old = self.focus, let view = old.view,
                          let key = notice.object as? NSWindow else { return }
                    if key !== old.window && self.service?.presenter?.ownsNativePicker(in:view) != true {
                        self.cancel(showRetry:true)
                    }
                }
            }
        inactiveObserver = NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,
            object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.focus?.token == focus.token else { return }
                    self.cancel(showRetry:true)
                }
            }
    }
    private func focused(_ focus: VaultNativeFocus?) {
        guard passkey == nil else { return }
        if let focus, self.focus?.token == focus.token { return }
        if focus == nil, let old = self.focus, let view = old.view,
           service?.presenter?.ownsNativePicker(in: view) == true,
           current(old, generation, foreground: false) { return }
        cancel(showRetry: focus == nil)
        guard let focus, focus.token != 0, let url = URL(string: focus.origin),
              let scheme = url.scheme, let host = url.host(percentEncoded: false),
              WebAuthnPolicy.isAllowedOrigin(scheme: scheme, host: host) else { return }
        self.focus = focus
        trackFocusWindows(focus)
        session?.nativeVaultNotice = nil
        let generation = generation
        guard current(focus, generation), let service, let profile = page?.vaultProfileID?.uuidString else {
            cancel()
            return
        }
        Task { [weak self, weak service] in
            guard let service else { return }
            let logins: [VaultLogin]
            do { logins = try await service.send(VaultLogins(origin: focus.origin, profile: profile)).logins }
            catch {
                if let self, self.generation == generation { self.cancel() }
                return
            }
            guard let self, self.current(focus, generation), let presenter = service.presenter,
                  let view = focus.view else { return }
            let items = focus.isCode ? logins.filter(\.hasCode).map(VaultPickerItem.init(code:)) : logins.map(VaultPickerItem.init(_:))
            guard !items.isEmpty else { return }
            self.pickerView = view
            presenter.presentNativePicker(host: host, items: items, anchor: focus.anchor, in: view,
                validateSelection: { [weak self] in self?.current(focus, generation, foreground: false) == true }) { [weak self] result in
                guard let self, self.generation == generation, self.focus?.token == focus.token else { return }
                let item: VaultPickerItem
                switch result {
                case .selected(let selected): item = selected
                case .cancelled: self.cancel(); return
                case .focusUnavailable:
                    self.awaitingSecret = true
                    self.cancel(showRetry: true); return
                }
                self.awaitingSecret = true
                guard self.current(focus, generation) else {
                        if self.generation == generation { self.cancel(showRetry: true) }
                        return
                    }
                self.pickerView = nil
                // The native picker is consent. Secrets are fetched only now,
                // after rechecking the exact page/profile/document/field.
                Task { [weak self, weak service] in
                    guard let self, let service else { return }
                    guard self.current(focus, generation) else {
                        if self.generation == generation { self.cancel(showRetry: true) }
                        return
                    }
                    do {
                        let username: String, secret: String
                        switch item.kind {
                        case .login(let id) where !focus.isCode:
                            let reply = try await service.send(VaultPassword(id: id, origin: focus.origin, profile: profile))
                            username = reply.username; secret = reply.password
                        case .code(let id) where focus.isCode:
                            let reply = try await service.send(VaultCode(id: id, origin: focus.origin, profile: profile))
                            username = ""; secret = reply.code
                        default: self.cancel(); return
                        }
                        guard self.current(focus, generation), let page = self.page else {
                            if self.generation == generation { self.cancel(showRetry: true) }
                            return
                        }
                        let admitted = page.fillVault(focus.token, username: username, secret: secret)
                        if self.generation == generation { self.cancel(showRetry: !admitted) }
                    } catch { if self.generation == generation { self.cancel(showRetry: true) } }
                }
            }
        }
    }
}
#endif
