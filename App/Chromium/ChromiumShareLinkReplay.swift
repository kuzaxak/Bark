// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// A rejected share lookup re-enters Chromium's normal external URL queue.
/// Target resolution may repeat before Chromium admits a pending page.
@MainActor
final class ChromiumShareLinkReplay {
    private var replaying: [URL: TimeInterval] = [:]
    private let currentTime: () -> TimeInterval

    init(currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.currentTime = currentTime
    }

    private func prune() {
        let now = currentTime()
        replaying = replaying.filter { $0.value > now }
    }

    func take(_ url: URL, lookup: (URL, @escaping () -> Void) -> Bool,
              reopen: @escaping (URL) -> Void) -> Bool {
        prune()
        guard replaying[url] == nil else { return false }
        return lookup(url) { [weak self] in
            guard let self else { return }
            self.prune()
            guard self.replaying[url] == nil else { return }
            // A refused or abandoned navigation may never reach the pending
            // page callback. Do not bypass future opens of that invitation.
            self.replaying[url] = self.currentTime() + 60
            reopen(url)
        }
    }

    func reachedPendingPage(_ url: URL) {
        replaying.removeValue(forKey: url)
    }
}
