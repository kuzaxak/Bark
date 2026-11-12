import AppKit
import BarcChromium

/// One host-mode window's root view (`--bark-window=host`). Chromium shows it
/// as the window's whole content, and the app places the selected tab's page
/// view in it. A page is visible only while its view is in the window.
@MainActor
final class ChromiumWindowRoot: NSView {
    private let bridge: BarcBridge
    let nativeWindow: Int32
    private(set) var shownTab: Int32 = 0
    private weak var page: NSView?
    private var observation: UInt64 = 0

    init(bridge: BarcBridge, nativeWindow: Int32) {
        self.bridge = bridge
        self.nativeWindow = nativeWindow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if observation != 0 { bridge.window_host_unobserve(observation) }
    }

    /// Gives this view to the window and listens for pages leaving it. The
    /// caller keeps the root alive while the window can still send events.
    func attach() -> Bool {
        guard observation == 0,
              bridge.window_set_root_view(nativeWindow, Unmanaged.passUnretained(self).toOpaque()) == 1 else { return false }
        observation = bridge.window_host_observe(nativeWindow, { event, context in
            guard let event, let context, event.pointee.size >= MemoryLayout<BarcWindowHostEvent>.size,
                  event.pointee.kind == Int32(BARC_WINDOW_HOST_PAGE_VIEW_RETIRED.rawValue) else { return }
            let view = event.pointee.view
            MainActor.assumeIsolated {
                Unmanaged<ChromiumWindowRoot>.fromOpaque(context).takeUnretainedValue().pageRetired(view)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        return observation != 0
    }

    /// Shows `tab`'s page in place of the one shown before. False when the
    /// window has no page view for that tab.
    @discardableResult
    func show(tab: Int32) -> Bool {
        guard let pointer = bridge.tab_native_view(nativeWindow, tab) else { return false }
        let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
        if view !== page, page?.superview === self {
            page?.removeFromSuperview()
        }
        if view.superview !== self {
            view.frame = Self.pageFrame(in: bounds)
            addSubview(view)
        }
        page = view
        shownTab = tab
        return true
    }

    private func pageRetired(_ view: UnsafeMutableRawPointer?) {
        guard let page, let view, Unmanaged.passUnretained(page).toOpaque() == view else { return }
        if page.superview === self { page.removeFromSuperview() }
        self.page = nil
        shownTab = 0
    }

    override func layout() {
        super.layout()
        page?.frame = Self.pageFrame(in: bounds)
    }

    nonisolated static func pageFrame(in bounds: CGRect) -> CGRect { bounds }
}
