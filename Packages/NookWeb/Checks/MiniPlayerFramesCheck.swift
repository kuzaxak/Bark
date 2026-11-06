// Licensed under GPL-3.0. See LICENSE.
//
//  MiniPlayerFramesCheck.swift
//  Nook
//
//  The media scripts in WebKit: a player in a cross-origin iframe, and one the page plays outside
//  its document (`new Audio()`), are the page's media and bring up the mini player; Pause, Play
//  and Next act in the frame that holds the player; a short chime outside the document is no
//  player. Runs an offscreen WKWebView. From the repo root:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/MediaScript.swift \
//           Packages/NookWeb/Sources/NookWeb/PageMedia.swift Packages/NookWeb/Sources/NookWeb/MiniPlayer.swift \
//           Packages/NookWeb/Checks/MiniPlayerFramesCheck.swift -o /tmp/miniplayer-frames && /tmp/miniplayer-frames
//

import AppKit
import WebKit

/// Serves the check's pages, so each frame is a real document with an origin of its own.
final class Pages: NSObject, WKURLSchemeHandler {
    let files: [String: String]

    init(files: [String: String]) {
        self.files = files
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        guard let html = files[(url.host ?? "") + url.path] else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// The app's message handler, reduced to the frame bookkeeping it does.
@MainActor
final class Reports: NSObject, WKScriptMessageHandler {
    var frames = MediaFrames<WKFrameInfo>()
    /// WebKit's private frame handle of every subframe report, which the app keys frames by.
    var subframeHandles: [NSObject] = []

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["frame"] as? String else { return }
        let info = message.frameInfo
        if !info.isMainFrame, let handle = info.value(forKey: "_handle") as? NSObject { subframeHandles.append(handle) }
        frames.report(info.isMainFrame ? "main" : AnyHashable(id), document: id, frame: info,
                      media: body["gone"] == nil ? PageMedia(report: body) : nil)
    }
}

@main
struct MiniPlayerFramesCheck {
    /// Silent 8-bit mono WAV: the scripts go by the element's state, not by what it sounds like.
    static func wav(seconds: Int) -> String {
        let rate = 8000, count = rate * seconds
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate)); append(UInt16(1)); append(UInt16(8))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count))
        data.append(Data(repeating: 128, count: count))
        return "data:audio/wav;base64," + data.base64EncodedString()
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { fatalError("MiniPlayerFramesCheck timed out") }

        let song = wav(seconds: 30), chime = wav(seconds: 2)
        let pages = Pages(files: [
            "article/page.html": """
                <!doctype html><html><body><p>An article with a player in it.</p>
                <iframe src="nookcheck://player/frame.html" width="300" height="150"></iframe>
                <script>window.song = '\(song)'; window.chime = '\(chime)';</script>
                </body></html>
                """,
            "player/frame.html": """
                <!doctype html><html><body><audio id="player" src="\(song)" loop></audio>
                <script>
                document.getElementById('player').play();
                navigator.mediaSession?.setActionHandler('nexttrack', () => { window.skipped = true; });
                </script></body></html>
                """,
            "www.youtube.com/watch.html": """
                <!doctype html><html><body><video src="\(song)"></video>
                <button class="ytp-prev-button" style="display: none" onclick="window.previous = true"></button>
                <button class="ytp-next-button" onclick="window.next = true"></button>
                </body></html>
                """,
            "news/page.html": """
                <!doctype html><html><body><video id="clip" src="\(song)" muted loop></video>
                <audio id="podcast" src="\(song)"></audio>
                <script>document.getElementById('clip').play(); window.podcast = document.getElementById('podcast');
                window.chime = '\(chime)';</script></body></html>
                """,
            "www.youtube.com/mute.html": """
                <!doctype html><html><body><video id="video" src="\(song)" loop></video>
                <button class="ytp-mute-button" onclick="window.muteClicks = (window.muteClicks || 0) + 1;
                    video.muted = !video.muted;"></button></body></html>
                """,
        ])
        let reports = Reports()
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(pages, forURLScheme: "nookcheck")
        let ucc = configuration.userContentController
        ucc.addUserScript(WKUserScript(source: MediaScript.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: MediaScript.reporter(handler: "media"), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.add(reports, name: "media")

        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        window.contentView = web
        window.orderBack(nil)

        func until(_ what: String, _ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            fatalError("waited for \(what): \(reports.frames.media)")
        }
        func run(_ body: String, in frame: WKFrameInfo?, _ arguments: [String: Any] = [:]) async -> Any? {
            do {
                return try await web.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: .page)
            } catch {
                fatalError("\(body) failed: \(error)")
            }
        }

        Task { @MainActor in
            web.load(URLRequest(url: URL(string: "nookcheck://article/page.html")!))
            await until("the iframe's player") { reports.frames.media.isAudible }
            let embed = reports.frames.pauseTargets
            precondition(embed.count == 1 && !embed[0].isMainFrame && embed[0].securityOrigin.host == "player",
                         "sound from the iframe only: \(embed.map(\.securityOrigin.host))")
            let handles = Set(reports.subframeHandles.map(AnyHashable.init))
            precondition(reports.subframeHandles.count >= 2 && handles.count == 1,
                         "one frame, one handle: \(reports.subframeHandles.count) reports, \(handles.count) handles")

            var miniPlayer = MiniPlayer()
            let page = UUID()
            let media = reports.frames.media
            miniPlayer.update([MiniPlayerPage(id: page, hasMedia: media.hasMedia, isAudible: media.isAudible, isOnScreen: false)])
            precondition(miniPlayer.itemID == page, "the bar shows the page whose iframe plays")

            let hasMediaSession = await run("return typeof navigator.mediaSession === 'object';", in: embed[0]) as? Bool == true
            if hasMediaSession {
                await until("the iframe's Next handler") { reports.frames.media.handlesNextTrack }
                let next = reports.frames.trackTarget(forward: true)
                precondition(next?.securityOrigin.host == "player", "Next acts in the player's frame")
                _ = await run("window.__nookMedia.skip(true);", in: next)
                let skipped = await run("return window.skipped === true;", in: next) as? Bool
                precondition(skipped == true, "the page's Next handler ran")
            }

            _ = await run("window.__nookMedia.toggle(false);", in: embed[0])
            await until("Pause in the iframe") { !reports.frames.media.isAudible }
            precondition(reports.frames.media.hasMedia, "a paused player is still media")
            let resume = reports.frames.resumeTarget
            precondition(resume?.securityOrigin.host == "player", "Play resumes the frame that last played sound")
            _ = await run("window.__nookMedia.toggle(true);", in: resume)
            await until("Play in the iframe") { reports.frames.media.isAudible }
            _ = await run("window.__nookMedia.toggle(false);", in: resume)
            await until("Pause again") { !reports.frames.media.isAudible }

            _ = await run("new Audio(window.chime).play(); return null;", in: nil)
            try? await Task.sleep(for: .milliseconds(1000))
            precondition(!reports.frames.media.isAudible, "a two-second chime outside the document is no player")

            _ = await run("window.player = new Audio(window.song); window.player.play(); return null;", in: nil)
            await until("the player outside the document") { reports.frames.pauseTargets.contains { $0.isMainFrame } }
            _ = await run("window.__nookMedia.toggle(false);", in: nil)
            await until("Pause outside the document") { !reports.frames.media.isAudible }
            precondition(reports.frames.resumeTarget?.isMainFrame == true, "Play resumes the main frame's player")

            // YouTube without media session handlers: its player's own buttons, when they show.
            reports.frames = MediaFrames()
            web.load(URLRequest(url: URL(string: "nookcheck://www.youtube.com/watch.html")!))
            await until("YouTube's Next button") { reports.frames.media.handlesNextTrack }
            precondition(!reports.frames.media.handlesPreviousTrack, "a hidden Previous button is no Previous")
            _ = await run("window.__nookMedia.skip(true);", in: reports.frames.trackTarget(forward: true))
            let clicked = await run("return window.next === true;", in: nil) as? Bool
            precondition(clicked == true, "Next clicks YouTube's button")

            // A news clip loops muted beside the podcast the bar controls.
            reports.frames = MediaFrames()
            web.load(URLRequest(url: URL(string: "nookcheck://news/page.html")!))
            await until("the news page") { reports.frames.media.hasMedia }
            _ = await run("podcast.volume = 0.4; await podcast.play(); return null;", in: nil)
            await until("the podcast") { reports.frames.media.isAudible }
            _ = await run("podcast.pause(); return null;", in: nil)
            await until("the podcast paused") { !reports.frames.media.isPlaying }
            precondition(!reports.frames.media.isMuted, "a muted clip is not the page muting its player")
            _ = await run("podcast.volume = 0; await podcast.play(); return null;", in: nil)
            await until("the podcast muted by the page") { reports.frames.media.isMuted }
            _ = await run("return await window.__nookMedia.unmute();", in: nil)
            let volume = await run("return podcast.volume;", in: nil) as? Double
            precondition(volume == 0.4, "unmuting restores the volume from before: \(String(describing: volume))")
            _ = await run("podcast.src = chime; podcast.loop = true; await podcast.play(); return null;", in: nil)
            let short = await run("return window.__nookMedia.state();", in: nil) as? [String: Any]
            precondition(short?["isAudible"] as? Bool == true, "the player counts on a short source, as for a bumper ad")

            // YouTube's own mute button keeps its player in step.
            reports.frames = MediaFrames()
            web.load(URLRequest(url: URL(string: "nookcheck://www.youtube.com/mute.html")!))
            await until("YouTube's video") { reports.frames.media.hasMedia }
            _ = await run("await video.play(); return null;", in: nil)
            await until("YouTube's video playing") { reports.frames.media.isAudible }
            _ = await run("video.muted = true; return null;", in: nil)
            await until("YouTube's video muted") { reports.frames.media.isMuted }
            _ = await run("return await window.__nookMedia.unmute();", in: nil)
            let muteClicks = await run("return window.muteClicks ?? 0;", in: nil) as? Int
            let stillMuted = await run("return video.muted;", in: nil) as? Bool
            precondition(muteClicks == 1 && stillMuted == false, "unmute clicks YouTube's button: \(String(describing: muteClicks))")

            print("MiniPlayerFramesCheck passed\(hasMediaSession ? "" : " (no navigator.mediaSession here: Next not checked)")")
            exit(0)
        }
        app.run()
    }
}
