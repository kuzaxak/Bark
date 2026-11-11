import Foundation

/// Files the person opens with Bark, from Finder or `open`: a Nook space file is imported, as in
/// WebKit windows, and one that arrives before the first window waits for it.
@MainActor final class ChromiumSpaceFiles {
    private var pending: [URL] = []
    private var importer: (@MainActor (URL) -> Void)?

    /// Whether `url` is a space file, which this then imports.
    func take(_ url: URL) -> Bool {
        guard BrowserManager.isSpaceFile(url) else { return false }
        if let importer {
            Task { @MainActor in importer(url) }
        } else {
            pending.append(url)
        }
        return true
    }

    func ready(_ importer: @escaping @MainActor (URL) -> Void) {
        self.importer = importer
        let urls = pending
        pending = []
        for url in urls { Task { @MainActor in importer(url) } }
    }
}
