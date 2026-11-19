import AppKit
import BarcChromium

/// One Bark window's root view (the app's default window). Chromium shows it as the window's
/// whole content, and the app lays out the sidebar, the page frame and the selected tab's page
/// view in it. A page is visible only while its view is in the window.
@MainActor
final class ChromiumWindowRoot: NSView {
    /// Arc's window at 1x, read from `build/arc-reference/`.
    enum Arc {
        /// The first light centred at (20, 24); with the revealed sidebar, at (25, 28.5).
        static let lights = Lights(titlebarHeight: 48, leadingInset: 13)
        static let revealedLights = Lights(titlebarHeight: 57, leadingInset: 18)
        /// With the Library out, at (23, 28).
        static let libraryLights = Lights(titlebarHeight: 56, leadingInset: 16)
        static let sidebarWidth: CGFloat = 247
        static let pageMargin: CGFloat = 10
        static let pageCornerRadius: CGFloat = 7
        static let revealMargin: CGFloat = 5
        /// Between two panes of a split, where the window's backdrop shows.
        static let splitGap: CGFloat = 10
        /// The Peek card's page, rounded at its bottom corners.
        static let peekCornerRadius: CGFloat = 16
        static let revealCornerRadius: CGFloat = 10
    }

    struct Lights: Equatable {
        var titlebarHeight: Double
        var leadingInset: Double
    }

    enum Sidebar: Equatable { case shown, hidden, revealed }

    /// The Library (History, Spaces, Downloads), which comes out in the sidebar's column.
    struct Library: Equatable {
        /// The width its page asks for; the window's width limits it.
        var preferredWidth: CGFloat
        /// How far out it is: 0 shut, 1 open, past 1 while a swipe pulls it further.
        var progress: CGFloat

        static let shut = Library(preferredWidth: 0, progress: 0)

        nonisolated func width(in windowWidth: CGFloat) -> CGFloat {
            CGFloat(LibrarySwipeDecision.width(preferred: Double(preferredWidth), windowWidth: Double(windowWidth)))
        }
    }

    struct Layout: Equatable {
        /// Nil while the sidebar is out of the window.
        var sidebar: CGRect?
        var page: CGRect
        var pageCornerRadius: CGFloat
        var sidebarCornerRadius: CGFloat = 0
    }

    struct LightsPlacement: Equatable {
        /// Nil hides them.
        var lights: Lights?
        var alpha: CGFloat
    }

    /// Where the lights sit and how strongly they show. As in Arc, they fade out where they are over
    /// the first half of the Library's pull and back in with the Library over the second.
    nonisolated static func lights(for sidebar: Sidebar, library progress: CGFloat) -> LightsPlacement {
        let out = min(max(progress, 0), 1)
        if out >= 0.5 { return LightsPlacement(lights: Arc.libraryLights, alpha: 2 * out - 1) }
        let lights = lights(for: sidebar)
        return LightsPlacement(lights: lights, alpha: lights == nil ? 1 : 1 - 2 * out)
    }

    /// Where the sidebar's column and the page frame go in `bounds`, with a top-left origin. The page
    /// frame keeps its place when the hidden sidebar floats in over it. The Library comes out in the
    /// column and pushes the page to the Library's edge beside a shown sidebar, and by the Library's
    /// whole width otherwise.
    nonisolated static func layout(in bounds: CGRect, sidebar: Sidebar, sidebarWidth: CGFloat = Arc.sidebarWidth,
                                   library: Library = .shut, pageFullscreen: Bool) -> Layout {
        if pageFullscreen { return Layout(sidebar: nil, page: bounds, pageCornerRadius: 0) }
        let margin = Arc.pageMargin
        let height = max(0, bounds.height - 2 * margin)
        let progress = max(library.progress, 0)
        let libraryWidth = library.width(in: bounds.width)
        let out = progress * libraryWidth
        switch sidebar {
        case .shown:
            let rest = min(sidebarWidth, bounds.width)
            let width = min(bounds.width, rest + max(0, out - rest * progress))
            return Layout(sidebar: CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height),
                          page: CGRect(x: bounds.minX + width, y: bounds.minY + margin,
                                       width: max(0, bounds.width - width - margin), height: height),
                          pageCornerRadius: Arc.pageCornerRadius)
        case .hidden, .revealed:
            let page = CGRect(x: bounds.minX + margin + out, y: bounds.minY + margin,
                              width: max(0, bounds.width - 2 * margin - out), height: height)
            let inset = Arc.revealMargin
            let floating = CGRect(x: bounds.minX + inset, y: bounds.minY + inset,
                                  width: min(sidebarWidth, max(0, bounds.width - 2 * inset)), height: max(0, bounds.height - 2 * inset))
            if out == 0 {
                return sidebar == .revealed
                    ? Layout(sidebar: floating, page: page, pageCornerRadius: Arc.pageCornerRadius, sidebarCornerRadius: Arc.revealCornerRadius)
                    : Layout(sidebar: nil, page: page, pageCornerRadius: Arc.pageCornerRadius)
            }
            if sidebar == .hidden {
                let width = max(libraryWidth, out)
                return Layout(sidebar: CGRect(x: bounds.minX + out - width, y: bounds.minY, width: width, height: bounds.height),
                              page: page, pageCornerRadius: Arc.pageCornerRadius)
            }
            let settled = min(progress, 1)
            let lead = inset * (1 - settled)
            return Layout(sidebar: CGRect(x: bounds.minX + lead, y: bounds.minY + lead,
                                          width: floating.width + progress * (libraryWidth - floating.width),
                                          height: max(0, bounds.height - 2 * lead)),
                          page: page, pageCornerRadius: Arc.pageCornerRadius, sidebarCornerRadius: Arc.revealCornerRadius * (1 - settled))
        }
    }

    /// Where the window's lights sit beside the sidebar; nil hides them, as Arc does with its sidebar.
    nonisolated static func lights(for sidebar: Sidebar) -> Lights? {
        switch sidebar {
        case .shown: Arc.lights
        case .revealed: Arc.revealedLights
        case .hidden: nil
        }
    }

    private let bridge: BarcBridge
    /// The client the window answers for: the engine's selected client, whose page has the keys.
    /// The window's own calls go through it, since the first client may close before the others.
    private(set) var client: Int32
    /// The page with the keys: the one page shown, or the focused pane of a split.
    private(set) var shownTab: Int32 = 0
    /// One slot for one page, one per pane in a split, in the panes' order.
    private var slots: [Slot] = []
    private lazy var link = ChromiumWindowHostLink(bridge: bridge) { [weak self] in self?.handle($0) }
    private let pageFrame = Container()
    private let dividerLayer = ControlLayer()
    private let pagePanels = ControlLayer()
    private let libraryDismissal = LibraryDismissal()
    private let sidebarColumn = Container()
    private let overlayLayer = Overlay()
    private weak var overlay: NSView?
    private weak var librarySwipeSurface: NSView?
    private var placedLights: Lights?
    private weak var sidebarView: NSView?
    private weak var backdrop: NSView?
    private weak var header: NSView?
    private var headerHeight: CGFloat = 0
    private var crashedTabs: Set<Int32> = []
    private var peekCard: PeekCard?
    private var peekGeneration: UInt64 = 0
    private let peekLayer = PeekLayer()
    private let peekWash = PeekWash()
    /// Every page slot: the panes' and the Peek's.
    private var allSlots: [Slot] { slots + (peekCard.map { [$0.slot] } ?? []) }
    private var windowObservers: [NSObjectProtocol] = []
    private var startupSplitFocus: (pane: Pane, ready: Bool, isCurrent: () -> Bool)?
    private var startupInputMonitor: Any?
    private(set) var pageFullscreen = false

    var sidebar: Sidebar = .shown {
        didSet {
            guard sidebar != oldValue else { return }
            applyLayout()
            applyLights()
        }
    }

    /// The sidebar's column at rest.
    var sidebarWidth: CGFloat = Arc.sidebarWidth {
        didSet { if sidebarWidth != oldValue { applyLayout() } }
    }

    var library = Library.shut {
        didSet {
            guard library != oldValue else { return }
            applyLayout()
            applyLights(replacing: false)
        }
    }

    /// Puts the Library away; a click beside it while it is out calls this.
    var dismissLibrary: (() -> Void)? {
        get { libraryDismissal.dismiss }
        set { libraryDismissal.dismiss = newValue }
    }

    var libraryWidth: CGFloat { library.width(in: bounds.width) }

    /// The view that takes the open Library's sideways swipe, over the whole window. It decides
    /// which events it takes; the root only keeps it above the sidebar and the page.
    func setLibrarySwipeSurface(_ view: NSView) {
        guard view !== librarySwipeSurface else { return }
        librarySwipeSurface?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .above, relativeTo: sidebarColumn)
        librarySwipeSurface = view
    }

    /// The sidebar's downloads button, which a starting download flies into.
    weak var downloadsButton: NSView?

    /// Shows `view` over the sidebar and the page, without taking their clicks: a starting
    /// download's flight.
    func setOverlay(_ view: NSView) {
        guard view !== overlay else { return }
        overlay?.removeFromSuperview()
        view.frame = overlayLayer.bounds
        view.autoresizingMask = [.width, .height]
        overlayLayer.addSubview(view)
        overlay = view
    }

    /// Where a download that starts now flies from, in window coordinates: the pointer while it is
    /// over the page, which is where the click was, else the page's middle.
    func downloadLaunchPoint(pointer: NSPoint) -> NSPoint? {
        guard window != nil else { return nil }
        let page = pageFrame.convert(pageFrame.bounds, to: nil)
        return page.contains(pointer) ? pointer : NSPoint(x: page.midX, y: page.midY)
    }

    /// A starting download's flight in this view's coordinates, from `launch` in the window that
    /// started it to the middle of the downloads button. Nil for another window's download, and
    /// while the sidebar and its button are out of the window: hidden, or beside a full-screen page.
    func downloadFlight(from launch: NSPoint?, startedIn source: NSWindow?) -> (start: CGPoint, end: CGPoint)? {
        guard let window, source === window, let launch, sidebar != .hidden, !pageFullscreen,
              let button = downloadsButton, button.window === window else { return nil }
        let target = convert(button.bounds, from: button)
        return (convert(launch, from: nil), CGPoint(x: target.midX, y: target.midY))
    }

    /// A tab's page in a split, with the client that holds the tab: a window shows one client per profile.
    struct Pane: Equatable {
        var client: Int32
        var tab: Int32
    }

    /// A split as the window shows it.
    struct Split: Equatable {
        /// Leading to trailing, or top to bottom; nil is Add Split View's empty pane.
        var panes: [Pane?]
        var vertical: Bool
        /// Where each divider sits, as a fraction of the page area from its leading or top edge.
        var dividers: [CGFloat]
        /// The pane with the keys.
        var focused: Int32
    }

    /// The split shown; nil while one page fills the page frame.
    private(set) var split: Split?

    /// Called with a divider's index, its new place and the page area's length along the split
    /// while it is dragged; the caller answers with `showSplit`.
    var dividerMoved: ((Int, CGFloat, CGFloat) -> Void)?
    var dividerReleased: (() -> Void)?
    private let dividerRange: (Int, [CGFloat], CGFloat) -> ClosedRange<CGFloat>?
    /// What Add Split View's empty pane shows.
    var makeEmptyPane: () -> NSView = { NSView() }

    var splitDividers: [SplitDividerView] { dividerLayer.subviews.compactMap { $0 as? SplitDividerView } }

    /// Shows `split`'s panes, which may be of different clients. A page that stays a pane stays in the
    /// window, whatever moves; a page that leaves the split leaves the window. False, and nothing
    /// changes, when a pane's client has no page view for its tab or the split is not one.
    @discardableResult
    func showSplit(_ split: Split) -> Bool {
        let panes = split.panes.compactMap { $0 }
        guard (2...4).contains(split.panes.count), split.dividers.count + 1 == split.panes.count,
              zip([0] + split.dividers, split.dividers + [1]).allSatisfy({ $0 < $1 }),
              Set(panes.map(\.tab)).count == panes.count,
              let focused = panes.first(where: { $0.tab == split.focused }) else { return false }
        var views: [Int32: NSView] = [:]
        for pane in panes {
            guard let view = pageView(pane) else { return false }
            views[pane.tab] = view
        }
        var free = slots
        let next = split.panes.map { pane -> Slot in
            if let index = free.firstIndex(where: { $0.pane == pane }) { return free.remove(at: index) }
            return Slot(pane: pane, bridge: bridge)
        }
        let focusChanged = shownTab != split.focused || slots.first(where: { $0.pane?.tab == split.focused }) == nil
        self.split = split
        use(next)
        for slot in next {
            if let pane = slot.pane, let view = views[pane.tab] { place(view, in: slot) } else { slot.showEmpty(makeEmptyPane) }
        }
        shownTab = split.focused
        client = focused.client
        // A promoted page is already in its new slot, even when the source
        // keeps model focus. Retire the card without detaching that page.
        let retiredCard = peekCard.flatMap { card in
            card.peek.source != focused || views[card.peek.page.tab] != nil ? card : nil
        }
        if retiredCard != nil { removePeek() }
        layoutPageArea()
        if focusChanged || retiredCard != nil {
            focusPage(preferred: retiredCard?.peek.source == focused ? retiredCard?.sourceResponder : nil)
        }
        return true
    }

    /// A slot can outlive its native view, even while the tab IDs and layout match.
    func showsSplit(_ expected: Split) -> Bool {
        guard split == expected, slots.count == expected.panes.count else { return false }
        return zip(slots, expected.panes).allSatisfy { slot, pane in
            guard slot.pane == pane, slot.container.superview === pageFrame else { return false }
            return pane.map { slot.holds(bridge.tab_native_view($0.client, $0.tab)) } ?? true
        }
    }

    /// Ends the split shown: the focused page fills the page frame, the others leave the window.
    @discardableResult
    func endSplit() -> Bool {
        guard split != nil else { return shownTab != 0 }
        split = nil
        return show(tab: shownTab, of: client)
    }

    func showsCrashedPage(tab: Int32) -> Bool {
        allSlots.contains { $0.pane?.tab == tab && !$0.crashed.isHidden }
    }

    /// The window shows no page of its own: an empty space, or a page another window holds.
    var pageHidden = false {
        didSet {
            guard pageHidden != oldValue else { return }
            allSlots.forEach { $0.heldView?.isHidden = pageHidden }
            if !pageHidden { focusPage() }
        }
    }

    /// The focused page; nil once another root took it.
    private var heldPage: NSView? { slots.first { $0.pane?.tab == shownTab }?.heldView }

    init(bridge: BarcBridge, client: Int32,
         dividerRange: @escaping (Int, [CGFloat], CGFloat) -> ClosedRange<CGFloat>? = { _, _, _ in nil }) {
        self.bridge = bridge
        self.client = client
        self.dividerRange = dividerRange
        super.init(frame: .zero)
        wantsLayer = true
        let frameDrag = WindowFrameInteractionView()
        frameDrag.autoresizingMask = [.width, .height]
        addSubview(frameDrag)
        pageFrame.wantsLayer = true
        pageFrame.layer?.masksToBounds = true
        pageFrame.autoresizingMask = [.width, .height]
        addSubview(pageFrame)
        pageFrame.addSubview(dividerLayer)
        pageFrame.addSubview(pagePanels)
        peekWash.onClick = { [weak self] in self?.peekCard?.dismiss() }
        peekLayer.addSubview(peekWash)
        libraryDismissal.isHidden = true
        addSubview(libraryDismissal)
        sidebarColumn.wantsLayer = true
        sidebarColumn.autoresizingMask = [.height]
        addSubview(sidebarColumn)
        overlayLayer.autoresizingMask = [.width, .height]
        addSubview(overlayLayer)
        applyLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        cancelStartupSplitFocus()
    }

    override var isFlipped: Bool { true }

    /// Gives this view to the window, places the window's lights and listens for its pages. The
    /// caller keeps the root alive while the window can still send events.
    func attach() -> Bool {
        guard link.attach(self, client: client) else { return false }
        applyLights()
        return true
    }

    /// What the window shows around the page frame and behind the sidebar: the space's own
    /// background, as Arc's window is.
    func setBackdrop(_ view: NSView) {
        guard view !== backdrop else { return }
        backdrop?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: nil)
        backdrop = view
    }

    /// The window's sidebar, shown in the sidebar column or floating over the page.
    func setSidebar(_ view: NSView) {
        guard view !== sidebarView else { return }
        sidebarView?.removeFromSuperview()
        view.frame = sidebarColumn.bounds
        view.autoresizingMask = [.width, .height]
        sidebarColumn.addSubview(view)
        sidebarView = view
    }

    func holdsSidebar(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return sidebarView === view && view.superview === sidebarColumn
    }

    /// Shows `owner`'s `tab`: as the focused pane when the split shown has it, else in place of what
    /// was shown before, the split's other pages leaving the window. False when `owner` has no page
    /// view for that tab.
    @discardableResult
    func show(tab: Int32, of owner: Int32, while isCurrent: () -> Bool = { true }) -> Bool {
        let pane = Pane(client: owner, tab: tab)
        if let split, split.panes.contains(pane) {
            guard let slot = slots.first(where: { $0.pane == pane }), let view = pageView(pane),
                  isCurrent(), self.split == split, slot.container.superview === pageFrame else { return false }
            let replaced = slot.heldView !== view
            let changed = shownTab != tab || replaced
            if replaced { place(view, in: slot) }
            self.split?.focused = tab
            shownTab = tab
            client = owner
            if let card = peekCard, card.peek.source != pane { removePeek() }
            if pageFullscreen { layoutPageArea() }
            if changed { focusPage() }
            return true
        }
        guard let view = pageView(pane), isCurrent() else { return false }
        let slot = slots.first { $0.pane == pane } ?? Slot(pane: pane, bridge: bridge)
        let changed = view !== slot.view || view.superview !== slot.container || slots.count != 1 || shownTab != tab
        split = nil
        use([slot])
        place(view, in: slot)
        shownTab = tab
        client = owner
        layoutPageArea()
        if changed { focusPage() }
        return true
    }

    func showsPage(tab: Int32, of owner: Int32) -> Bool {
        let pane = Pane(client: owner, tab: tab)
        guard client == owner, shownTab == tab,
              let slot = slots.first(where: { $0.pane == pane }),
              slot.container.superview === pageFrame else { return false }
        return slot.holds(bridge.tab_native_view(owner, tab))
    }

    private func pageView(_ pane: Pane) -> NSView? {
        bridge.tab_native_view(pane.client, pane.tab).map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Makes `next` the slots shown: a slot that goes takes its page out of the window.
    private func use(_ next: [Slot]) {
        for slot in slots where !next.contains(where: { $0 === slot }) {
            if slot.heldView != nil { slot.view?.removeFromSuperview() }
            slot.container.removeFromSuperview()
        }
        for slot in next where slot.container.superview !== pageFrame {
            pageFrame.addSubview(slot.container, positioned: .below, relativeTo: dividerLayer)
        }
        slots = next
        if let card = peekCard, !next.contains(where: { $0.pane == card.peek.source }) { removePeek() }
    }

    private func place(_ view: NSView, in slot: Slot) {
        slot.place(view, hidden: pageHidden, crashed: crashedTabs.contains(slot.pane?.tab ?? 0))
    }

    /// The optional bar above the page, inside the page frame. `expected` is the bar the caller
    /// installed before; a different one in place refuses the change.
    func setHeader(_ view: NSView?, replacing expected: NSView?, height: CGFloat) -> Bool {
        guard header === expected else { return false }
        if header !== view { header?.removeFromSuperview() }
        header = view
        headerHeight = view == nil ? 0 : max(0, height)
        if let view, view.superview !== pageFrame {
            view.autoresizingMask = [.width]
            pageFrame.addSubview(view, positioned: .below, relativeTo: dividerLayer)
        }
        layoutPageArea()
        return true
    }

    var showsCrashedPage: Bool { showsCrashedPage(tab: shownTab) }

    /// The bar's height in the page frame; a full-screen page has none above it.
    private var barHeight: CGFloat { pageFullscreen ? 0 : headerHeight }

    private var pageArea: CGRect {
        CGRect(x: 0, y: barHeight, width: pageFrame.bounds.width, height: max(0, pageFrame.bounds.height - barHeight))
    }

    var extensionActionsChanged: (() -> Void)?

    private func handle(_ change: ChromiumWindowHostChange) {
        switch change {
        case .pageRetired(let tab, let view):
            crashedTabs.remove(tab)
            pageRetired(view)
        case .fullscreen(let page, let selected):
            if selected > 0 { client = selected }
            guard page != pageFullscreen else { return }
            pageFullscreen = page
            applyLayout()
            applyLights()
        case .pageCrashed(let tab, let view):
            crashedTabs.insert(tab)
            for slot in allSlots where slot.pane?.tab == tab && slot.holds(view) { slot.crashed.isHidden = false }
        case .extensionActionsChanged:
            extensionActionsChanged?()
        case .pageRestored(let tab):
            crashedTabs.remove(tab)
            for slot in allSlots where slot.pane?.tab == tab { slot.crashed.isHidden = true }
        }
    }

    /// A retired page leaves the window; a tab that replaced its contents shows its new page. A
    /// pane whose page closed stays empty until the split changes.
    private func pageRetired(_ view: UnsafeMutableRawPointer?) {
        if let card = peekCard, let view, card.slot.view.map({ Unmanaged.passUnretained($0).toOpaque() }) == view {
            if card.slot.heldView != nil { card.slot.view?.removeFromSuperview() }
            card.slot.view = nil
            card.slot.crashed.isHidden = true
            guard let next = bridge.tab_native_view(card.peek.page.client, card.peek.page.tab), next != view else {
                hidePeek(generation: card.generation)
                return
            }
            place(Unmanaged<NSView>.fromOpaque(next).takeUnretainedValue(), in: card.slot)
            return
        }
        guard let view, let slot = slots.first(where: { $0.view.map { Unmanaged.passUnretained($0).toOpaque() } == view }),
              let pane = slot.pane else { return }
        if slot.heldView != nil { slot.view?.removeFromSuperview() }
        slot.view = nil
        slot.crashed.isHidden = true
        guard let next = bridge.tab_native_view(pane.client, pane.tab), next != view else {
            if split == nil { shownTab = 0 }
            return
        }
        if split == nil { show(tab: pane.tab, of: pane.client) } else { place(Unmanaged<NSView>.fromOpaque(next).takeUnretainedValue(), in: slot) }
    }

    /// Keys go to the page shown, unless the person is typing in a field outside it.
    private func focusPage(preferred: NSView? = nil) {
        guard let window, let page = peekCard?.slot.heldView ?? heldPage, !pageHidden else { return }
        if let editor = window.firstResponder as? NSText, !editor.isDescendant(of: pageFrame) { return }
        if let preferred, preferred.window === window, preferred.isDescendant(of: page),
           window.makeFirstResponder(preferred) { return }
        guard let target = page.subviews.first(where: \.acceptsFirstResponder) ?? (page.acceptsFirstResponder ? page : nil)
        else { return }
        window.makeFirstResponder(target)
    }

    /// Transfers focus only to the live renderer of the exact presented pane.
    @discardableResult
    func focusPresentedPage(tab: Int32, of owner: Int32, replacing: (NSResponder?) -> Bool) -> Bool {
        guard showsPage(tab: tab, of: owner), !pageHidden, peekCard == nil,
              let window, window.isKeyWindow, NSApp.isActive,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              let page = heldPage, page.window === window, !page.isHiddenOrHasHiddenAncestor,
              let target = page.subviews.first(where: {
                  $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.acceptsFirstResponder
              }) else { return false }
        if window.firstResponder === target { return true }
        guard replacing(window.firstResponder), window.makeFirstResponder(target) else { return false }
        return window.firstResponder === target
    }

    /// On initial presentation AppKit can select the divider as the first key
    /// view before the saved page's renderer is ready. Any input ends this
    /// startup-only intent before a user-selected divider/control is touched.
    func beginStartupSplitFocus(_ pane: Pane, ready: Bool, isCurrent: @escaping () -> Bool) {
        cancelStartupSplitFocus()
        startupSplitFocus = (pane, ready, isCurrent)
        startupInputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.cancelStartupSplitFocus() }
            return event
        }
    }

    func startupSplitRendererReady(_ pane: Pane) {
        guard startupSplitFocus?.pane == pane else { return }
        startupSplitFocus?.ready = true
        restoreStartupSplitFocusIfReady()
    }

    func cancelStartupSplitFocus() {
        startupSplitFocus = nil
        if let startupInputMonitor { NSEvent.removeMonitor(startupInputMonitor) }
        startupInputMonitor = nil
    }

    func restoreStartupSplitFocusIfReady() {
        guard let pending = startupSplitFocus, pending.ready, let window, window.isKeyWindow else { return }
        guard pending.isCurrent(), split != nil, !pageHidden, peekCard == nil,
              window.attachedSheet == nil, NSApp.modalWindow == nil else {
            cancelStartupSplitFocus()
            return
        }
        let responder = window.firstResponder
        let isAutomatic = responder == nil || responder === window || responder === window.contentView ||
            splitDividers.contains { $0 === responder }
        if focusPresentedPage(tab: pending.pane.tab, of: pending.pane.client, replacing: { _ in isAutomatic }) ||
            !isAutomatic {
            cancelStartupSplitFocus()
        }
    }

    private func applyLayout() {
        let layout = Self.layout(in: bounds, sidebar: sidebar, sidebarWidth: sidebarWidth, library: library, pageFullscreen: pageFullscreen)
        pageFrame.frame = layout.page
        pageFrame.layer?.cornerRadius = layout.pageCornerRadius
        sidebarColumn.frame = layout.sidebar ?? waitingSidebarFrame
        sidebarView?.frame = sidebarColumn.bounds
        sidebarColumn.layer?.cornerRadius = layout.sidebarCornerRadius
        sidebarColumn.layer?.masksToBounds = layout.sidebarCornerRadius > 0
        let besideLibrary = layout.sidebar?.maxX ?? bounds.minX
        libraryDismissal.isHidden = pageFullscreen || library.progress <= 0
        libraryDismissal.frame = CGRect(x: besideLibrary, y: bounds.minY, width: max(0, bounds.maxX - besideLibrary), height: bounds.height)
        overlayLayer.frame = bounds
        layoutPageArea()
    }

    /// Beside the window's leading edge, where a hidden sidebar waits for the pointer.
    private var waitingSidebarFrame: CGRect {
        CGRect(x: bounds.minX - sidebarWidth - Arc.revealMargin, y: bounds.minY, width: sidebarWidth, height: bounds.height)
    }

    private func layoutPageArea() {
        let area = pageArea
        pagePanels.frame = area
        header?.isHidden = pageFullscreen
        header?.frame = CGRect(x: 0, y: 0, width: pageFrame.bounds.width, height: barHeight)
        let panes = split.map { split in
            SplitDrop.paneFrames(in: area, count: split.panes.count, vertical: split.vertical, dividers: split.dividers, gap: Arc.splitGap)
        }
        var washFrame = area
        for (index, slot) in slots.enumerated() {
            let paneFrame = pageFullscreen ? nil : panes.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            let frame = paneFrame ?? area
            slot.container.isHidden = pageFullscreen && panes != nil && slot.pane?.tab != shownTab
            // Update the frame and logical viewport together before sizing the renderer.
            slot.container.autoresizesSubviews = false
            if let card = peekCard, slot.pane == card.peek.source, paneFrame != nil {
                washFrame = frame
                slot.container.frame = frame.insetBy(dx: min(9, frame.width / 8), dy: min(10, frame.height / 8))
            } else {
                slot.container.frame = frame
            }
            // Keep the document viewport stable while its pane is inset behind a Peek.
            slot.container.bounds.size = frame.size
            slot.container.autoresizesSubviews = true
            slot.container.autoresizingMask = panes == nil ? [.width, .height] : []
            slot.container.layer?.cornerRadius = paneFrame == nil ? 0 : Arc.pageCornerRadius
            slot.fillContainer()
        }
        layoutDividers(panes.flatMap { pageFullscreen || split?.panes.contains(nil) == true ? nil : $0 } ?? [], in: area)
        layoutPeek(in: area, washFrame: washFrame)
    }

    var canResizeSplit: Bool {
        !pageHidden && !pageFullscreen && dividerMoved != nil && splitDividers.first?.acceptsFirstResponder == true
    }

    func focusSplitDivider() {
        guard canResizeSplit, let divider = splitDividers.first else { return }
        window?.makeFirstResponder(divider)
    }

    private func focusAdjacentDivider(to index: Int, backwards: Bool) {
        let dividers = splitDividers
        let next = index + (backwards ? -1 : 1)
        if dividers.indices.contains(next) {
            window?.makeFirstResponder(dividers[next])
        } else {
            focusPage()
        }
    }

    /// One divider in each gap between two panes, the gap itself being where it is dragged.
    private func layoutDividers(_ panes: [CGRect], in area: CGRect) {
        dividerLayer.frame = area
        let vertical = split?.vertical ?? false
        let gaps = zip(panes, panes.dropFirst()).map { before, after in
            vertical ? CGRect(x: area.minX, y: before.maxY, width: area.width, height: after.minY - before.maxY)
                     : CGRect(x: before.maxX, y: area.minY, width: after.minX - before.maxX, height: area.height)
        }
        var dividers = splitDividers
        var removedFocus = false
        while dividers.count > gaps.count {
            let divider = dividers.removeLast()
            removedFocus = removedFocus || window?.firstResponder === divider
            divider.removeFromSuperview()
        }
        if removedFocus { focusPage() }
        while dividers.count < gaps.count {
            let divider = SplitDividerView()
            dividerLayer.addSubview(divider)
            dividers.append(divider)
        }
        guard !dividers.isEmpty, let split else { return }
        let length = vertical ? area.height : area.width
        for (index, divider) in dividers.enumerated() {
            divider.frame = dividerLayer.convert(gaps[index], from: pageFrame)
            divider.vertical = vertical
            divider.position = split.dividers[index]
            divider.onResize = { [weak self] position, length in self?.dividerMoved?(index, position, length) }
            divider.onResizeEnded = { [weak self] in self?.dividerReleased?() }
            divider.onLeave = { [weak self] in self?.focusPage() }
            divider.onTab = { [weak self] backwards in self?.focusAdjacentDivider(to: index, backwards: backwards) }
            if let range = dividerRange(index, split.dividers, length) {
                divider.configureAccessibility(index: index, count: dividers.count, range: range)
            }
            divider.window?.invalidateCursorRects(for: divider)
        }
    }

    /// `replacing` places the lights even where they already are, which AppKit needs after it
    /// rebuilds the titlebar.
    private func applyLights(replacing: Bool = true) {
        guard link.isAttached else { return }
        let placement = pageFullscreen ? LightsPlacement(lights: nil, alpha: 1) : Self.lights(for: sidebar, library: library.progress)
        if let lights = placement.lights, replacing || lights != placedLights {
            var chrome = BarcWindowChrome(size: MemoryLayout<BarcWindowChrome>.size,
                                          titlebar_height: lights.titlebarHeight, leading_inset: lights.leadingInset)
            _ = bridge.window_set_chrome(client, &chrome)
            placedLights = lights
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window?.standardWindowButton(kind) else { continue }
            button.isHidden = placement.lights == nil
            button.alphaValue = placement.alpha
        }
    }

    override func layout() {
        super.layout()
        applyLayout()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        applyLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { cancelStartupSplitFocus(); return }
        // AppKit rebuilds the titlebar when the window leaves full screen.
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyLights() }
            })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restoreStartupSplitFocusIfReady() }
            })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restoreStartupSplitFocusIfReady() }
            })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelStartupSplitFocus() }
            })
        applyLights()
    }

    private final class Container: NSView {
        override var isFlipped: Bool { true }
    }

    private typealias Slot = ChromiumPageSlot

    /// Dividers and page panels use unflipped containers that only receive input on their children.
    private final class ControlLayer: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }

    private final class Overlay: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Beside the Library while it is out: a click there puts the Library away.
    private final class LibraryDismissal: NSView {
        var dismiss: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { dismiss?() }
    }
}

extension ChromiumWindowRoot: ChromiumPanelHost {
    func panelContainer(for fill: ChromiumPanelFill) -> NSView { fill == .window ? self : pagePanels }

    // MARK: - Peek

    /// A Peek: `page` shown in a card over the page area while `source`, a page the window shows,
    /// stays placed under the card's wash.
    struct Peek: Equatable {
        var source: Pane
        var page: Pane
    }

    /// The card stays centred across all panes.
    struct PeekLayout: Equatable {
        var header: CGRect
        var page: CGRect
        var actions: CGRect
    }

    nonisolated static func peekLayout(in size: CGSize) -> PeekLayout {
        let width = max(0, min((size.width * 0.82).rounded(.down), size.width - 88))
        let x = ((size.width - width) / 2).rounded(.down)
        let height = max(0, size.height - 16)
        return PeekLayout(header: CGRect(x: x, y: 8, width: width, height: min(32, height)),
                          page: CGRect(x: x, y: 40, width: width, height: max(0, height - 32)),
                          actions: CGRect(x: x + width + 8, y: 14, width: 28, height: max(0, min(96, height - 6))))
    }

    /// Shows `peek`'s page in the card with `header` above it and `actions` beside it; the page then
    /// has the keys. Returns the card's generation, or 0 when the window does not show the source or
    /// has no page view for the Peek. A click on the wash calls `dismiss`.
    @discardableResult
    func showPeek(_ peek: Peek, header: NSView, actions: NSView, dismiss: @escaping () -> Void) -> UInt64 {
        guard peek.page != peek.source, let source = slots.first(where: { $0.pane == peek.source })?.heldView,
              let view = pageView(peek.page), !slots.contains(where: { $0.heldView === view }) else { return 0 }
        removePeek()
        peekGeneration = peekGeneration == .max ? 1 : peekGeneration + 1
        let card = PeekCard(peek: peek, generation: peekGeneration, slot: Slot(pane: peek.page, bridge: bridge),
                            header: header, actions: actions, dismiss: dismiss)
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: source) {
            card.sourceResponder = responder
        }
        card.slot.container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        peekLayer.addSubview(card.slot.container)
        peekLayer.addSubview(header)
        peekLayer.addSubview(actions)
        peekCard = card
        place(view, in: card.slot)
        pageFrame.addSubview(peekLayer, positioned: .above, relativeTo: dividerLayer)
        layoutPageArea()
        focusPage()
        return card.generation
    }

    /// Takes the card of `generation` down, its page leaving the window; the keys go back to the page
    /// shown under it.
    @discardableResult
    func hidePeek(generation: UInt64) -> Bool {
        guard let card = peekCard, card.generation == generation else { return false }
        removePeek()
        focusPage(preferred: card.sourceResponder)
        return true
    }

    /// An Esc the page left alone closes the Peek card; with no card it goes on to the window.
    override func cancelOperation(_ sender: Any?) {
        guard let card = peekCard else {
            _ = nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
            return
        }
        card.dismiss()
    }

    func showsPeekPage(_ peek: Peek) -> Bool {
        guard let card = peekCard, card.peek == peek else { return false }
        return card.slot.heldView != nil && card.slot.container.superview === peekLayer && peekLayer.superview === pageFrame
    }

    func showsPeek(_ peek: Peek, generation: UInt64, header: NSView, actions: NSView) -> Bool {
        guard let card = peekCard, card.generation == generation,
              card.header === header, card.actions === actions else { return false }
        return showsPeekPage(peek) && header.superview === peekLayer && actions.superview === peekLayer
    }

    private func removePeek() {
        guard let card = peekCard else { return }
        peekCard = nil
        if card.slot.heldView != nil { card.slot.view?.removeFromSuperview() }
        card.slot.container.removeFromSuperview()
        for view in [card.header, card.actions] where view?.superview === peekLayer { view?.removeFromSuperview() }
        peekLayer.removeFromSuperview()
        layoutPageArea()
    }

    private func layoutPeek(in area: CGRect, washFrame: CGRect) {
        guard let card = peekCard else { return }
        peekLayer.frame = area
        peekWash.frame = peekLayer.convert(washFrame, from: pageFrame)
        let layout = Self.peekLayout(in: area.size)
        for view in [peekWash, card.header, card.actions] { view?.isHidden = pageFullscreen }
        card.header?.frame = layout.header
        card.actions?.frame = layout.actions
        card.slot.container.frame = pageFullscreen ? peekLayer.bounds : layout.page
        card.slot.container.layer?.cornerRadius = pageFullscreen ? 0 : Arc.peekCornerRadius
        card.slot.fillContainer()
    }

    private final class PeekCard {
        let peek: Peek
        let generation: UInt64
        let slot: Slot
        weak var sourceResponder: NSView?
        weak var header: NSView?
        weak var actions: NSView?
        let dismiss: () -> Void

        init(peek: Peek, generation: UInt64, slot: Slot, header: NSView, actions: NSView, dismiss: @escaping () -> Void) {
            self.peek = peek; self.generation = generation; self.slot = slot
            self.header = header; self.actions = actions; self.dismiss = dismiss
        }
    }

    /// Uncovered siblings keep receiving pointer and scroll events.
    private final class PeekLayer: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }

    /// A click on the dimmed source dismisses the card.
    private final class PeekWash: NSView {
        var onClick: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor(white: 128 / 255, alpha: 115 / 255).cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func mouseDown(with event: NSEvent) { onClick?() }
        override func rightMouseDown(with event: NSEvent) {}
        override func otherMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
    }
}
