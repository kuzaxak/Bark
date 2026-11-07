// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+SwitcherSnapshot.swift
//  NookWeb
//
//  The picture the Control-Tab switcher shows for a tab: taken as the window moves off it, while
//  the page is still on screen and drawn, at thumbnail size so it costs little to keep.
//

import WebKit

/// Set by the system's memory-pressure events; capture pauses for a minute after one.
@MainActor private enum SwitcherPressure {
    static var last: Date?
    static let source: DispatchSourceMemoryPressure = {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { last = Date() } }
        s.resume()
        return s
    }()
    static var isUnderPressure: Bool {
        _ = source
        return last.map { Date().timeIntervalSince($0) < 60 } ?? false
    }
}

extension PageSession {
    private static let switcherSnapshotWidth: CGFloat = 400

    public func captureSwitcherSnapshot() {
        guard !SwitcherPressure.isUnderPressure, switcherCaptureInFlight == nil else { return }
        let request = UUID(), generation = switcherSnapshotGeneration
        if let page = navigation {
            switcherCaptureInFlight = request
            let accepted = page.captureThumbnail { [weak self, weak page] bytes in
                guard let self, self.switcherCaptureInFlight == request else { return }
                self.switcherCaptureInFlight = nil
                guard self.switcherSnapshotGeneration == generation,
                      let page, self.navigation === page, !SwitcherPressure.isUnderPressure,
                      let bytes, bytes.count <= 1_048_576,
                      let image = PlatformImage(data: bytes) else { return }
                self.switcherSnapshot = image
            }
            if !accepted, switcherCaptureInFlight == request { switcherCaptureInFlight = nil }
            return
        }
        guard let webView, webView.window != nil, webView.bounds.width > 0 else { return }
        switcherCaptureInFlight = request
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(Self.switcherSnapshotWidth))
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, _ in
            guard let self, self.switcherCaptureInFlight == request else { return }
            self.switcherCaptureInFlight = nil
            guard self.switcherSnapshotGeneration == generation,
                  let webView, self.primaryWebView === webView,
                  !SwitcherPressure.isUnderPressure, let image else { return }
            self.switcherSnapshot = image
        }
    }
}
