// Licensed under GPL-3.0. See LICENSE.
//
//  BoostOverlay.swift
//  Nook
//

import SwiftUI
import NookDesign
import NookSettings
import NookUI
import NookWeb

/// The Boost panel, drawn in the window over the page's top-right corner. Only the panel takes
/// clicks, so the page stays usable for Zap.
struct BoostOverlay: View {
    var fillsWindow = true
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @State private var nativePreview: (session: PageSession, serial: UInt64, page: ObjectIdentifier, token: UUID)?

    private var session: PageSession? { browserManager.frontPage(in: windowState) }

    var body: some View {
        content.task(id: windowState.isBoostPanelVisible) { await browserManager.nookSettings?.waitForBoosts() }
            .onChange(of: windowState.isBoostPanelVisible) { _, visible in
                if !visible, let lease = nativePreview {
                    nativePreview = nil
                    lease.session.endNativeBoostPreview(lease.token)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if windowState.isBoostPanelVisible, let settings = browserManager.nookSettings, settings.boostsLoaded, let session,
           case let host = Boost.normalizeHost(session.url.host ?? ""), !host.isEmpty
        {
            let serial = session.nativeNavigationSerial
            let page = session.navigation.map { ObjectIdentifier($0) }
            BoostPanel(
                settings: settings,
                host: host,
                canZap: session.navigation?.supportsElementPicker == true,
                canRunScripts: true,
                opensLibrary: windowState.boostPanelOpensLibrary,
                onPreview: { draft in preview(draft, in: session, serial: serial, page: page) },
                onZap: {
                    guard let lease = nativePreview, lease.session === session,
                          lease.serial == serial, lease.page == page else { return nil }
                    return await session.pickNativeBoostElement(token: lease.token)
                },
                onCancelZap: {
                    if let lease = nativePreview, lease.session === session, lease.serial == serial, lease.page == page {
                        session.cancelNativeBoostElementPicker(token: lease.token)
                    }
                },
                onFinish: { close(session, serial: serial, page: page) }
            )
            // A different site is a different panel, with its own draft.
            .id(host)
            .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.lg))
            .padding(fillsWindow ? NookDesign.Spacing.lg : 0)
            .frame(maxWidth: fillsWindow ? .infinity : nil,
                   maxHeight: fillsWindow ? .infinity : nil, alignment: .topTrailing)
            .padding(.top, fillsWindow ? NookDesign.Size.row : 0)
            .transition(.opacity)
            .onAppear {
                windowState.boostPanelOpensLibrary = false
                preview(nil, in: session, serial: serial, page: page)
            }
            .onDisappear { endNativePreview(session, serial: serial, page: page) }
            .onChange(of: windowState.selectedItemID) { _, _ in close(session, serial: serial, page: page) }
            .onChange(of: session.nativeNavigationSerial) { _, _ in
                close(session, serial: serial, page: page)
            }
            .onChange(of: session.navigation.map { ObjectIdentifier($0) }) { _, _ in
                close(session, serial: serial, page: page)
            }
            .onChange(of: session.isUnloaded) { _, unloaded in
                if unloaded { close(session, serial: serial, page: page) }
            }
        }
    }

    private func preview(_ draft: Boost?, in session: PageSession, serial: UInt64, page: ObjectIdentifier?) {
        guard browserManager.frontPage(in: windowState) === session,
              session.nativeNavigationSerial == serial, let page,
              session.navigation.map({ ObjectIdentifier($0) }) == page else { return }
        if nativePreview?.session !== session || nativePreview?.serial != serial || nativePreview?.page != page {
            if let old = nativePreview { old.session.endNativeBoostPreview(old.token) }
            nativePreview = nil
            guard let token = session.beginNativeBoostPreview() else {
                windowState.isBoostPanelVisible = false; return
            }
            nativePreview = (session, serial, page, token)
        }
        if let draft, let lease = nativePreview {
            _ = session.previewNativeBoost(draft, token: lease.token)
        }
    }

    private func endNativePreview(_ session: PageSession, serial: UInt64, page: ObjectIdentifier?) {
        guard let lease = nativePreview, lease.session === session, lease.serial == serial, lease.page == page else { return }
        nativePreview = nil
        session.endNativeBoostPreview(lease.token)
    }

    /// End the preview so the page shows the saved Boosts again.
    private func close(_ session: PageSession, serial: UInt64, page: ObjectIdentifier?) {
        endNativePreview(session, serial: serial, page: page)
        windowState.isBoostPanelVisible = false
    }
}
