import AppKit
import BarcChromium

/// One host-mode window's root view (`--bark-window=host`). Chromium shows it as the window's
/// whole content, and the app lays out the sidebar, the page frame and the selected tab's page
/// view in it. A page is visible only while its view is in the window.
@MainActor
final class ChromiumWindowRoot: NSView {
    /// Arc's window at 1x, read from `build/arc-reference/`.
    enum Arc {
        /// The first light centred at (20, 24); with the revealed sidebar, at (25, 28.5).
        static let lights = Lights(titlebarHeight: 48, leadingInset: 13)
        static let revealedLights = Lights(titlebarHeight: 57, leadingInset: 18)
        static let sidebarWidth: CGFloat = 247
        static let pageMargin: CGFloat = 10
        static let pageCornerRadius: CGFloat = 7
        static let revealMargin: CGFloat = 5
        static let revealCornerRadius: CGFloat = 10
    }

    struct Lights: Equatable {
        var titlebarHeight: Double
        var leadingInset: Double
    }

    enum Sidebar: Equatable { case shown, hidden, revealed }

    struct Layout: Equatable {
        /// Nil while the sidebar is out of the window.
        var sidebar: CGRect?
        var page: CGRect
        var pageCornerRadius: CGFloat
    }

    /// Where the sidebar and the page frame go in `bounds`, with a top-left origin. The page frame
    /// keeps its place when the hidden sidebar floats in over it.
    nonisolated static func layout(in bounds: CGRect, sidebar: Sidebar, pageFullscreen: Bool) -> Layout {
        if pageFullscreen { return Layout(sidebar: nil, page: bounds, pageCornerRadius: 0) }
        let margin = Arc.pageMargin
        let height = max(0, bounds.height - 2 * margin)
        let unsided = CGRect(x: bounds.minX + margin, y: bounds.minY + margin,
                             width: max(0, bounds.width - 2 * margin), height: height)
        switch sidebar {
        case .shown:
            let width = min(Arc.sidebarWidth, bounds.width)
            return Layout(sidebar: CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height),
                          page: CGRect(x: bounds.minX + width, y: bounds.minY + margin,
                                       width: max(0, bounds.width - width - margin), height: height),
                          pageCornerRadius: Arc.pageCornerRadius)
        case .hidden:
            return Layout(sidebar: nil, page: unsided, pageCornerRadius: Arc.pageCornerRadius)
        case .revealed:
            let inset = Arc.revealMargin
            return Layout(sidebar: CGRect(x: bounds.minX + inset, y: bounds.minY + inset,
                                          width: min(Arc.sidebarWidth, max(0, bounds.width - 2 * inset)),
                                          height: max(0, bounds.height - 2 * inset)),
                          page: unsided, pageCornerRadius: Arc.pageCornerRadius)
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
    let nativeWindow: Int32
    private(set) var shownTab: Int32 = 0
    private weak var page: NSView?
    private var observation: UInt64 = 0
    private let pageFrame = Container()
    private let sidebarColumn = Container()
    private let crashedPage = CrashedPage()
    private weak var sidebarView: NSView?
    private weak var backdrop: NSView?
    private weak var header: NSView?
    private var headerHeight: CGFloat = 0
    private var crashedTabs: Set<Int32> = []
    private var fullscreenObservers: [NSObjectProtocol] = []
    private(set) var pageFullscreen = false

    var sidebar: Sidebar = .shown {
        didSet {
            guard sidebar != oldValue else { return }
            applyLayout()
            applyLights()
        }
    }

    /// The window shows no page of its own: an empty space, or a page another window holds.
    var pageHidden = false {
        didSet { heldPage?.isHidden = pageHidden }
    }

    /// The page this root shows; nil once another root took it.
    private var heldPage: NSView? { page?.superview === pageFrame ? page : nil }

    init(bridge: BarcBridge, nativeWindow: Int32) {
        self.bridge = bridge
        self.nativeWindow = nativeWindow
        super.init(frame: .zero)
        wantsLayer = true
        let frameDrag = WindowFrameInteractionView()
        frameDrag.autoresizingMask = [.width, .height]
        addSubview(frameDrag)
        pageFrame.wantsLayer = true
        pageFrame.layer?.masksToBounds = true
        pageFrame.autoresizingMask = [.width, .height]
        addSubview(pageFrame)
        crashedPage.isHidden = true
        crashedPage.autoresizingMask = [.width, .height]
        crashedPage.reload = { [weak self] in
            guard let self, self.shownTab != 0 else { return }
            _ = self.bridge.tab_reload(self.nativeWindow, self.shownTab)
        }
        pageFrame.addSubview(crashedPage)
        sidebarColumn.wantsLayer = true
        sidebarColumn.autoresizingMask = [.height]
        addSubview(sidebarColumn)
        applyLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if observation != 0 { bridge.window_host_unobserve(observation) }
        fullscreenObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }

    /// Gives this view to the window, places the window's lights and listens for its pages. The
    /// caller keeps the root alive while the window can still send events.
    func attach() -> Bool {
        guard observation == 0 else { return false }
        let observation = bridge.window_host_observe(nativeWindow, { event, context in
            guard let event, let context, event.pointee.size >= MemoryLayout<BarcWindowHostEvent>.size else { return }
            let copy = event.pointee
            MainActor.assumeIsolated {
                Unmanaged<ChromiumWindowRoot>.fromOpaque(context).takeUnretainedValue().handle(copy)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard observation != 0 else { return false }
        guard bridge.window_set_root_view(nativeWindow, Unmanaged.passUnretained(self).toOpaque()) == 1 else {
            bridge.window_host_unobserve(observation)
            return false
        }
        self.observation = observation
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

    /// Shows `tab`'s page in place of the one shown before. False when the window has no page
    /// view for that tab.
    @discardableResult
    func show(tab: Int32) -> Bool {
        guard let pointer = bridge.tab_native_view(nativeWindow, tab) else { return false }
        let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
        let changed = view !== page || view.superview !== pageFrame
        if view !== page, page?.superview === pageFrame {
            page?.removeFromSuperview()
        }
        if view.superview !== pageFrame {
            view.frame = pageArea
            view.autoresizingMask = [.width, .height]
            pageFrame.addSubview(view, positioned: .below, relativeTo: crashedPage)
        }
        view.isHidden = pageHidden
        page = view
        shownTab = tab
        crashedPage.isHidden = !crashedTabs.contains(tab)
        if changed { focusPage() }
        return true
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
            pageFrame.addSubview(view, positioned: .above, relativeTo: crashedPage)
        }
        layoutPageArea()
        return true
    }

    var showsCrashedPage: Bool { !crashedPage.isHidden }

    /// The bar's height in the page frame; a full-screen page has none above it.
    private var barHeight: CGFloat { pageFullscreen ? 0 : headerHeight }

    private var pageArea: CGRect {
        CGRect(x: 0, y: barHeight, width: pageFrame.bounds.width, height: max(0, pageFrame.bounds.height - barHeight))
    }

    private func handle(_ event: BarcWindowHostEvent) {
        switch UInt32(bitPattern: event.kind) {
        case BARC_WINDOW_HOST_PAGE_VIEW_RETIRED.rawValue:
            crashedTabs.remove(event.tab)
            pageRetired(event.view)
        case BARC_WINDOW_HOST_FULLSCREEN_CHANGED.rawValue:
            let pageFullscreen = event.fullscreen == Int32(BARC_FULLSCREEN_PAGE.rawValue)
            guard pageFullscreen != self.pageFullscreen else { return }
            self.pageFullscreen = pageFullscreen
            applyLayout()
            applyLights()
        case BARC_WINDOW_HOST_PAGE_CRASHED.rawValue:
            crashedTabs.insert(event.tab)
            if event.tab == shownTab, isShown(event.view) { crashedPage.isHidden = false }
        case BARC_WINDOW_HOST_PAGE_RESTORED.rawValue:
            crashedTabs.remove(event.tab)
            if event.tab == shownTab { crashedPage.isHidden = true }
        default:
            break
        }
    }

    private func isShown(_ view: UnsafeMutableRawPointer?) -> Bool {
        guard let page = heldPage, let view else { return false }
        return Unmanaged.passUnretained(page).toOpaque() == view
    }

    /// A retired page leaves the window; a tab that replaced its contents shows its new page.
    private func pageRetired(_ view: UnsafeMutableRawPointer?) {
        guard let page, let view, Unmanaged.passUnretained(page).toOpaque() == view else { return }
        if page.superview === pageFrame { page.removeFromSuperview() }
        self.page = nil
        let tab = shownTab
        shownTab = 0
        crashedPage.isHidden = true
        if let next = bridge.tab_native_view(nativeWindow, tab), next != view { show(tab: tab) }
    }

    /// Keys go to the page shown, unless the person is typing in a field outside it.
    private func focusPage() {
        guard let window, let page = heldPage, !pageHidden else { return }
        if let editor = window.firstResponder as? NSText, !editor.isDescendant(of: pageFrame) { return }
        guard let target = page.subviews.first(where: \.acceptsFirstResponder) ?? (page.acceptsFirstResponder ? page : nil)
        else { return }
        window.makeFirstResponder(target)
    }

    private func applyLayout() {
        let layout = Self.layout(in: bounds, sidebar: sidebar, pageFullscreen: pageFullscreen)
        pageFrame.frame = layout.page
        pageFrame.layer?.cornerRadius = layout.pageCornerRadius
        sidebarColumn.frame = layout.sidebar ?? waitingSidebarFrame
        let floating = sidebar == .revealed && !pageFullscreen
        sidebarColumn.layer?.cornerRadius = floating ? Arc.revealCornerRadius : 0
        sidebarColumn.layer?.masksToBounds = floating
        layoutPageArea()
    }

    /// Beside the window's leading edge, where a hidden sidebar waits for the pointer.
    private var waitingSidebarFrame: CGRect {
        CGRect(x: bounds.minX - Arc.sidebarWidth - Arc.revealMargin, y: bounds.minY, width: Arc.sidebarWidth, height: bounds.height)
    }

    private func layoutPageArea() {
        let area = pageArea
        header?.isHidden = pageFullscreen
        header?.frame = CGRect(x: 0, y: 0, width: pageFrame.bounds.width, height: barHeight)
        heldPage?.frame = area
        crashedPage.frame = area
    }

    private func applyLights() {
        guard observation != 0 else { return }
        let lights = Self.lights(for: pageFullscreen ? .hidden : sidebar)
        if let lights {
            var chrome = BarcWindowChrome(size: MemoryLayout<BarcWindowChrome>.size,
                                          titlebar_height: lights.titlebarHeight, leading_inset: lights.leadingInset)
            _ = bridge.window_set_chrome(nativeWindow, &chrome)
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = lights == nil
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
        fullscreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullscreenObservers = []
        guard let window else { return }
        // AppKit rebuilds the titlebar when the window leaves full screen.
        fullscreenObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyLights() }
            })
        applyLights()
    }

    private final class Container: NSView {
        override var isFlipped: Bool { true }
    }

    /// What the page frame shows while the shown tab's renderer is gone.
    private final class CrashedPage: NSView {
        var reload: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let title = NSTextField(labelWithString: "This page crashed")
            title.font = .systemFont(ofSize: 17, weight: .semibold)
            let button = NSButton(title: "Reload", target: self, action: #selector(reloadPage))
            let stack = NSStackView(views: [title, button])
            stack.orientation = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                         stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        @objc private func reloadPage() { reload?() }
    }
}

extension ChromiumWindowRoot: ChromiumPanelHost {
    func panelContainer(for fill: ChromiumPanelFill) -> NSView { fill == .window ? self : pageFrame }
}
