// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped router; BrowserManager stands in with the app's space-file test.
import Foundation

enum BrowserManager {
    static func isSpaceFile(_ url: URL) -> Bool { url.isFileURL && url.pathExtension.lowercased() == "nookspace" }
}

@main @MainActor enum Check {
    static func main() async {
        let files = ChromiumSpaceFiles()
        let space = URL(fileURLWithPath: "/private/tmp/fixture/Work.nookspace")
        let page = URL(fileURLWithPath: "/private/tmp/fixture/page.html"), web = URL(string: "https://fixture.test/x.nookspace")!
        var imported: [URL] = []
        precondition(files.take(space), "a space file opened before the app is ready is the app's")
        precondition(!files.take(page) && !files.take(web), "other files and links stay pages")
        await Task.yield()
        precondition(imported.isEmpty, "nothing is imported before a window is up")
        files.ready { imported.append($0) }
        for _ in 0..<5 { await Task.yield() }
        precondition(imported == [space], "it is imported once the first window is up: \(imported)")
        precondition(files.take(space), "a space file opened later is the app's too")
        for _ in 0..<5 { await Task.yield() }
        precondition(imported == [space, space], "and imported: \(imported)")
        print("Space files: a .nookspace opened from Finder is imported, never shown as a page")
    }
}
