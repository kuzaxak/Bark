import AppKit
import BarcChromium

/// A compact Bark window's root view: the mini window for a link from another app, or a page's
/// popup. The app's header runs across the top with the window's lights at its leading edge; the
/// one page fills the rest, to the window's edges.
@MainActor
final class ChromiumCompactRoot: NSView {
    static let headerHeight: CGFloat = 44
    /// The window's lights, centred in the header.
    nonisolated static let lights = ChromiumWindowRoot.Lights(titlebarHeight: 44, leadingInset: 13)

    let client: Int32
    private let bridge: BarcBridge
    private lazy var link = ChromiumWindowHostLink(bridge: bridge) { [weak self] in self?.handle($0) }
    private var slot: ChromiumPageSlot?
    private weak var header: NSView?
    private(set) var shownTab: Int32 = 0
    private(set) var pageFullscreen = false
    private var crashedTabs: Set<Int32> = []
    private var grown = false
    private var fullscreenObservers: [NSObjectProtocol] = []

    init(bridge: BarcBridge, client: Int32) {
        self.bridge = bridge
        self.client = client
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        fullscreenObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }

    /// Gives this view to the window `client` belongs to and places its lights. False when the
    /// window is not a Bark window.
    func attach() -> Bool {
        guard link.attach(self, client: client) else { return false }
        applyLights()
        return true
    }

    /// The header across the top; nil takes it out.
    func setHeader(_ view: NSView?) {
        guard view !== header else { return }
        header?.removeFromSuperview()
        header = view
        if let view { addSubview(view) }
        layoutContent()
    }

    func holdsHeader(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return header === view && view.superview === self
    }

    /// Shows the client's `tab` below the header; the page then has the keys. False when the tab
    /// has no page view.
    @discardableResult
    func show(tab: Int32) -> Bool {
        guard let pointer = bridge.tab_native_view(client, tab) else { return false }
        let slot = self.slot.flatMap { $0.pane?.tab == tab ? $0 : nil } ?? makeSlot(tab: tab)
        slot.place(Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue(), hidden: false, crashed: crashedTabs.contains(tab))
        shownTab = tab
        layoutContent()
        focusPage()
        return true
    }

    var showsCrashedPage: Bool { slot.map { !$0.crashed.isHidden } ?? false }

    private func makeSlot(tab: Int32) -> ChromiumPageSlot {
        if let old = slot {
            if old.heldView != nil { old.view?.removeFromSuperview() }
            old.container.removeFromSuperview()
        }
        let slot = ChromiumPageSlot(pane: .init(client: client, tab: tab), bridge: bridge)
        addSubview(slot.container, positioned: .below, relativeTo: header)
        self.slot = slot
        return slot
    }

    private func handle(_ change: ChromiumWindowHostChange) {
        switch change {
        case .pageRetired(let tab, let view):
            crashedTabs.remove(tab)
            guard let slot, let view, let pane = slot.pane,
                  slot.view.map({ Unmanaged.passUnretained($0).toOpaque() }) == view else { return }
            if slot.heldView != nil { slot.view?.removeFromSuperview() }
            slot.view = nil
            slot.crashed.isHidden = true
            if let next = bridge.tab_native_view(pane.client, pane.tab), next != view { show(tab: pane.tab) } else { shownTab = 0 }
        case .fullscreen(let page, _):
            guard page != pageFullscreen else { return }
            pageFullscreen = page
            layoutContent()
            applyLights()
        case .pageCrashed(let tab, let view):
            crashedTabs.insert(tab)
            if let slot, slot.pane?.tab == tab, slot.holds(view) { slot.crashed.isHidden = false }
        case .pageRestored(let tab):
            crashedTabs.remove(tab)
            if let slot, slot.pane?.tab == tab { slot.crashed.isHidden = true }
        }
    }

    private func layoutContent() {
        header?.isHidden = pageFullscreen
        header?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        let top = pageFullscreen ? 0 : min(Self.headerHeight, bounds.height)
        slot?.container.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        slot?.fillContainer()
    }

    private func focusPage() {
        guard let window, let page = slot?.heldView else { return }
        guard let target = page.subviews.first(where: \.acceptsFirstResponder) ?? (page.acceptsFirstResponder ? page : nil) else { return }
        window.makeFirstResponder(target)
    }

    private func applyLights() {
        guard link.isAttached else { return }
        if !pageFullscreen {
            var chrome = BarcWindowChrome(size: MemoryLayout<BarcWindowChrome>.size, titlebar_height: Self.lights.titlebarHeight,
                                          leading_inset: Self.lights.leadingInset)
            _ = bridge.window_set_chrome(client, &chrome)
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = pageFullscreen
        }
    }

    /// A page asks for the size of its page area: the window grows by the header once, its
    /// top-left corner kept, and stays inside the screen's visible frame.
    private func growOnce(_ window: NSWindow) {
        guard !grown else { return }
        grown = true
        var frame = window.frame
        frame.size.height += Self.headerHeight
        frame.origin.y -= Self.headerHeight
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.height = min(frame.height, visible.height)
            frame.origin.y = max(frame.minY, visible.minY)
        }
        window.setFrame(frame, display: false)
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fullscreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullscreenObservers = []
        guard let window else { return }
        growOnce(window)
        // AppKit rebuilds the titlebar when the window leaves full screen.
        fullscreenObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyLights() }
            })
        applyLights()
        layoutContent()
    }
}

extension ChromiumCompactRoot: ChromiumPanelHost {
    func panelContainer(for fill: ChromiumPanelFill) -> NSView { fill == .window ? self : (slot?.container ?? self) }
}
