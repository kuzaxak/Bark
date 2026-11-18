import AppKit
import BarcChromium

/// What a Bark window's engine tells the root view the app gave it.
enum ChromiumWindowHostChange {
    /// `tab`'s page view `view` leaves the window: the tab closed, moved or replaced its contents.
    case pageRetired(tab: Int32, view: UnsafeMutableRawPointer?)
    /// The window entered or left full screen, `page` when a page asked for it. The engine sends
    /// this on every client selection too, naming the selected client.
    case fullscreen(page: Bool, client: Int32)
    /// `tab`'s renderer is gone and its page view `view` shows nothing.
    case pageCrashed(tab: Int32, view: UnsafeMutableRawPointer?)
    case pageRestored(tab: Int32)
    case extensionActionsChanged
}

/// A root view's tie to its Bark window: the root given to the window, and the window's changes
/// while the link lives.
@MainActor
final class ChromiumWindowHostLink {
    private let bridge: BarcBridge
    private let receive: (ChromiumWindowHostChange) -> Void
    private var observation: UInt64 = 0

    init(bridge: BarcBridge, receive: @escaping (ChromiumWindowHostChange) -> Void) {
        self.bridge = bridge
        self.receive = receive
    }

    isolated deinit {
        if observation != 0 { bridge.window_host_unobserve(observation) }
    }

    var isAttached: Bool { observation != 0 }

    /// Observes the window `client` belongs to and gives it `root`. False, observing nothing, when
    /// the window is not a Bark window or already has another root.
    func attach(_ root: NSView, client: Int32) -> Bool {
        guard observation == 0 else { return false }
        let observation = bridge.window_host_observe(client, { event, context in
            guard let event, let context, event.pointee.size >= MemoryLayout<BarcWindowHostEvent>.size else { return }
            let copy = event.pointee
            MainActor.assumeIsolated {
                Unmanaged<ChromiumWindowHostLink>.fromOpaque(context).takeUnretainedValue().deliver(copy)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard observation != 0 else { return false }
        // The root can install its window chrome synchronously during attachment.
        self.observation = observation
        guard bridge.window_set_root_view(client, Unmanaged.passUnretained(root).toOpaque()) == 1 else {
            self.observation = 0
            bridge.window_host_unobserve(observation)
            return false
        }
        return true
    }

    private func deliver(_ event: BarcWindowHostEvent) {
        switch UInt32(bitPattern: event.kind) {
        case BARC_WINDOW_HOST_PAGE_VIEW_RETIRED.rawValue: receive(.pageRetired(tab: event.tab, view: event.view))
        case BARC_WINDOW_HOST_FULLSCREEN_CHANGED.rawValue:
            receive(.fullscreen(page: event.fullscreen == Int32(BARC_FULLSCREEN_PAGE.rawValue), client: event.window))
        case BARC_WINDOW_HOST_PAGE_CRASHED.rawValue: receive(.pageCrashed(tab: event.tab, view: event.view))
        case BARC_WINDOW_HOST_PAGE_RESTORED.rawValue: receive(.pageRestored(tab: event.tab))
        case BARC_WINDOW_HOST_EXTENSION_ACTIONS_CHANGED.rawValue: receive(.extensionActionsChanged)
        default: break
        }
    }
}

/// One page in its own clipped container, with the crashed-page card over it; with no pane, Add
/// Split View's empty pane.
@MainActor
final class ChromiumPageSlot {
    let pane: ChromiumWindowRoot.Pane?
    let container = FlippedView()
    weak var view: NSView?
    let crashed = ChromiumCrashedPage()
    private var empty: NSView?

    init(pane: ChromiumWindowRoot.Pane?, bridge: BarcBridge) {
        self.pane = pane
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        crashed.isHidden = true
        crashed.frame = container.bounds
        crashed.autoresizingMask = [.width, .height]
        crashed.reload = {
            guard let pane else { return }
            _ = bridge.tab_reload(pane.client, pane.tab)
        }
        container.addSubview(crashed)
    }

    /// The page while it is still in this slot; nil once another root took it.
    var heldView: NSView? { view?.superview === container ? view : nil }

    func holds(_ pointer: UnsafeMutableRawPointer?) -> Bool {
        guard let held = heldView, let pointer else { return false }
        return Unmanaged.passUnretained(held).toOpaque() == pointer
    }

    /// Puts `view` in the container, taking out the page this slot held before.
    func place(_ view: NSView, hidden: Bool, crashed isCrashed: Bool) {
        if view !== self.view, heldView != nil { self.view?.removeFromSuperview() }
        if view.superview !== container {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view, positioned: .below, relativeTo: crashed)
        }
        view.isHidden = hidden
        self.view = view
        crashed.isHidden = !isCrashed
    }

    /// Autoresizing rounds a fractional container size; the page takes it exactly.
    func fillContainer() {
        heldView?.frame = container.bounds
        crashed.frame = container.bounds
        empty?.frame = container.bounds
    }

    func showEmpty(_ make: () -> NSView) {
        guard empty == nil else { return }
        let view = make()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        empty = view
    }

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// What a page's place shows while its renderer is gone.
final class ChromiumCrashedPage: NSView {
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
