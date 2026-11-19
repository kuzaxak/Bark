import NookWeb

/// A detached Chromium page and its window controller.
@MainActor
protocol DetachedPageWindowController: AnyObject {
    var page: PageSession { get }
    var nativeWindowID: Int32? { get }
    var nativeTabID: Int32? { get }
    func relinquishNativeHeader()
    func releaseAfterAdoption()
    func close()
}
