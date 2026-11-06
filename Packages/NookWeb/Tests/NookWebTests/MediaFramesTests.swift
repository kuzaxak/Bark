// Licensed under GPL-3.0. See LICENSE.
import Testing
@testable import NookWeb

/// A page's media is what any of its frames holds: a player embedded in an article counts as
/// much as one in the page itself, and each control acts in the frame it belongs to. Whether the
/// page plays sound is WebKit's to say when it can, since a frame's report can fail to arrive.
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
        let media = frames.media(audible: nil)
        #expect(media.hasMedia && media.isAudible && media.isPlaying && media.handlesNextTrack)
        #expect(!media.handlesPreviousTrack)
    }

    @Test func webKitSaysWhetherThePagePlaysSound() {
        var frames = MediaFrames<String>()
        frames.report("main", frame: "main", media: paused)
        let heard = frames.media(audible: true)
        #expect(heard.isAudible && heard.isPlaying, "a report that never came does not silence the page")
        frames.report("main", frame: "main", media: sounding)
        #expect(!frames.media(audible: false).isAudible)
        #expect(frames.media(audible: nil).isAudible, "the frames decide without WebKit's signal")
    }

    @Test func aPageThatMutedItselfIsMuted() {
        var frames = MediaFrames<String>()
        frames.report("main", frame: "main", media: mutedByPage)
        #expect(frames.media(audible: false).isMuted)
        #expect(frames.media(audible: false).isPlaying, "still playing, only muted")
        frames.report("embed", frame: "embed", media: sounding)
        #expect(!frames.media(audible: true).isMuted, "something else on the page plays with sound")
    }

    @Test func aFrameThatGoesTakesItsMediaWithIt() {
        var frames = MediaFrames<String>()
        frames.report("embed", frame: "embed", media: sounding)
        frames.report("embed", frame: "embed", media: nil)
        #expect(frames.media(audible: nil) == PageMedia())
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
