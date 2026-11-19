// Licensed under GPL-3.0. See LICENSE.

import Foundation

// MARK: - Page Text for History Search
extension PageSession {
    func cancelNativePageTextCapture() {
        nativePageTextTask?.cancel()
        nativePageTextTask = nil
    }

    private func nativePageTextCaptureIsCurrent(_ page: any PageNavigation,
        url: URL, serial: UInt64, controller: TabsController?) -> Bool {
        guard let controller else { return false }
        return usesNativePageHost && navigation === page && self.controller === controller &&
            !controller.isTerminating && !nativeIsEnding && !isPrivate && !isAgentPage &&
            profile != nil && profile?.isEphemeral == false && profile?.id == page.profileID &&
            controller.settings.searchPageTextInHistory &&
            nativeNavigationSerial == serial && self.url == url && page.state.url == url &&
            !page.state.isLoading &&
            (controller.session(for: itemID) === self || (isDetached && nativeResourceHost != nil))
    }

    /// The top bar takes the colour at the page's top right, once per domain. A page
    /// with no rendered frame yet refuses or returns nothing, and selecting it asks again.
    public func sampleNativeTopBarColor() {
        guard usesNativePageHost, !isLoading, let page = navigation, let domain = url.host,
              lastTopBarDomain != domain else { return }
        let serial = nativeNavigationSerial
        nativeTopBarSample?.cancel()
        nativeTopBarSample = Task { @MainActor [weak self, weak page] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let page, self.navigation === page,
                  self.nativeNavigationSerial == serial else { return }
            _ = page.captureThumbnail { [weak self, weak page] bytes in
                guard let self, let page, self.navigation === page, self.nativeNavigationSerial == serial,
                      let bytes, let color = PlatformImage(data: bytes)?.topRightPixelColor else { return }
                self.lastSampledDomain = domain
                self.lastTopBarDomain = domain
                self.topBarBackgroundColor = color
            }
        }
    }

    /// A page's colours follow the appearance, so its next selection samples again.
    public func resetNativeTopBarSample() {
        lastSampledDomain = nil
        lastTopBarDomain = nil
    }

    /// Capture opted-in searchable text after the current document settles.
    func scheduleNativePageTextCapture(sameDocument: Bool) {
        guard usesNativePageHost, let page = navigation, let controller, let profileID = page.profileID,
              let url = page.state.url, url.scheme == "http" || url.scheme == "https" else { return }
        let serial = nativeNavigationSerial
        guard nativePageTextCaptureIsCurrent(page, url: url, serial: serial, controller: controller) else { return }
        cancelNativePageTextCapture()
        nativePageTextTask = Task { @MainActor [weak self, weak page, weak controller] in
            do { try await Task.sleep(for: .milliseconds(sameDocument ? 1500 : 1000)) }
            catch { return }
            guard !Task.isCancelled, let page,
                  self?.nativePageTextCaptureIsCurrent(page, url: url, serial: serial, controller: controller) == true else { return }
            if let last = self?.lastTextCapture {
                if sameDocument, last.url.host == url.host, last.url.path == url.path { return }
                if !sameDocument, last.url == url, Date().timeIntervalSince(last.at) < 5 { return }
            }
            self?.lastTextCapture = (url, Date())
            let text = await page.capturePageText()
            guard !Task.isCancelled, let self, let controller, let text, text.body.utf16.count >= 100,
                  self.nativePageTextCaptureIsCurrent(page, url: url, serial: serial, controller: controller) else { return }
            controller.history?.recordPageText(url: url, profile: profileID, title: text.title, body: text.body)
        }
    }
}
