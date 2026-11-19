// Licensed under GPL-3.0. See LICENSE.
//
//  MediaControlsView.swift
//  Nook
//
//  Created by apelreflex on 13/10/2025.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

/// Arc's mini player above the space bar: the page playing in another tab of this window, with
/// its site's icon, which goes to the tab, then Previous, Play or Pause, Next and Mute.
/// `MiniPlayer` decides which page it is; `TabsController` keeps it up to date.
struct MediaControlsView: View {
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovering = false

    var body: some View {
        Group {
            if let itemID = windowState.miniPlayer.itemID, let page = tabs.session(for: itemID) {
                bar(page)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(NookDesign.Motion.standard, value: windowState.miniPlayer.itemID)
    }

    private func bar(_ page: PageSession) -> some View {
        controls(page)
        .labelStyle(.iconOnly)
        .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.mediaControl))
        .padding(.horizontal, NookDesign.Spacing.md)
        .padding(.vertical, NookDesign.Spacing.sm)
        .nookTabSurface(selected: true)
        .overlay(alignment: .topLeading) {
            if isHovering {
                closeButton
            }
        }
        .onHoverTracking { hovering in
            withAnimation(NookDesign.Motion.quick) { isHovering = hovering }
        }
        // A tracking area removed under the pointer never reports it leaving.
        .onDisappear { isHovering = false }
        // The close button shows only under the pointer; VoiceOver reaches it here.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini Player")
        .accessibilityAction(named: "Close", dismiss)
        .padding(.horizontal, NookDesign.Spacing.sidebarInset)
    }

    private func dismiss() {
        withAnimation(NookDesign.Motion.standard) { windowState.miniPlayer.dismiss() }
    }

    private func controls(_ page: PageSession) -> some View {
        let media = page.media
        let track = [media.title, media.artist, media.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
        let label = track.isEmpty ? page.title : track
        return HStack(spacing: 0) {
            Button {
                withAnimation(NookDesign.Motion.standard) { tabs.select(page.itemID, in: windowState) }
            } label: {
                page.favicon
                    .resizable()
                    .scaledToFit()
                    .frame(width: NookDesign.Size.favicon, height: NookDesign.Size.favicon)
                    .clipShape(NookDesign.Radius.shape(NookDesign.Radius.xs))
            }
            .help(label)
            .accessibilityLabel("Go to \(label)")
            Spacer(minLength: 0)
            Button("Previous", systemImage: "backward.end.fill") { page.skipTrack(forward: false) }
                .help("Previous")
                .disabled(!media.handlesPreviousTrack)
            Spacer(minLength: 0)
            Button(media.isPlaying ? "Pause" : "Play", systemImage: media.isPlaying ? "pause.fill" : "play.fill") {
                page.togglePlayback()
            }
            .help(media.isPlaying ? "Pause" : "Play")
            .disabled(!media.isKnown || (media.isPlaying ? !media.canPause : !media.canPlay))
            Spacer(minLength: 0)
            Button("Next", systemImage: "forward.end.fill") { page.skipTrack(forward: true) }
                .help("Next")
                .disabled(!media.handlesNextTrack)
            Spacer(minLength: 0)
            let muted = page.isAudioMuted || media.isMuted
            Button(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                page.toggleSound()
            }
            .help(muted ? "Unmute" : "Mute")
        }
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .font(NookDesign.Font.micro)
        .foregroundStyle(.secondary)
        .frame(width: NookDesign.Size.cornerButton, height: NookDesign.Size.cornerButton)
        .background(NookDesign.Surface.raised, in: Circle())
        .overlay(Circle().strokeBorder(NookDesign.Surface.hairline, lineWidth: NookDesign.Size.hairlineWidth))
        .contentShape(Circle())
        .buttonStyle(.plain)
        .help("Close")
        .offset(x: -NookDesign.Spacing.xs, y: -NookDesign.Spacing.xs)
        .transition(.opacity)
    }
}
