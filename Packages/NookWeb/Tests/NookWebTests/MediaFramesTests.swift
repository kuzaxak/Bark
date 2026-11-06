// Licensed under GPL-3.0. See LICENSE.
import Testing
@testable import NookWeb

/// A page's media is what any of its frames holds: a player embedded in an article counts as
/// much as one in the page itself, and each control acts in the frame it belongs to. The bar goes
/// by the frames alone; WebKit's own signal only adds to the tab row's speaker.
struct MediaFramesTests {
    let silent = PageMedia()
    let mutedClip = PageMedia(hasMedia: true, hasVideo: true, isPlayingVideo: true)
    let sounding = PageMedia(hasMedia: true, isAudible: true, isPlaying: true, handlesNextTrack: true)
    let paused = PageMedia(hasMedia: true, handlesNextTrack: true)
    let mutedByPage = PageMedia(hasMedia: true, isPlaying: true, isMuted: true)

    @Test func thePageHasWhatAnyFrameHas() {
        var frames = MediaFrames<String>()
        frames.report("main", frame: "main", media: silent)
        frames.report("embed", frame: "embed", media: sounding)
        #expect(frames.media.hasMedia && frames.media.isAudible && frames.media.isPlaying && frames.media.handlesNextTrack)
        #expect(!frames.media.handlesPreviousTrack)
    }

    /// The tab row's speaker and the unload rules: on when WebKit hears the page or a frame says
    /// it plays sound. WebKit's "no" never cancels a frame's "yes", since its signal can go quiet.
    @Test func theSpeakerIsOnWhenWebKitOrAFrameHearsSound() {
        var frames = MediaFrames<String>()
        frames.report("main", frame: "main", media: paused)
        #expect(frames.isAudible(webKit: true), "a chime, or a frame whose report never came")
        #expect(!frames.isAudible(webKit: false))
        #expect(!frames.isAudible(webKit: nil))
        #expect(!frames.media.isAudible && !frames.media.isPlaying, "the bar goes by the frames alone")
        frames.report("main", frame: "main", media: sounding)
        #expect(frames.isAudible(webKit: false))
        #expect(frames.isAudible(webKit: nil))
    }

    @Test func aPageThatMutedItselfIsMuted() {
        var frames = MediaFrames<String>()
        frames.report("main", frame: "main", media: mutedByPage)
        #expect(frames.media.isMuted)
        #expect(frames.media.isPlaying, "still playing, only muted")
        frames.report("embed", frame: "embed", media: sounding)
        #expect(!frames.media.isMuted, "something else on the page plays with sound")
    }

    @Test func aFrameThatGoesTakesItsMediaWithIt() {
        var frames = MediaFrames<String>()
        frames.report("embed", frame: "embed", media: sounding)
        frames.report("embed", frame: "embed", media: nil)
        #expect(frames.media == PageMedia())
    }

    @Test func pauseActsWhereThePlayerPlays() {
        var frames = MediaFrames<String>()
        frames.report("ad", frame: "ad", media: mutedClip)
        frames.report("main", frame: "main", media: mutedByPage)
        frames.report("embed", frame: "embed", media: sounding)
        #expect(Set(frames.pauseTargets) == ["main", "embed"], "a muted clip is left playing")
    }

    @Test func playResumesTheFrameThatLastPlayedSound() {
        var frames = MediaFrames<String>()
        frames.report("embed", frame: "embed", media: sounding)
        frames.report("embed", frame: "embed", media: paused)
        frames.report("main", frame: "main", media: mutedClip)
        #expect(frames.resumeTarget == "embed")
    }

    @Test func previousAndNextActInTheFrameWithTheHandler() {
        var frames = MediaFrames<String>()
        frames.report("first", frame: "first", media: sounding)
        frames.report("first", frame: "first", media: paused)
        frames.report("second", frame: "second", media: sounding)
        frames.report("main", frame: "main", media: silent)
        #expect(frames.trackTarget(forward: true) == "second", "the frame that played sound last")
        #expect(frames.trackTarget(forward: false) == nil)
    }

    @Test func everyKnownFrameCanBeAskedAgain() {
        var frames = MediaFrames<String>()
        frames.report("main", frame: "main", media: sounding)
        frames.report("embed", frame: "embed", media: paused)
        #expect(Set(frames.frames) == ["main", "embed"])
    }

    @Test func aFrameReportReadsWhatTheScriptPosts() {
        let media = PageMedia(report: ["frame": "a1", "hasMedia": true, "isAudible": true, "isPlaying": true,
                                       "isMuted": false, "hasVideo": true, "isPlayingVideo": false,
                                       "previousTrack": false, "nextTrack": true])
        #expect(media == PageMedia(hasMedia: true, isAudible: true, isPlaying: true, hasVideo: true, handlesNextTrack: true))
    }

    /// The bar's mute button: Nook's tab mute first, then the page's own, else Nook mutes the tab.
    @Test func muteUndoesWhicheverMuteIsOn() {
        #expect(MuteAction.next(tabMuted: true, pageMuted: true) == .unmuteTab)
        #expect(MuteAction.next(tabMuted: false, pageMuted: true) == .unmutePage)
        #expect(MuteAction.next(tabMuted: false, pageMuted: false) == .muteTab)
    }
}
