// Licensed under GPL-3.0. See LICENSE.
//
//  PageMedia.swift
//  NookWeb
//
//  What a page's audio and video are doing, from what each of its frames reports
//  (`MediaScript`) and from WebKit. Foundation only, so `Checks/MiniPlayerFramesCheck.swift`
//  builds it.
//

import Foundation

/// What a frame's, or a whole page's, audio and video are doing.
public struct PageMedia: Equatable, Sendable {
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

    public init(hasMedia: Bool = false, isAudible: Bool = false, isPlaying: Bool = false, isMuted: Bool = false,
                hasVideo: Bool = false, isPlayingVideo: Bool = false,
                handlesPreviousTrack: Bool = false, handlesNextTrack: Bool = false) {
        self.hasMedia = hasMedia
        self.isAudible = isAudible
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.hasVideo = hasVideo
        self.isPlayingVideo = isPlayingVideo
        self.handlesPreviousTrack = handlesPreviousTrack
        self.handlesNextTrack = handlesNextTrack
    }

    /// A frame's report, as `MediaScript`'s `state()` gives it.
    public init(report: [String: Any]) {
        func flag(_ key: String) -> Bool { report[key] as? Bool ?? false }
        self.init(hasMedia: flag("hasMedia"), isAudible: flag("isAudible"), isPlaying: flag("isPlaying"),
                  isMuted: flag("isMuted"), hasVideo: flag("hasVideo"), isPlayingVideo: flag("isPlayingVideo"),
                  handlesPreviousTrack: flag("previousTrack"), handlesNextTrack: flag("nextTrack"))
    }
}

/// What the mini player's mute button does next.
public enum MuteAction: Equatable, Sendable {
    case muteTab, unmuteTab, unmutePage

    /// Nook's own tab mute is undone first, then the page's; with neither on, Nook mutes the tab.
    public static func next(tabMuted: Bool, pageMuted: Bool) -> MuteAction {
        if tabMuted { return .unmuteTab }
        return pageMuted ? .unmutePage : .muteTab
    }
}

/// The media reports of a page's frames, keyed by the id each frame's script made up, combined
/// into the page's, and the frame each control acts in. `Frame` is WebKit's `WKFrameInfo?` in the
/// app, nil being the main frame.
public struct MediaFrames<Frame> {
    private struct Entry {
        var frame: Frame
        var media: PageMedia
        var reportedAt: Int
        var audibleAt: Int?
    }

    private var entries: [String: Entry] = [:]
    private var clock = 0

    public init() {}

    /// `media` nil: the frame's document went away.
    public mutating func report(_ id: String, frame: Frame, media: PageMedia?) {
        guard let media else {
            entries[id] = nil
            return
        }
        clock += 1
        let previous = entries[id]
        let audibleAt = media.isAudible && previous?.media.isAudible != true ? clock : previous?.audibleAt
        entries[id] = Entry(frame: frame, media: media, reportedAt: clock, audibleAt: audibleAt)
    }

    /// The page's media. `audible` is WebKit's own word on whether the page plays sound, which
    /// holds even when a frame's report was lost; nil leaves it to the frames.
    public func media(audible: Bool?) -> PageMedia {
        let all = entries.values.map(\.media)
        let framesAudible = all.contains { $0.isAudible }
        let isAudible = audible ?? framesAudible
        return PageMedia(
            hasMedia: all.contains { $0.hasMedia }, isAudible: isAudible,
            isPlaying: isAudible || all.contains { $0.isPlaying },
            isMuted: !framesAudible && all.contains { $0.isMuted },
            hasVideo: all.contains { $0.hasVideo }, isPlayingVideo: all.contains { $0.isPlayingVideo },
            handlesPreviousTrack: all.contains { $0.handlesPreviousTrack },
            handlesNextTrack: all.contains { $0.handlesNextTrack })
    }

    /// Every frame that has reported, to ask again.
    public var frames: [Frame] {
        entries.values.map(\.frame)
    }

    /// Where Pause acts: every frame whose player plays.
    public var pauseTargets: [Frame] {
        ranked.filter { $0.media.isPlaying }.map(\.frame)
    }

    /// Where Play acts: the frame that last played sound, else the one that last reported media.
    public var resumeTarget: Frame? {
        ranked.first { $0.media.hasMedia }?.frame
    }

    /// Where Previous or Next acts: of the frames that can, the one that last played sound.
    public func trackTarget(forward: Bool) -> Frame? {
        ranked.first { forward ? $0.media.handlesNextTrack : $0.media.handlesPreviousTrack }?.frame
    }

    /// Frames that played sound most recently first, then those that reported most recently.
    private var ranked: [Entry] {
        entries.values.sorted { ($0.audibleAt ?? 0, $0.reportedAt) > ($1.audibleAt ?? 0, $1.reportedAt) }
    }
}
