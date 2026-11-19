// Licensed under GPL-3.0. See LICENSE.
import Foundation

extension PageSession {
    public func toggleMute() {
        setMuted(!isAudioMuted)
    }

    public func togglePlayback() {
        guard media.isKnown, media.hasMedia else { return }
        _ = navigation?.setPlaybackPaused(media.isPlaying)
    }

    public func skipTrack(forward: Bool) {
        guard media.isKnown, forward ? media.handlesNextTrack : media.handlesPreviousTrack else { return }
        _ = navigation?.skipTrack(forward: forward)
    }

    public func toggleSound() {
        guard let navigation, let muted = navigation.state.isAudioMuted else { return }
        _ = navigation.setAudioMuted(!muted)
    }

    public func setMuted(_ muted: Bool) {
        _ = navigation?.setAudioMuted(muted)
    }

    public func requestPictureInPicture() {
        _ = navigation?.requestPictureInPicture()
    }

    public func extractDomain(from url: URL) -> String? {
        url.host
    }
}
