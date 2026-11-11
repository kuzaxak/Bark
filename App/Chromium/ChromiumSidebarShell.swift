import NookDesign
import NookSettings
import NookUI
import NookWeb
import AppKit
import SwiftUI

/// The existing tab-tree sidebar only. Chromium owns the adjacent web surface;
/// constructing WindowView/WebsiteView here would reinstate WebKit hosting.
struct ChromiumSidebarShell: View {
    @ObservedObject var browserManager: BrowserManager
    let storage: ChromiumAppStorage
    let window: BrowserWindowState
    let registry: WindowRegistry
    let commandPalette: CommandPalette
    let organizer: TabOrganizerManager
    @ObservedObject var hover: HoverSidebarManager
    let aiService: AIService
    let setPageHidden: (Bool) -> Void
    @State private var dialogFocus = ChromiumDialogFocus()
    @State private var siteControlsAnchor = ChromiumSiteControlsAnchor()
    @State private var titleBand = SidebarTitleBand.design
    @Environment(\.colorScheme) private var baseColorScheme

    private func focusShownPage() {
        guard !window.nativePresentationIsPreparing, let page = browserManager.frontPage(in: window),
              let native = page.navigation as? ChromiumPageNavigation,
              browserManager.tabs.nativePageHost?.isNativeSelection(native, in: window) == true else { return }
        _ = native.selectNativePage()
    }

    private var spaceChrome: ChromiumSpaceChrome {
        let space = window.spaceID.flatMap { browserManager.tabs.space($0) }
        return ChromiumSpaceChrome(isIncognito: window.isIncognito, draftTheme: window.spaceDraftTheme,
            spaceID: window.spaceID, agentSpaceID: browserManager.tabs.agentSpaceID,
            spaceTheme: space?.theme, spaceAccentHex: space?.accentHex)
    }

    private func applyAccent() {
        guard let hex = spaceChrome.accentHex, registry.activeWindowId == window.id else { return }
        browserManager.gradientColorManager.setImmediate(SpaceGradient.accent(hex: hex))
    }

    private var layers: some View {
        ZStack {
            ChromiumSpaceBackground(chrome: spaceChrome, isActive: registry.activeWindowId == window.id)
                .animation(NookDesign.Motion.standard, value: window.spaceID)
                .animation(NookDesign.Motion.standard, value: window.spaceDraftTheme == nil)
            SpacesSideBarView()
                .environment(\.nookBaseColorScheme, baseColorScheme)
                .environment(\.sidebarTitleBand, titleBand)
                .spaceThemeAppearance(spaceChrome.theme)
                .background(SidebarTitleBandReader { titleBand = $0 ?? .design })
                // Chromium's title bar band is the lights' row, which the title row shares.
                .ignoresSafeArea(.container, edges: .top)
                .opacity(window.isSidebarMenuVisible ? 0 : 1)
                .allowsHitTesting(!window.isSidebarMenuVisible)
            if let page = browserManager.tabs.selectedSession(in:window), let notice = page.nativeVaultNotice {
                VStack {
                    HStack(alignment:.top) {
                        Text(notice).font(.caption).fixedSize(horizontal:false,vertical:true)
                        Button("Dismiss") { page.nativeVaultNotice = nil }.font(.caption)
                    }
                    .padding(10).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius:8))
                    Spacer()
                }.padding(8)
            }
            if window.isSidebarMenuVisible {
                SidebarMenu()
                    .spaceThemeAppearance(spaceChrome.theme)
            }
            if window.isSidebarAIChatVisible {
                SidebarAIChat()
                    .environment(aiService)
                    .environment(storage.aiConfig)
                    .background(Color(nsColor: .windowBackgroundColor))
                    // The traffic lights and the sidebar's title row stay reachable above the chat.
                    .padding(.top, storage.settings.sidebarPosition == .left ? NookDesign.Spacing.sidebarTop : 0)
            }
            if let offer = browserManager.autofillManager.saveOffer,
               let page = browserManager.frontPage(in:window), offer.itemID == page.itemID {
                VStack {
                    VaultSaveOfferView(offer:offer) { browserManager.autofillManager.answerSaveOffer($0,id:offer.id) }
                        .padding(8)
                    Spacer()
                }
            }
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if browserManager.showTabClosureToast && browserManager.tabClosureToastCount > 0 {
                    TabClosureToast()
                }
                if let tidied = browserManager.downloadManager.lastTidied, registry.activeWindowId == window.id {
                    TidyDownloadToast(download: tidied, downloads: browserManager.downloadManager)
                }
                if window.isShowingCopyURLToast {
                    CopyURLToast(title: window.copyToastText)
                }
            }
            .frame(width: window.sidebarContentWidth)
            .padding(.vertical, 10)
            .animation(.smooth(duration: 0.25), value: browserManager.showTabClosureToast)
            .animation(.smooth(duration: 0.25), value: window.isShowingCopyURLToast)
            .animation(.smooth(duration: 0.25), value: browserManager.downloadManager.lastTidied?.id)
            CommandPaletteView()
            ForEach(translationPages, id: \.itemID) { page in
                TranslationTaskHost(session: page)
            }
            if let page = browserManager.frontPage(in: window) {
                VStack {
                    if let language = page.translationOffer, !page.isTranslated {
                        TranslateOfferView(session: page, language: language)
                    } else if let notice = page.translationNotice, page.isTranslated {
                        TranslationNoticeView(session: page, notice: notice)
                    }
                    Spacer()
                }
            }
        }
    }

    private var hostedLayers: some View {
        layers
            .environmentObject(browserManager)
            .environmentObject(browserManager.gradientColorManager)
            .environmentObject(hover)
            .environment(browserManager.tabs)
            .environment(storage.settings)
            .environment(\.nookSettings, storage.settings)
            .environment(\.tabActions, browserManager)
            .environment(window)
            .environment(registry)
            .environment(commandPalette)
            .environment(organizer)
            .environment(\.nookUsesDefaultSpaceTheme, spaceChrome.theme == nil)
            .environment(\.chromiumSiteControlsAnchor, siteControlsAnchor)
            .defaultAppStorage(storage.defaults)
            .modifier(OrganizeTabsRequests(window: window, registry: registry, organizer: organizer, tabs: browserManager.tabs,
                notify: { [browserManager, window] in browserManager.showWindowToast($0, in: window) }))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { applyAccent() }
            .onChange(of: spaceChrome.accentHex) { _, _ in applyAccent() }
            .onChange(of: registry.activeWindowId) { _, _ in applyAccent() }
            .background {
                ChromiumPageHeader(browserManager: browserManager, model: window,
                    height: headerHeight, content: AnyView(headerContent))
            }
    }

    private var paneledLayers: some View {
        hostedLayers
            .background {
                if window.isPortraitCaptureVisible, let page = browserManager.frontPage(in: window) {
                    ChromiumPagePanel(content: PortraitCaptureView(session: page)
                        .environmentObject(browserManager).environment(window).id(page.itemID))
                } else if window.isBoostPanelVisible {
                    ChromiumPagePanel(content: BoostOverlay(fillsWindow: false)
                        .environmentObject(browserManager).environment(window))
                }
            }
            .background {
                if browserManager.showDefaultBrowserPrompt, registry.activeWindowId == window.id {
                    ChromiumPagePanel(content: DefaultBrowserToast(onMakeDefault: { browserManager.setAsDefaultBrowser() },
                        onNotNow: { browserManager.dismissDefaultBrowserPrompt() }))
                }
            }
            .background {
                if window.isExtensionLibraryVisible {
                    ChromiumPagePanel(content: ChromiumSiteControls(browserManager: browserManager, window: window,
                        settings: storage.settings, anchor: siteControlsAnchor).defaultAppStorage(storage.defaults), fill: .window)
                }
            }
            .background {
                if browserManager.dialogManager.isVisible {
                    ChromiumPagePanel(content: DialogView()
                        .environmentObject(browserManager)
                        .environmentObject(browserManager.gradientColorManager)
                        .environment(browserManager.tabs)
                        .environment(storage.settings)
                        .environment(\.nookSettings, storage.settings)
                        .environment(\.tabActions, browserManager)
                        .environment(window)
                        .defaultAppStorage(storage.defaults)
                        .onAppear { dialogFocus.take(in: window.window) }
                        .onDisappear { dialogFocus.giveBack(orFocusPage: focusShownPage) }, fill: .window)
                }
            }
            .background {
                ChromiumNoPagePanel(window: window, browserManager: browserManager, registry: registry,
                                    storage: storage, setPageHidden: setPageHidden)
            }
            .background {
                if window.tabSwitcher?.isPresented == true {
                    ChromiumPagePanel(content: TabSwitcherOverlay()
                        .environment(window)
                        .environment(browserManager.tabs)
                        .environment(\.peekedPage) { [peekManager = browserManager.peekManager, windowID = window.id] in
                            peekManager.page(tab: $0, window: windowID)
                        }, fill: .window)
                }
            }
    }

    var body: some View {
        paneledLayers
            .onChange(of: window.isBoostPanelVisible) { _, visible in
                if visible { window.isPortraitCaptureVisible = false }
            }
            .onChange(of: window.isPortraitCaptureVisible) { _, visible in
                if visible { window.isBoostPanelVisible = false }
            }
            .popover(isPresented: Binding(
                get: { browserManager.downloadManager.previewing != nil && browserManager.downloadManager.previewWindowID == window.id },
                set: { if !$0 { browserManager.downloadManager.dismissPreview(in: window) } }
            )) {
                if let download = browserManager.downloadManager.previewing,
                   browserManager.downloadManager.previewWindowID == window.id {
                    DownloadPreviewOverlay(downloads: browserManager.downloadManager, download: download, window: window)
                        .frame(width: min(900, max(1, window.window?.contentView?.bounds.width ?? 780)),
                               height: min(650, max(1, window.window?.contentView?.bounds.height ?? 540)))
                }
            }
            .onDisappear { browserManager.downloadManager.dismissPreview(in: window) }
            .onChange(of: window.spaceID) { _, _ in
                dismissPagePanels()
                browserManager.windowSpaceChanged(window)
            }
            .onChange(of: window.selectedItemID) { _, _ in
                dismissPagePanels()
                browserManager.peekManager.refreshNativePresentation(in: window)
            }
    }
    private var headerHeight: Int32 {
        if browserManager.showsDeveloperBar(in: window) { return Int32(DeveloperBar.height) }
        return browserManager.showsTopBar(in: window) ? Int32(TopBarMetrics.height) : 0
    }
    private var headerContent: some View {
        Group {
            if browserManager.showsDeveloperBar(in: window), let page = browserManager.frontPage(in: window) {
                DeveloperBar(session: page).id(page.itemID)
            } else if browserManager.showsTopBar(in: window) { TopBarView() }
        }
        .environmentObject(browserManager)
        .environmentObject(browserManager.gradientColorManager)
        .environmentObject(hover)
        .environment(browserManager.tabs)
        .environment(storage.settings)
        .environment(\.nookSettings, storage.settings)
        .environment(\.tabActions, browserManager)
        .environment(window).environment(registry).environment(commandPalette).environment(organizer)
        .environment(\.chromiumSiteControlsAnchor, siteControlsAnchor)
        .defaultAppStorage(storage.defaults)
    }

    private func dismissPagePanels() {
        window.isExtensionLibraryVisible = false
        window.isBoostPanelVisible = false
        window.isPortraitCaptureVisible = false
    }
    /// Existing displayed split slots plus a detached front page. Looking up a
    /// session never creates or loads a page; stable IDs keep both pane tasks
    /// mounted while the controllable pane changes.
    private var translationPages: [PageSession] {
        let ids = browserManager.splitManager.pageLayout(in: window)?.slots.compactMap { $0 }
            ?? window.selectedItemID.map { [$0] } ?? []
        var pages = ids.compactMap { browserManager.tabs.session(for: $0) }
            .filter { browserManager.tabs.isNativePageOwner($0, in: window) && $0.navigation != nil }
        if let front = browserManager.frontPage(in: window), front.navigation != nil,
           !pages.contains(where: { $0 === front }) { pages.append(front) }
        return pages
    }

}

/// The Organize Tabs shortcut and command bar row, for the window in front. A space the organizer
/// cannot sort says why.
private struct OrganizeTabsRequests: ViewModifier {
    let window: BrowserWindowState
    let registry: WindowRegistry
    let organizer: TabOrganizerManager
    let tabs: TabsController
    let notify: (String) -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .organizeTabsRequested)) { _ in
            guard registry.activeWindow?.id == window.id, let spaceID = window.spaceID else { return }
            Task { await organize(spaceID) }
        }
    }

    func organize(_ spaceID: UUID) async {
        await organizer.organizeTabs(in: spaceID, using: tabs)
        if let error = organizer.error { notify(error) }
    }
}

/// The sidebar's fill, the part of WindowView's window background this window has.
private struct ChromiumSpaceBackground: View {
    let chrome: ChromiumSpaceChrome
    let isActive: Bool

    var body: some View {
        let accent = chrome.tintsPrivate ? SpaceGradient.incognito.primaryColor
            : chrome.accentHex.map { SpaceGradient.accent(hex: $0).primaryColor } ?? SpaceGradient.default.primaryColor
        SpaceChromeBackground(theme: chrome.theme, accent: accent, isActive: isActive)
            .spaceThemeAppearance(chrome.theme)
            .overlay(chrome.tintsPrivate ? NookDesign.Surface.privateTint : Color.clear)
            .overlay(Rectangle().fill(NookDesign.Surface.agentGradient)
                .opacity(chrome.showsAgentGradient ? NookDesign.Surface.agentChromeOpacity : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .backgroundDraggable()
            .ignoresSafeArea()
            .animation(NookDesign.Motion.standard, value: isActive)
    }
}

/// A bounded sibling above Chromium's surface, like the existing address editor.
/// Only the panel receives input; no full-window overlay or second window.
private struct ChromiumPagePanel<Content: View>: NSViewRepresentable {
    enum Fill { case fitted, window, page }

    let content: Content
    var fill = Fill.fitted

    final class Anchor: NSView {
        var content: Content?
        var fill = Fill.fitted
        private var host: NSHostingView<AnyView>?
        private var resizeObserver: NSObjectProtocol?
        private var closeObserver: NSObjectProtocol?
        private weak var closedWindow: NSWindow?
        private var updating = false
        private var heightLimit: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            if let window {
                resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                    object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updatePanel() }
                    }
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                    object: window, queue: .main) { [weak self] note in
                        MainActor.assumeIsolated {
                            self?.closedWindow = note.object as? NSWindow
                            self?.removePanel()
                        }
                    }
            }
            updatePanel()
        }
        override func viewDidHide() { super.viewDidHide(); removePanel() }
        override func viewDidUnhide() { super.viewDidUnhide(); updatePanel() }
        override func layout() { super.layout(); updatePanel() }

        func updatePanel() {
            guard !updating, !isHiddenOrHasHiddenAncestor, let window, window !== closedWindow,
                  let root = window.contentView,
                  bounds.height > 0, let content else { return }
            updating = true
            defer { updating = false }
            let region = root.convert(bounds, from: self).intersection(root.bounds)
            let height = max(0, region.height - 24)
            guard height > 0 else { removePanel(); return }
            let view = fill == .fitted ? AnyView(content.frame(maxHeight: height, alignment: .top)) : AnyView(content)
            if host?.superview !== root { removePanel() }
            let panel: NSHostingView<AnyView>
            if let host {
                panel = host
                if heightLimit != height { panel.rootView = view }
            }
            else {
                panel = NSHostingView(rootView: view)
                panel.safeAreaRegions = []
                host = panel
                root.addSubview(panel, positioned: .above, relativeTo: nil)
            }
            heightLimit = height
            switch fill {
            case .window:
                panel.frame = root.bounds
                return
            case .page:
                // The anchor spans the sidebar, on whichever side it sits.
                let sidebarLeads = region.minX <= root.bounds.minX
                panel.frame = NSRect(x: sidebarLeads ? region.maxX : root.bounds.minX, y: root.bounds.minY,
                                     width: root.bounds.width - region.width, height: root.bounds.height)
                return
            case .fitted:
                break
            }
            let size = panel.fittingSize
            let width = min(size.width, max(0, root.bounds.width - 24))
            let panelHeight = min(size.height, height)
            let top = root.isFlipped ? region.minY + 12 : region.maxY - 12
            panel.frame = NSRect(x: root.bounds.maxX - width - 12,
                y: root.isFlipped ? top : top - panelHeight, width: width, height: panelHeight)
        }

        func removePanel() {
            host?.removeFromSuperview()
            host = nil
            heightLimit = nil
        }
        func setContent(_ content: Content) {
            self.content = content
            // SwiftUI updates replace content; AppKit layout only positions it.
            heightLimit = nil
            updatePanel()
        }
        func stop() {
            removePanel()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            resizeObserver = nil
            closeObserver = nil
        }
        isolated deinit { stop() }
    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor(); anchor.content = content; anchor.fill = fill; return anchor
    }
    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.setContent(content)
    }
    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.stop() }
}

/// Zero-size anchor only. Chromium owns the separate, inset header host; no
/// overlay covers its web surface and this root never retains the sidebar.
private struct ChromiumPageHeader: NSViewRepresentable {
    let browserManager: BrowserManager
    let model: BrowserWindowState
    let height: Int32
    let content: AnyView

    final class Anchor: NSView {
        weak var manager: BrowserManager?
        weak var model: BrowserWindowState?
        var height: Int32 = 0
        var host: NSHostingView<AnyView>?
        var installed = false
        private var updating = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateHeader() }
        override func layout() { super.layout(); updateHeader() }
        func updateHeader() {
            guard !updating, window != nil, let manager, let model,
                  let native = manager.tabs.nativePageHost as? ChromiumNativePageHost else { return }
            updating = true
            defer { updating = false }
            let next = height > 0 ? host : nil
            if native.setPageHeader(next, replacing: installed ? host : nil, height: height, in: model) {
                installed = next != nil
            }
        }
        func stop() {
            if installed, let manager, let model,
               let native = manager.tabs.nativePageHost as? ChromiumNativePageHost {
                _ = native.setPageHeader(nil, replacing: host, height: 0, in: model)
            }
            installed = false
            manager = nil; model = nil
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.manager = browserManager; anchor.model = model; anchor.height = height
        if let host = anchor.host { host.rootView = content }
        else if height > 0 {
            let host = NSHostingView(rootView: content)
            host.safeAreaRegions = []
            anchor.host = host
        }
        anchor.updateHeader()
    }
    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.stop() }
}

/// What the page area shows when the window shows no page of its own: an empty space, or a page
/// another window holds. Page commands then do nothing, and once no other window shows the
/// selected page this window shows it. Kept apart from the shell, whose body need not follow
/// which window holds each page.
private struct ChromiumNoPagePanel: View {
    let window: BrowserWindowState
    let browserManager: BrowserManager
    let registry: WindowRegistry
    let storage: ChromiumAppStorage
    let setPageHidden: (Bool) -> Void

    var body: some View {
        let tabs = browserManager.tabs
        let elsewhere = tabs.showsPageElsewhere(in: window)
        Color.clear
            .overlay {
                if window.showsNativeEmptySpace {
                    ChromiumPagePanel(content: EmptyWebsiteView()
                        .environmentObject(browserManager.gradientColorManager)
                        .environment(window)
                        .environment(registry)
                        .environment(tabs)
                        .environment(storage.settings)
                        .environment(\.nookSettings, storage.settings)
                        .environment(\.tabActions, browserManager)
                        .defaultAppStorage(storage.defaults)
                        .onAppear { window.window?.makeFirstResponder(nil) }, fill: .page)
                } else if elsewhere, let page = tabs.selectedSession(in: window) {
                    let item = page.itemID
                    ChromiumPagePanel(content: PageElsewhereView(title: page.title,
                        onShowHere: { [window] in tabs.takeControl(item, in: window) },
                        onGoToWindow: { tabs.showOwnerWindow(of: item) })
                        .onAppear { window.window?.makeFirstResponder(nil) }, fill: .page)
                }
            }
            .onChange(of: window.showsNativeEmptySpace || elsewhere, initial: true) { _, hidden in
                setPageHidden(hidden)
            }
            .onChange(of: elsewhere) { wasElsewhere, _ in
                if wasElsewhere { tabs.showSelectedPageHere(in: window) }
            }
    }
}
