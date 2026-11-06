// Licensed under GPL-3.0. See LICENSE.
import Testing
@testable import NookWeb

/// A page's media is what any of its frames holds: a player embedded in an article counts as
/// much as one in the page itself, and each control acts in the frame it belongs to.
struct MediaFramesTests {
    let silent = PageMedia()
    let muted = PageMedia(hasMedia: true, hasVideo: true, isPlayingVideo: true)
    let sounding = PageMedia(hasMedia: true, isAudible: true, handlesNextTrack: true)
    let paused = PageMedia(hasMedia: true, handlesNextTrack: true)

    @Test func thePageHasWhatAnyFrameHas() {
        var frames = MediaFrames<String>()
        frames.report("main", frame: "main", media: silent)
        frames.report("embed", frame: "embed", media: sounding)
        #expect(frames.media.hasMedia && frames.media.isAudible && frames.media.handlesNextTrack)
        #expect(!frames.media.handlesPreviousTrack)
    }

    @Test func aFrameThatGoesTakesItsMediaWithIt() {
        var frames = MediaFrames<String>()
        frames.report("embed", frame: "embed", media: sounding)
        frames.report("embed", frame: "embed", media: nil)
        #expect(frames.media == PageMedia())
    }

    @Test func pauseActsWhereSoundPlays() {
        var frames = MediaFrames<String>()
        frames.report("main", frame: "main", media: muted)
        frames.report("embed", frame: "embed", media: sounding)
        #expect(frames.pauseTargets == ["embed"], "a muted clip is left playing")
    }

    @Test func playResumesTheFrameThatLastPlayedSound() {
        var frames = MediaFrames<String>()
        frames.report("embed", frame: "embed", media: sounding)
        frames.report("embed", frame: "embed", media: paused)
        frames.report("main", frame: "main", media: muted)
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

    @Test func aFrameReportReadsWhatTheScriptPosts() {
        let media = PageMedia(report: ["frame": "a1", "hasMedia": true, "isAudible": true,
                                       "hasVideo": true, "isPlayingVideo": false, "previousTrack": false, "nextTrack": true])
        #expect(media == PageMedia(hasMedia: true, isAudible: true, hasVideo: true, handlesNextTrack: true))
    }
}
