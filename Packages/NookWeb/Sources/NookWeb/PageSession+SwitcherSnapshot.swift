// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+SwitcherSnapshot.swift
//  NookWeb
//
//  The picture the Control-Tab switcher shows for a tab: taken as the window moves off it, while
//  the page is still on screen and drawn, at thumbnail size so it costs little to keep.
//

import Foundation

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
    public func captureSwitcherSnapshot() {
        guard let page = navigation, !SwitcherPressure.isUnderPressure,
              switcherCaptureInFlight == nil else { return }
        let request = UUID(), generation = switcherSnapshotGeneration
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
    }
}
