// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+Media.swift
//  Nook
//
//  Media, audio, picture-in-picture and page color state for a PageSession.
//

import SwiftUI
import WebKit

extension PageSession {
    // MARK: - Media Reports

    /// One frame's state from its media script (`MediaScript`): pushed by its reporter, asked for
    /// again by `refreshMediaReports`, or returned by a control. `gone` means the frame's document
    /// went away. The page's media is what any frame holds.
    func receiveMediaReport(_ body: [String: Any], from frame: WKFrameInfo?) {
        guard let id = body["frame"] as? String else { return }
        mediaFrames.report(id, frame: frame, media: body["gone"] == nil ? PageMedia(report: body) : nil)
        applyMediaFrames()
    }

    /// Sets the page's media from WebKit's signal and its frames' reports, each property only when
    /// it changes: a set fires observers even with the same value, and views showing video
    /// re-render on it.
    func applyMediaFrames() {
        let combined = mediaFrames.media(audible: webKitAudible)
        if media != combined { media = combined }
        if hasVideoContent != combined.hasVideo { hasVideoContent = combined.hasVideo }
        if hasPlayingVideo != combined.isPlayingVideo { hasPlayingVideo = combined.isPlayingVideo }
        if hasAudioContent != combined.isAudible { hasAudioContent = combined.isAudible }
        if hasPlayingAudio != combined.isAudible { hasPlayingAudio = combined.isAudible }
    }

    /// WebKit says the page started or stopped playing sound. The frames are asked for their state
    /// again as well, so a report that never arrived cannot leave the page without a player.
    func webKitAudioChanged(_ audible: Bool) {
        webKitAudible = audible
        refreshMediaReports()
    }

    /// Asks the main frame and every frame that has reported for its state again.
    func refreshMediaReports() {
        guard let webView else { return applyMediaFrames() }
        let frames: [WKFrameInfo?] = [nil] + mediaFrames.frames.filter { $0?.isMainFrame == false }
        Task { @MainActor [weak self, weak webView] in
            for frame in frames {
                guard let webView, let state = try? await webView.callAsyncJavaScript(
                    "return window.__nookMedia?.state() ?? null;", in: frame, contentWorld: .page) as? [String: Any]
                else { continue }
                self?.receiveMediaReport(state, from: frame)
            }
            self?.applyMediaFrames()
        }
    }

    /// Runs one of `window.__nookMedia`'s controls in `frame` and takes the state it answers with,
    /// so the bar follows the change at once.
    private func runMediaControl(_ call: String, _ arguments: [String: Any], in frame: WKFrameInfo?) {
        guard let webView else { return }
        Task { @MainActor [weak self] in
            let state = try? await webView.callAsyncJavaScript(
                "return (await window.__nookMedia?.\(call)) ?? null;", arguments: arguments, in: frame, contentWorld: .page)
            if let state = state as? [String: Any] { self?.receiveMediaReport(state, from: frame) }
        }
    }

    public func toggleMute() {
        setMuted(!isAudioMuted)
    }

    /// Pauses every frame's player, or resumes what last played with sound.
    public func togglePlayback() {
        let play = !media.isPlaying
        let frames = play ? [mediaFrames.resumeTarget ?? nil] : mediaFrames.pauseTargets
        for frame in frames { runMediaControl("toggle(play)", ["play": play], in: frame) }
    }

    /// Previous or Next, in the frame whose player can (`media.handlesPreviousTrack`, `handlesNextTrack`).
    public func skipTrack(forward: Bool) {
        guard let frame = mediaFrames.trackTarget(forward: forward) else { return }
        runMediaControl("skip(forward)", ["forward": forward], in: frame)
    }

    /// The mini player's mute button: undoes Nook's tab mute, else the page's own, else mutes the tab.
    public func toggleSound() {
        switch MuteAction.next(tabMuted: isAudioMuted, pageMuted: media.isMuted) {
        case .unmuteTab: setMuted(false)
        case .muteTab: setMuted(true)
        case .unmutePage:
            for frame in mediaFrames.pauseTargets { runMediaControl("unmute()", [:], in: frame) }
        }
    }

    public func setMuted(_ muted: Bool) {
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
    public func setupThemeColorObserver(for webView: WKWebView) {
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
        // In multi-window setup, we need to work with the WebView that's actually visible
        // in the current window, not just the first WebView created
        let activeWindowID = controller?.windowRegistry.activeWindow?.id
        let activeWebView = activeWindowID.flatMap { controller?.webViews?.webView(for: self.itemID, in: $0) }
        controller?.sessionDelegate?.requestPictureInPicture(for: self, webView: activeWebView)
    }
}
