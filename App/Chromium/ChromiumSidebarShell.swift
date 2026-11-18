import NookDesign
import NookTabsCore
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
    @State private var extensionActions = ChromiumExtensionActions()
    @State private var titleBand = SidebarTitleBand.design
    @Environment(\.colorScheme) private var baseColorScheme

    private func focusShownPage() {
        guard !window.nativePresentationIsPreparing, let page = browserManager.frontPage(in: window),
              let native = page.navigation as? ChromiumPageNavigation,
              browserManager.tabs.nativePageHost?.isNativeSelection(native, in: window) == true else { return }
        _ = native.selectNativePage()
    }

    private func refreshExtensionActions() {
        guard let host = browserManager.tabs.nativePageHost as? ChromiumNativePageHost,
              let page = browserManager.frontPage(in: window),
              let navigation = page.navigation as? ChromiumPageNavigation else {
            extensionActions.refresh(nil)
            return
        }
        let target = host.extensionActionTarget(for: navigation, in: window) { [weak browserManager, weak window, weak page] in
            guard let browserManager, let window, let page else { return false }
            return browserManager.frontPage(in: window) === page
        }
        extensionActions.refresh(target)
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
                .frame(maxWidth: ChromiumWindowRoot.Arc.sidebarWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ChromiumSidebarFade(outOfWindow: hostedSidebar == .hidden))
                .environment(\.sidebarOutOfWindow, hostedSidebar == .hidden)
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
            ChromiumLibraryColumn(theme: spaceChrome.theme)
            if window.isSidebarAIChatVisible {
                SidebarAIChat()
                    .environment(aiService)
                    .environment(storage.aiConfig)
                    .background(Color(nsColor: .windowBackgroundColor))
                    // The traffic lights and the sidebar's title row stay reachable above the chat.
                    .padding(.top, storage.settings.sidebarPosition == .left ? NookDesign.Spacing.sidebarTop : 0)
                    .modifier(ChromiumSidebarFade(outOfWindow: hostedSidebar == .hidden))
            }
            if let offer = browserManager.autofillManager.saveOffer,
               let view = offer.view, let owner = offer.window, view.window === owner, !view.isHiddenOrHasHiddenAncestor,
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
            .overlayPreferenceValue(FavoritePreviewAnchorKey.self) {
                ChromiumFavoriteCard(anchor: $0, window: window, tabs: browserManager.tabs)
            }
            .overlayPreferenceValue(DownloadsButtonAnchorKey.self) { anchor in
                ChromiumDownloadsButtonSpot(anchor: window.isSidebarAIChatVisible ? nil : anchor)
            }
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
            .environment(\.chromiumExtensionActions, extensionActions)
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
                    let siteControls = ChromiumSiteControls(browserManager: browserManager, window: window,
                        settings: storage.settings, anchor: siteControlsAnchor)
                    ChromiumPagePanel(content: siteControls.defaultAppStorage(storage.defaults)
                        .environment(\.chromiumExtensionActions, extensionActions), fill: .window,
                                      windowInput: siteControls.windowInput)
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

    /// Where the host-mode root puts this sidebar: beside the page, out of the window, or floating
    /// over the page while the pointer is at the window's leading edge.
    private var hostedSidebar: ChromiumWindowRoot.Sidebar {
        if window.isSidebarVisible { return .shown }
        return hover.isOverlayVisible && registry.activeWindowId == window.id ? .revealed : .hidden
    }

    var body: some View {
        let sidebar = hostedSidebar
        let backdrop = AnyView(ChromiumSpaceBackground(chrome: spaceChrome, isActive: registry.activeWindowId == window.id)
            .environment(\.nookSettings, storage.settings))
        let layout = browserManager.splitManager.pageLayout(in: window)
        ChromiumLibraryPush(window: window, link: { [window, hover] library, open in
            ChromiumWindowRootLink(sidebar: sidebar, hover: hover, backdrop: backdrop, split: splitLink(layout), flights: { [window] root in
                    AnyView(DownloadFlightOverlay(target: .path { [weak root] download in
                        root?.downloadFlight(from: download.launchPoint, startedIn: download.sourceWindow)
                    }).environment(window))
                }, library: library, libraryOpen: open,
                closeLibrary: { LibraryMotion.close(window) },
                extensionActionsChanged: { Task { @MainActor in refreshExtensionActions() } },
                swipeChanged: { window.libraryDrag = max($0, 0) },
                swipeEnded: { LibraryMotion.release(window, distance: $0, velocity: $1, width: $2) })
        }) {
            paneledLayers
        }
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
        .onAppear { refreshExtensionActions() }
        .onDisappear {
            browserManager.downloadManager.dismissPreview(in: window)
            extensionActions.refresh(nil)
        }
        .onChange(of: registry.activeWindowId) { _, _ in refreshExtensionActions() }
        .onChange(of: window.nativePresentationIsPreparing) { _, _ in refreshExtensionActions() }
        .onChange(of: browserManager.frontPage(in: window)?.itemID) { _, _ in refreshExtensionActions() }
        .onChange(of: browserManager.frontPage(in: window)?.url) { _, _ in refreshExtensionActions() }
        .onChange(of: window.isExtensionLibraryVisible) { _, visible in
            if visible { refreshExtensionActions() }
        }
        .onChange(of: browserManager.showsTopBar(in: window)) { _, _ in
            window.isExtensionLibraryVisible = false
            siteControlsAnchor.source = .address
        }
        .onChange(of: window.spaceID) { _, _ in
            dismissPagePanels()
            browserManager.windowSpaceChanged(window)
            refreshExtensionActions()
        }
        .onChange(of: window.selectedItemID) { _, _ in
            dismissPagePanels()
            browserManager.peekManager.refreshNativePresentation(in: window)
            refreshExtensionActions()
        }
    }
    /// The model's split for the Bark window's root: the panes it shows, its divider drags, and Add
    /// Split View's empty pane.
    private func splitLink(_ layout: SplitViewManager.PageLayout?) -> ChromiumWindowRootLink.SplitLink {
        ChromiumWindowRootLink.SplitLink(show: { [browserManager, window] in
            (browserManager.tabs.nativePageHost as? ChromiumNativePageHost)?.showModelSplit(
                layout?.slots, vertical: layout?.vertical ?? false, dividers: layout?.dividers ?? [], focused: window.selectedItemID,
                page: { browserManager.tabs.session(for: $0)?.navigation as? ChromiumPageNavigation }, in: window)
        }, moveDivider: { [browserManager, window] index, position, length in
            browserManager.splitManager.moveDivider(index, to: position, length: length, in: window)
        }, dividerReleased: { [browserManager, window] in
            browserManager.splitManager.dividerMoveEnded(in: window)
        }, emptyPane: { [browserManager] in
            let index = layout?.slots.firstIndex(of: nil) ?? 0
            return EmptySplitPaneView(frame: .zero, position: SplitPanePosition(index: index, count: layout?.slots.count ?? 2,
                                                                                vertical: layout?.vertical ?? false),
                                      settings: browserManager.nookSettings)
        })
    }

    private var headerHeight: Int32 {
        let toolbarHeight = browserManager.showsTopBar(in: window) ? TopBarMetrics.height : 0
        let developerHeight = browserManager.showsDeveloperBar(in: window) ? DeveloperBar.height : 0
        return Int32(toolbarHeight + developerHeight)
    }
    private var headerContent: some View {
        let showsToolbar = browserManager.showsTopBar(in: window)
        return VStack(spacing: 0) {
            if showsToolbar { TopBarView() }
            if browserManager.showsDeveloperBar(in: window), let page = browserManager.frontPage(in: window) {
                DeveloperBar(session: page, showsAddress: !showsToolbar).id(page.itemID)
            }
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
        .environment(\.chromiumExtensionActions, extensionActions)
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

/// How far the window's Library is out, read here alone so a swipe re-renders this and not the
/// shell.
private struct ChromiumLibraryPush<Content: View>: View {
    let window: BrowserWindowState
    let link: (ChromiumWindowRoot.Library, Bool) -> ChromiumWindowRootLink
    @ViewBuilder let content: Content

    var body: some View {
        let tab = window.sidebarMenuSelectedTab
        let width = LibraryMotion.width(for: tab, windowWidth: window.window?.contentView?.bounds.width ?? .greatestFiniteMagnitude)
        let open = window.isSidebarMenuVisible
        content.modifier(ChromiumLibraryProgress(progress: width > 0 ? LibraryMotion.shown(window, width: width) / width : 0) {
            link(ChromiumWindowRoot.Library(preferredWidth: LibraryMotion.preferredWidth(for: tab), progress: $0), open)
        })
    }
}

/// Steps the Library's progress frame by frame while it springs open or shut, so the host root lays
/// the column and the page out at every step and the sidebar fades with it.
private struct ChromiumLibraryProgress: ViewModifier, Animatable {
    var progress: CGFloat
    let link: (CGFloat) -> ChromiumWindowRootLink

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.libraryProgress, min(progress, 1))
            .background(link(progress))
    }
}

/// The sidebar, or the AI Assistant in its place, giving way to the Library. A hidden sidebar stays
/// out of sight while the Library comes in through its column.
private struct ChromiumSidebarFade: ViewModifier {
    @Environment(\.libraryProgress) private var progress
    let outOfWindow: Bool

    func body(content: Content) -> some View {
        content
            .modifier(LibraryFade())
            .opacity(outOfWindow && progress > 0 ? 0 : 1)
    }
}

/// The Library in the sidebar's column, fading in as it comes out.
private struct ChromiumLibraryColumn: View {
    @Environment(\.libraryProgress) private var progress
    let theme: SpaceTheme?

    var body: some View {
        if progress > 0 {
            SidebarMenu()
                .spaceThemeAppearance(theme)
                .opacity(min(1, progress * 2))
        }
    }
}

/// Gives the host-mode root view around the sidebar its state, the Library's and the space's
/// background, and starts the leading-edge tracking that reveals a hidden sidebar. In Chromium's own
/// window there is no such root and it does nothing.
private struct ChromiumWindowRootLink: NSViewRepresentable {
    let sidebar: ChromiumWindowRoot.Sidebar
    let hover: HoverSidebarManager
    let backdrop: AnyView
    let split: SplitLink
    /// A starting download's flight over the whole window, made once for the root it goes in.
    let flights: (ChromiumWindowRoot) -> AnyView
    let library: ChromiumWindowRoot.Library
    /// While the Library is open a sideways swipe anywhere in the window pushes it shut.
    let libraryOpen: Bool
    let closeLibrary: () -> Void
    let extensionActionsChanged: () -> Void
    let swipeChanged: (CGFloat) -> Void
    /// The swipe's distance and velocity, and the Library's width it was measured against.
    let swipeEnded: (CGFloat, CGFloat, CGFloat) -> Void

    struct SplitLink {
        var show: () -> Void
        var moveDivider: (Int, CGFloat, CGFloat) -> Void
        var dividerReleased: () -> Void
        var emptyPane: () -> NSView
    }

    final class Link: NSView {
        var sidebar = ChromiumWindowRoot.Sidebar.shown
        var split: SplitLink?
        weak var hover: HoverSidebarManager?
        var backdrop: AnyView?
        var flights: ((ChromiumWindowRoot) -> AnyView)?
        var library = ChromiumWindowRoot.Library.shut
        var libraryOpen = false
        var closeLibrary: () -> Void = {}
        var extensionActionsChanged: () -> Void = {}
        var swipeChanged: (CGFloat) -> Void = { _ in }
        var swipeEnded: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }
        private var backdropHost: NSHostingView<AnyView>?
        private var flightsHost: NSHostingView<AnyView>?
        private let swipeSurface = LibrarySwipeSurfaceView()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            extensionActionsChanged()
        }
        func apply() {
            var ancestor = superview
            while let view = ancestor, !(view is ChromiumWindowRoot) { ancestor = view.superview }
            guard let root = ancestor as? ChromiumWindowRoot else { return }
            root.extensionActionsChanged = { [weak self] in self?.extensionActionsChanged() }
            hover?.start()
            if let backdrop {
                if let backdropHost { backdropHost.rootView = backdrop } else {
                    let host = NSHostingView(rootView: backdrop)
                    host.safeAreaRegions = []
                    backdropHost = host
                }
            }
            if let backdropHost { root.setBackdrop(backdropHost) }
            if flightsHost == nil, let flights {
                let host = NSHostingView(rootView: flights(root))
                host.safeAreaRegions = []
                flightsHost = host
            }
            if let flightsHost { root.setOverlay(flightsHost) }
            if let split {
                root.dividerMoved = split.moveDivider
                root.dividerReleased = split.dividerReleased
                root.makeEmptyPane = split.emptyPane
                split.show()
            }
            root.sidebarWidth = ChromiumWindowRoot.Arc.sidebarWidth
            root.library = library
            root.sidebar = sidebar
            root.dismissLibrary = closeLibrary
            let width = root.libraryWidth
            swipeSurface.width = width
            swipeSurface.onChange = swipeChanged
            swipeSurface.onEnd = { [swipeEnded] in swipeEnded($0, $1, width) }
            swipeSurface.isHidden = !libraryOpen
            root.setLibrarySwipeSurface(swipeSurface)
        }
    }

    func makeNSView(context: Context) -> Link { Link() }
    func updateNSView(_ link: Link, context: Context) {
        link.hover = hover
        link.sidebar = sidebar
        link.backdrop = backdrop
        link.split = split
        link.flights = flights
        link.library = library
        link.libraryOpen = libraryOpen
        link.closeLibrary = closeLibrary
        link.extensionActionsChanged = extensionActionsChanged
        link.swipeChanged = swipeChanged
        link.swipeEnded = swipeEnded
        link.apply()
    }
}

/// Where the sidebar's downloads button is, for the host-mode root: a starting download flies to
/// it over the page, in a view tree apart from the sidebar's.
private struct ChromiumDownloadsButtonSpot: View {
    let anchor: Anchor<CGRect>?

    var body: some View {
        GeometryReader { proxy in
            if let anchor {
                let button = proxy[anchor]
                Spot().frame(width: button.width, height: button.height).position(x: button.midX, y: button.midY)
            }
        }
        .allowsHitTesting(false)
    }

    private struct Spot: NSViewRepresentable {
        final class Marker: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                var ancestor = superview
                while let view = ancestor, !(view is ChromiumWindowRoot) { ancestor = view.superview }
                (ancestor as? ChromiumWindowRoot)?.downloadsButton = self
            }
        }
        func makeNSView(context: Context) -> Marker { Marker() }
        func updateNSView(_ marker: Marker, context: Context) {}
    }
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
