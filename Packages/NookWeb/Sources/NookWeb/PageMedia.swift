// Licensed under GPL-3.0. See LICENSE.
//
//  PageMedia.swift
//  NookWeb
//
//  What a page's audio and video are doing, from what each of its frames reports
//  (`MediaScript`). Foundation only, so `Checks/MiniPlayerFramesCheck.swift` builds it.
//

import Foundation

/// What a frame's, or a whole page's, audio and video are doing.
public struct PageMedia: Equatable, Sendable {
    /// Audio or video, playing or paused, or a streaming service's player.
    public var hasMedia: Bool
    /// Something plays with sound.
    public var isAudible: Bool
    public var hasVideo: Bool
    public var isPlayingVideo: Bool
    /// Previous and Next can act: the page set `navigator.mediaSession` handlers for them, or
    /// YouTube's player shows its buttons.
    public var handlesPreviousTrack: Bool
    public var handlesNextTrack: Bool

    public init(hasMedia: Bool = false, isAudible: Bool = false,
                hasVideo: Bool = false, isPlayingVideo: Bool = false,
                handlesPreviousTrack: Bool = false, handlesNextTrack: Bool = false) {
        self.hasMedia = hasMedia
        self.isAudible = isAudible
        self.hasVideo = hasVideo
        self.isPlayingVideo = isPlayingVideo
        self.handlesPreviousTrack = handlesPreviousTrack
        self.handlesNextTrack = handlesNextTrack
    }

    /// A frame's report, as `MediaScript.reporter` posts it.
    public init(report: [String: Any]) {
        func flag(_ key: String) -> Bool { report[key] as? Bool ?? false }
        self.init(hasMedia: flag("hasMedia"), isAudible: flag("isAudible"),
                  hasVideo: flag("hasVideo"), isPlayingVideo: flag("isPlayingVideo"),
                  handlesPreviousTrack: flag("previousTrack"), handlesNextTrack: flag("nextTrack"))
    }
}

/// The media reports of a page's frames, keyed by the id each frame's script made up, combined
/// into the page's, and the frame each control acts in. `Frame` is WebKit's `WKFrameInfo` in the app.
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

    public var media: PageMedia {
        let all = entries.values.map(\.media)
        return PageMedia(
            hasMedia: all.contains { $0.hasMedia }, isAudible: all.contains { $0.isAudible }, hasVideo: all.contains { $0.hasVideo },
            isPlayingVideo: all.contains { $0.isPlayingVideo },
            handlesPreviousTrack: all.contains { $0.handlesPreviousTrack },
            handlesNextTrack: all.contains { $0.handlesNextTrack })
    }

    /// Where Pause acts: every frame playing sound.
    public var pauseTargets: [Frame] {
        ranked.filter { $0.media.isAudible }.map(\.frame)
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
