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
        checkShareReplay()
    }

    static func checkShareReplay() {
        let share = URL(string: "https://www.icloud.com/share/fixture#Bark_Spaces")!
        let other = URL(string: "https://www.icloud.com/share/other#Bark_Spaces")!
        var time: TimeInterval = 100
        let router = ChromiumShareLinkReplay(currentTime: { time })
        var opens: [URL] = []
        var lookedUp: [URL] = []
        var fallback: (() -> Void)?
        func lookup(_ url: URL, _ next: @escaping () -> Void) -> Bool {
            lookedUp.append(url)
            guard url == share else { return false }
            fallback = next
            return true
        }
        func take(_ url: URL) -> Bool { router.take(url, lookup: lookup, reopen: { opens.append($0) }) }

        precondition(take(share) && opens.isEmpty)
        fallback?()
        fallback?()
        precondition(opens == [share], "one replay is queued")
        precondition(!take(share) && !take(share), "both native resolution passes bypass CloudKit")
        precondition(!take(other), "a different link is not affected by the replay")
        precondition(lookedUp == [share, other])
        router.reachedPendingPage(share)
        precondition(take(share), "a later open can be handled after the pending page")
        fallback?()
        time += 61
        precondition(take(share), "an abandoned replay does not leave a permanent exception")
        print("Share links: ordinary replay survives repeated native resolution and retires on admission or expiry")
    }
}
