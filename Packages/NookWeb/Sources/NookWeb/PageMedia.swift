// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// Observed audio and video state for a page.
public struct PageMedia: Equatable, Sendable {
    /// Native controllable-session state can be unavailable. This is not an
    /// assertion that capture, uploads or every page player are inactive.
    public var isKnown: Bool
    public var canPlay: Bool
    public var canPause: Bool
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Audio or video longer than a notification sound, playing or paused, or a streaming
    /// service's player.
    public var hasMedia: Bool
    /// Something plays with sound.
    public var isAudible: Bool
    /// The player plays, with sound or muted by the page.
    public var isPlaying: Bool
    /// Something plays, and everything playing is muted or at volume 0 by the page itself.
    public var isMuted: Bool
    public var hasVideo: Bool
    public var isPlayingVideo: Bool
    /// Previous and Next can act: the page set `navigator.mediaSession` handlers for them, or
    /// YouTube's player shows its buttons.
    public var handlesPreviousTrack: Bool
    public var handlesNextTrack: Bool

    public init(isKnown: Bool = true, hasMedia: Bool = false, isAudible: Bool = false, isPlaying: Bool = false, isMuted: Bool = false,
                hasVideo: Bool = false, isPlayingVideo: Bool = false,
                handlesPreviousTrack: Bool = false, handlesNextTrack: Bool = false,
                canPlay: Bool = true, canPause: Bool = true, title: String? = nil, artist: String? = nil, album: String? = nil) {
        self.isKnown = isKnown
        self.canPlay = canPlay; self.canPause = canPause
        self.title = title; self.artist = artist; self.album = album
        self.hasMedia = hasMedia
        self.isAudible = isAudible
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.hasVideo = hasVideo
        self.isPlayingVideo = isPlayingVideo
        self.handlesPreviousTrack = handlesPreviousTrack
        self.handlesNextTrack = handlesNextTrack
    }
}
