import NookWeb

/// The existing mini-window manager retains both native and WebKit presenters.
@MainActor
protocol DetachedPageWindowController: AnyObject {
    var page: PageSession { get }
    var nativeWindowID: Int32? { get }
    var nativeTabID: Int32? { get }
    func relinquishNativeHeader()
    func releaseAfterAdoption()
    func close()
}

extension DetachedPageWindowController {
    var nativeWindowID: Int32? { nil }
    var nativeTabID: Int32? { nil }
    func relinquishNativeHeader() {}
    func releaseAfterAdoption() { close() }
}
