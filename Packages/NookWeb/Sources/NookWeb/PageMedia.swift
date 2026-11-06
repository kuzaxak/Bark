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

/// The media reports of a page's frames, one entry per frame, combined into the page's, and the
/// frame each control acts in. `Frame` is WebKit's `WKFrameInfo?` in the app, nil being the main
/// frame; `key` tells frames apart, and `document` the documents a frame has shown, by the id each
/// document's media script made up.
public struct MediaFrames<Frame> {
    private struct Entry {
        var frame: Frame
        var document: String
        var media: PageMedia
        var reportedAt: Int
        var audibleAt: Int?
    }

    private var entries: [AnyHashable: Entry] = [:]
    private var clock = 0

    public init() {}

    /// A frame's report replaces its last one, from whichever document. `media` nil: `document`
    /// went away, which removes the entry only while it is still that document's.
    public mutating func report(_ key: AnyHashable, document: String, frame: Frame, media: PageMedia?) {
        let previous = entries[key]
        guard let media else {
            if previous?.document == document { entries[key] = nil }
            return
        }
        clock += 1
        let earlier = previous?.document == document ? previous : nil
        let audibleAt = media.isAudible && earlier?.media.isAudible != true ? clock : earlier?.audibleAt
        entries[key] = Entry(frame: frame, document: document, media: media, reportedAt: clock, audibleAt: audibleAt)
    }

    /// The frame is gone, or its document no longer runs the media script.
    public mutating func forget(_ key: AnyHashable) {
        entries[key] = nil
    }

    /// What one frame last reported.
    public func frameMedia(_ key: AnyHashable) -> PageMedia? {
        entries[key]?.media
    }

    /// The page's media as its frames report it: what the bar goes by.
    public var media: PageMedia {
        let all = entries.values.map(\.media)
        let isAudible = all.contains { $0.isAudible }
        return PageMedia(
            hasMedia: all.contains { $0.hasMedia }, isAudible: isAudible,
            isPlaying: isAudible || all.contains { $0.isPlaying },
            isMuted: !isAudible && all.contains { $0.isMuted },
            hasVideo: all.contains { $0.hasVideo }, isPlayingVideo: all.contains { $0.isPlayingVideo },
            handlesPreviousTrack: all.contains { $0.handlesPreviousTrack },
            handlesNextTrack: all.contains { $0.handlesNextTrack })
    }

    /// Whether the page plays sound, for the tab row's speaker and the unload rules: WebKit's own
    /// signal (`webKit`, nil when unknown) or any frame's report. WebKit's false never cancels a
    /// frame's true, and its true covers sounds no frame counts, such as a notification chime.
    public func isAudible(webKit: Bool?) -> Bool {
        webKit == true || media.isAudible
    }

    /// Every frame that has reported, by key, to ask again.
    public var frames: [AnyHashable: Frame] {
        entries.mapValues(\.frame)
    }

    /// Where Pause acts: every frame whose player plays.
    public var pauseTargets: [Frame] {
        ranked.filter { $0.media.isPlaying }.map(\.frame)
    }

    /// Where unmuting the page acts: every frame whose player plays muted by the page.
    public var mutedTargets: [Frame] {
        ranked.filter { $0.media.isMuted }.map(\.frame)
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

/// Asking a page's frames for their state again: one ask at a time, and any number of asks made
/// meanwhile run once more after it, so the last change is never missed.
public struct ReaskGate: Sendable {
    private var inFlight = false
    private var queued = false

    public init() {}

    /// True: start an ask now.
    public mutating func request() -> Bool {
        if inFlight {
            queued = true
            return false
        }
        inFlight = true
        return true
    }

    /// The ask in flight finished. True: start another now.
    public mutating func finished() -> Bool {
        if queued {
            queued = false
            return true
        }
        inFlight = false
        return false
    }
}
