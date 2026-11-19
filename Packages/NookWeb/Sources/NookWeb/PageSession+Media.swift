// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+Media.swift
//  Nook
//
//  Media, audio, picture-in-picture and page color state for a PageSession.
//

import OSLog
import SwiftUI
import WebKit

/// Media state and the mini player, item ids and flags only, on changes:
/// `/usr/bin/log stream --level info --predicate 'subsystem == "ee.qdo.nook" AND category == "Media"'`
/// (zsh has a `log` builtin; WebKit logs under a "Media" category of its own).
let mediaLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Media")

/// How a frame's state reached the app.
enum MediaReportSource: String {
    case push, ask, control
}

extension PageSession {
    // MARK: - Media Reports

    /// One frame's state from its media script (`MediaScript`): pushed by its reporter, asked for
    /// again by `refreshMediaReports`, or returned by a control. `gone` means the frame's document
    /// went away. The page's media is what any frame holds.
    func receiveMediaReport(_ body: [String: Any], from frame: WKFrameInfo?, via source: MediaReportSource = .push) {
        guard let document = body["frame"] as? String else { return }
        let key = Self.mediaFrameKey(frame, document: document)
        let report = body["gone"] == nil ? PageMedia(report: body) : nil
        if mediaFrames.frameMedia(key) != report {
            mediaLog.info("""
                media frame item=\(self.itemID, privacy: .public) source=\(source.rawValue, privacy: .public) \
                main=\(frame?.isMainFrame ?? true, privacy: .public) gone=\(report == nil, privacy: .public) \
                hasMedia=\(report?.hasMedia ?? false, privacy: .public) isAudible=\(report?.isAudible ?? false, privacy: .public) \
                isPlaying=\(report?.isPlaying ?? false, privacy: .public) isMuted=\(report?.isMuted ?? false, privacy: .public)
                """)
        }
        mediaFrames.report(key, document: document, frame: frame, media: report)
        applyMediaFrames()
    }

    /// Tells frames apart across reports and asks: WebKit's private `_handle`, equal for every
    /// `WKFrameInfo` of one frame, where there is one; else the reporting document.
    static func mediaFrameKey(_ frame: WKFrameInfo?, document: String) -> AnyHashable {
        guard let frame, !frame.isMainFrame else { return "main" }
        return frameHandle(frame) ?? AnyHashable("document " + document)
    }

    private static func frameHandle(_ frame: WKFrameInfo) -> AnyHashable? {
        guard frame.responds(to: NSSelectorFromString("_handle")) else { return nil }
        return (frame.value(forKey: "_handle") as? NSObject).map(AnyHashable.init)
    }

    /// A subframe a navigation named, asked again with the others even if it never reported.
    func noteMediaFrame(_ frame: WKFrameInfo) {
        guard !frame.isMainFrame, let handle = Self.frameHandle(frame) else { return }
        seenMediaFrames[handle] = frame
    }

    /// Sets the page's media from its frames' reports, and the audio state the tab row and the
    /// unload rules read from those and WebKit's signal. Each property is set only when it changes:
    /// a set fires observers even with the same value, and views showing video re-render on it.
    func applyMediaFrames() {
        let combined = mediaFrames.media
        let audible = mediaFrames.isAudible(webKit: webKitAudible)
        if media != combined || hasAudioContent != audible {
            mediaLog.info("""
                media page item=\(self.itemID, privacy: .public) \
                webKitAudible=\(self.webKitAudible.map(String.init) ?? "nil", privacy: .public) \
                framesAudible=\(combined.isAudible, privacy: .public) hasMedia=\(combined.hasMedia, privacy: .public) \
                isAudible=\(audible, privacy: .public)
                """)
        }
        if media != combined { media = combined }
        if hasVideoContent != combined.hasVideo { hasVideoContent = combined.hasVideo }
        if hasPlayingVideo != combined.isPlayingVideo { hasPlayingVideo = combined.isPlayingVideo }
        if hasAudioContent != audible { hasAudioContent = audible }
        if hasPlayingAudio != audible { hasPlayingAudio = audible }
    }

    /// WebKit says the page started or stopped playing sound. The tab row's speaker follows at
    /// once; the frames are asked for their state again, since the bar goes by them.
    func webKitAudioChanged(_ audible: Bool) {
        webKitAudible = audible
        applyMediaFrames()
        refreshMediaReports()
    }

    /// Asks the main frame and every subframe known from a report or a navigation for its state
    /// again. Asks made while one runs are folded into one more after it.
    public func refreshMediaReports() {
        guard primaryWebView != nil, mediaReask.request() else { return }
        Task { @MainActor [weak self] in await self?.reaskMediaFrames() }
    }

    private func reaskMediaFrames() async {
        var subframes = seenMediaFrames
        for (key, frame) in mediaFrames.frames {
            if let frame, !frame.isMainFrame { subframes[key] = frame }
        }
        await reaskMediaFrame(nil, key: "main")
        for (key, frame) in subframes { await reaskMediaFrame(frame, key: key) }
        applyMediaFrames()
        if mediaReask.finished() { await reaskMediaFrames() }
    }

    /// A subframe that no longer answers is gone, or no longer runs the media script. The main frame
    /// fails only mid-navigation, and its commit clears what it had reported.
    private func reaskMediaFrame(_ frame: WKFrameInfo?, key: AnyHashable) async {
        guard let webView = primaryWebView else { return }
        let state = try? await webView.callAsyncJavaScript(
            "return window.__nookMedia?.state() ?? null;", in: frame, contentWorld: .page)
        if let state = state as? [String: Any] {
            receiveMediaReport(state, from: frame, via: .ask)
        } else if frame != nil {
            mediaFrames.forget(key)
            seenMediaFrames[key] = nil
        }
    }

    /// Runs one of `window.__nookMedia`'s controls in `frame` and takes the state it answers with,
    /// so the bar follows the change at once, then asks every frame again.
    private func runMediaControl(_ call: String, _ arguments: [String: Any], in frame: WKFrameInfo?) {
        guard let webView = primaryWebView else { return }
        Task { @MainActor [weak self] in
            let state = try? await webView.callAsyncJavaScript(
                "return (await window.__nookMedia?.\(call)) ?? null;", arguments: arguments, in: frame, contentWorld: .page)
            if let state = state as? [String: Any] { self?.receiveMediaReport(state, from: frame, via: .control) }
            self?.refreshMediaReports()
        }
    }

    private func logMediaControl(_ control: String, frames: Int, fallback: Bool) {
        mediaLog.info("""
            media control item=\(self.itemID, privacy: .public) control=\(control, privacy: .public) \
            frames=\(frames, privacy: .public) fallback=\(fallback, privacy: .public)
            """)
    }

    public func toggleMute() {
        setMuted(!isAudioMuted)
    }

    /// Pauses every frame's player, or resumes what last played with sound. With no frame known to
    /// play, WebKit pauses everything on the page.
    public func togglePlayback() {
        if let navigation, !(navigation is WebKitPageNavigation) {
            guard media.isKnown, media.hasMedia else { return }
            _ = navigation.setPlaybackPaused(media.isPlaying)
            return
        }
        guard !usesNativePageHost else { return }
        let play = !media.isPlaying
        let frames = play ? [mediaFrames.resumeTarget ?? nil] : mediaFrames.pauseTargets
        logMediaControl(play ? "play" : "pause", frames: frames.count, fallback: frames.isEmpty)
        if frames.isEmpty, let webView = primaryWebView {
            Task { @MainActor [weak self] in
                await webView.pauseAllMediaPlayback()
                self?.refreshMediaReports()
            }
            return
        }
        for frame in frames { runMediaControl("toggle(play)", ["play": play], in: frame) }
    }

    /// Previous or Next, in the frame whose player can (`media.handlesPreviousTrack`, `handlesNextTrack`).
    public func skipTrack(forward: Bool) {
        if let navigation, !(navigation is WebKitPageNavigation) {
            guard media.isKnown, forward ? media.handlesNextTrack : media.handlesPreviousTrack else { return }
            _ = navigation.skipTrack(forward: forward)
            return
        }
        guard !usesNativePageHost else { return }
        let frame = mediaFrames.trackTarget(forward: forward)
        logMediaControl(forward ? "next" : "previous", frames: frame == nil ? 0 : 1, fallback: false)
        guard let frame else { return }
        runMediaControl("skip(forward)", ["forward": forward], in: frame)
    }

    /// The mini player's mute button: undoes Nook's tab mute, else the page's own, else mutes the tab.
    public func toggleSound() {
        if let navigation, !(navigation is WebKitPageNavigation) {
            guard let muted = navigation.state.isAudioMuted else { return }
            _ = navigation.setAudioMuted(!muted)
            return
        }
        guard !usesNativePageHost else { return }
        let action = MuteAction.next(tabMuted: isAudioMuted, pageMuted: media.isMuted)
        let frames = action == .unmutePage ? mediaFrames.mutedTargets : []
        logMediaControl("\(action)", frames: frames.count, fallback: false)
        switch action {
        case .unmuteTab: setMuted(false)
        case .muteTab: setMuted(true)
        case .unmutePage:
            for frame in frames { runMediaControl("unmute()", [:], in: frame) }
        }
    }

    public func setMuted(_ muted: Bool) {
        if let navigation, !(navigation is WebKitPageNavigation) {
            _ = navigation.setAudioMuted(muted)
            return
        }
        // A native page without a live resource has no mute command to apply.
        if usesNativePageHost { return }
        if let webView = primaryWebView {
            // Set the mute state using MuteableWKWebView's muted property
            webView.isMuted = muted
        } else {
        }

        controller?.sessionDelegate?.setMuteState(muted, for: itemID)

        // Update our internal state (already on main thread via @MainActor)
        isAudioMuted = muted
    }

    // MARK: - Native Audio Monitoring

    /// Core Audio reports output start/stop through a property listener, so there is no timer here.
    func startNativeAudioMonitoring() {
        guard !isMonitoringNativeAudio else { return }
        isMonitoringNativeAudio = true
        setupAudioSessionNotifications()
    }

    func stopNativeAudioMonitoring() {
        guard isMonitoringNativeAudio else { return }
        isMonitoringNativeAudio = false
        removeCoreAudioPropertyListeners()
    }

    func setupAudioSessionNotifications() {
        setupCoreAudioPropertyListeners()
    }

    /// Helper class that holds a weak reference to the session for the Core Audio listener callback.
    /// Prevents dangling pointer if the session is deallocated before the listener is removed.
    final class AudioListenerHelper {
        weak var session: PageSession?
        init(session: PageSession) { self.session = session }
    }

    // No throttle: the old 0.5s guard existed to dedupe the 1 Hz poll against listener
    // callbacks. With listeners only, throttling would swallow a stop that follows a start.
    func checkNativeAudioActivity() {
        let isDeviceActive = isDefaultAudioDeviceActive()

        if isDeviceActive && hasAudioContent {
            if !hasPlayingAudio {
                hasPlayingAudio = true
            }
        } else if hasPlayingAudio && !isDeviceActive {
            hasPlayingAudio = false
        }
    }

    // MARK: - Background Color Management
    func setupThemeColorObserver(for webView: WKWebView) {
        if !themeColorObservedWebViews.contains(webView) {
            webView.addObserver(
                self, forKeyPath: "themeColor", options: [.new, .initial], context: nil)
            themeColorObservedWebViews.add(webView)
        }
    }

    func removeThemeColorObserver(from webView: WKWebView) {
        if themeColorObservedWebViews.contains(webView) {
            webView.removeObserver(self, forKeyPath: "themeColor")
            themeColorObservedWebViews.remove(webView)
        }
    }

    func updateBackgroundColor(from webView: WKWebView) {
        // Check if we should sample based on domain change
        guard let currentURL = webView.url,
              let currentDomain = extractDomain(from: currentURL) else {
            // If no URL/domain, still try theme color but skip pixel sampling
            if let themeColor = webView.themeColor {
                pageBackgroundColor = themeColor
                webView.underPageBackgroundColor = themeColor
            }
            return
        }

        // Only sample if domain changed or we haven't sampled yet
        let shouldSample = lastSampledDomain != currentDomain

        var newColor: PlatformColor? = nil

        newColor = webView.themeColor

        if let themeColor = newColor {
            pageBackgroundColor = themeColor
            webView.underPageBackgroundColor = themeColor
            // Update sampled domain even for theme color
            if shouldSample {
                lastSampledDomain = currentDomain
            }
        } else if shouldSample {
            // Only extract via pixel sampling if domain changed
            extractBackgroundColorWithJavaScript(from: webView)
        }
    }
    
    /// Extract domain and subdomain from URL (e.g., "subdomain.example.com" -> "subdomain.example.com")
    public func extractDomain(from url: URL) -> String? {
        guard let host = url.host else { return nil }
        return host
    }

    func extractBackgroundColorWithJavaScript(from webView: WKWebView) {
        guard let sampleRect = colorSampleRect(for: webView) else {
            runLegacyBackgroundColorScript(on: webView)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = sampleRect
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = 1

        webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, error in
            // takeSnapshot completion runs on main thread; no dispatch needed
            guard let self = self, let webView = webView else { return }

            if let color = image?.singlePixelColor {
                self.pageBackgroundColor = color
                webView.underPageBackgroundColor = color
                // Update sampled domain after successful extraction
                if let currentURL = webView.url,
                   let currentDomain = self.extractDomain(from: currentURL) {
                    self.lastSampledDomain = currentDomain
                }
            } else {
                self.runLegacyBackgroundColorScript(on: webView)
            }
        }
    }

    func colorSampleRect(for webView: WKWebView) -> CGRect? {
        let bounds = webView.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        var sampleX = bounds.midX
        sampleX = min(max(bounds.minX, sampleX), bounds.maxX - 1)

        let offset: CGFloat = 2.0
        let yCandidate: CGFloat
        if webView.isFlipped {
            yCandidate = bounds.minY + offset
        } else {
            yCandidate = bounds.maxY - offset - 1
        }
        let sampleY = min(max(yCandidate, bounds.minY), bounds.maxY - 1)

        return CGRect(x: sampleX, y: sampleY, width: 1, height: 1)
    }
    
    func topRightPixelRect(for webView: WKWebView) -> CGRect? {
        let bounds = webView.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        
        // Sample the top-rightmost pixel
        let sampleX = bounds.maxX - 1
        let sampleY: CGFloat
        if webView.isFlipped {
            // In flipped coordinates, minY is at the top
            sampleY = bounds.minY
        } else {
            // In non-flipped coordinates, maxY is at the top
            sampleY = bounds.maxY - 1
        }
        
        return CGRect(x: sampleX, y: sampleY, width: 1, height: 1)
    }
    
    func extractTopBarColor(from webView: WKWebView) {
        // Only sample once per domain
        if let currentURL = webView.url,
           let domain = extractDomain(from: currentURL) {
            if lastTopBarDomain == domain { return }
            lastTopBarDomain = domain
        }

        guard let sampleRect = topRightPixelRect(for: webView) else {
            return
        }
        
        let configuration = WKSnapshotConfiguration()
        configuration.rect = sampleRect
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = 1
        
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self = self else { return }

            if let color = image?.singlePixelColor {
                self.topBarBackgroundColor = color
            }
        }
    }

    func runLegacyBackgroundColorScript(on webView: WKWebView) {
        let colorExtractionScript = """
            (function() {
                function rgbToHex(r, g, b) {
                    return '#' + [r, g, b].map(x => {
                        const hex = x.toString(16);
                        return hex.length === 1 ? '0' + hex : hex;
                    }).join('');
                }

                function parseColor(color) {
                    const div = document.createElement('div');
                    div.style.color = color;
                    document.body.appendChild(div);
                    const computedColor = window.getComputedStyle(div).color;
                    document.body.removeChild(div);

                    const match = computedColor.match(/rgb\\((\\d+),\\s*(\\d+),\\s*(\\d+)\\)/);
                    if (match) {
                        return rgbToHex(parseInt(match[1]), parseInt(match[2]), parseInt(match[3]));
                    }
                    return null;
                }

                function extractBackgroundColor() {
                    const body = document.body;
                    const html = document.documentElement;

                    // Try body background first
                    let bodyBg = window.getComputedStyle(body).backgroundColor;
                    if (bodyBg && bodyBg !== 'rgba(0, 0, 0, 0)' && bodyBg !== 'transparent') {
                        return parseColor(bodyBg);
                    }

                    // Try html background
                    let htmlBg = window.getComputedStyle(html).backgroundColor;
                    if (htmlBg && htmlBg !== 'rgba(0, 0, 0, 0)' && htmlBg !== 'transparent') {
                        return parseColor(htmlBg);
                    }

                    // Try sampling dominant colors from visible elements
                    const sampleElements = [
                        document.querySelector('header'),
                        document.querySelector('nav'),
                        document.querySelector('main'),
                        document.querySelector('.container'),
                        document.querySelector('#main'),
                        document.querySelector('[class*="background"]'),
                        document.querySelector('[class*="bg"]')
                    ].filter(el => el);

                    for (const el of sampleElements) {
                        const bg = window.getComputedStyle(el).backgroundColor;
                        if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') {
                            return parseColor(bg);
                        }
                    }

                    // Fallback: detect if page looks dark or light and return appropriate gray
                    const isDarkMode = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
                    const textColor = window.getComputedStyle(body).color;
                    const isLightText = textColor && (textColor.includes('255') || textColor.includes('white'));

                    if (isDarkMode || isLightText) {
                        return '#1a1a1a'; // Dark gray for dark themes
                    } else {
                        return '#ffffff'; // White for light themes
                    }
                }

                const bgColor = extractBackgroundColor();
                if (bgColor) {
                    window.webkit.messageHandlers['backgroundColor_\(itemID.uuidString)'].postMessage({
                        backgroundColor: bgColor
                    });
                }
            })();
            """

        webView.evaluateJavaScript(colorExtractionScript) { _, _ in }
    }

    public func requestPictureInPicture() {
        if let navigation, !(navigation is WebKitPageNavigation) {
            _ = navigation.requestPictureInPicture()
            return
        }
        guard !usesNativePageHost else { return }
        // In multi-window setup, we need to work with the WebView that's actually visible
        // in the current window, not just the first WebView created
        let activeWindowID = controller?.windowRegistry.activeWindow?.id
        let activeWebView = activeWindowID.flatMap { controller?.webViews?.webView(for: self.itemID, in: $0) }
        controller?.webKitSessionDelegate?.requestPictureInPicture(for: self, webView: activeWebView)
    }
}
