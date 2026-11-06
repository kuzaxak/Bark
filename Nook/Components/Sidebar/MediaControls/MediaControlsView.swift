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
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovering = false

    /// The video showing above carries its own controls, so the bar stands down while it is up.
    private var isVideoShowing: Bool {
        windowState.sidebarPiPController?.isShowing == true
    }

    var body: some View {
        Group {
            if !isVideoShowing, let itemID = windowState.miniPlayer.itemID, let page = tabs.session(for: itemID) {
                bar(page)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(NookDesign.Motion.standard, value: windowState.miniPlayer.itemID)
        .animation(NookDesign.Motion.standard, value: isVideoShowing)
        // Minimising the sidebar's video hands its page the bar.
        .onChange(of: isVideoShowing) { wasShowing, isShowing in
            guard wasShowing, !isShowing, let itemID = windowState.sidebarPiPController?.barSession?.itemID else { return }
            windowState.miniPlayer.takeOver(itemID)
        }
    }

    private func bar(_ page: PageSession) -> some View {
        ViewThatFits(in: .horizontal) {
            controls(page, showsVideoButton: page.hasVideoContent)
            controls(page, showsVideoButton: false)
        }
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
        .padding(.horizontal, NookDesign.Spacing.sidebarInset)
    }

    private func controls(_ page: PageSession, showsVideoButton: Bool) -> some View {
        let media = page.media
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
            .help(page.title)
            .accessibilityLabel("Go to \(page.title)")
            Spacer(minLength: 0)
            Button("Previous", systemImage: "backward.end.fill") { page.skipTrack(forward: false) }
                .help("Previous")
                .disabled(!media.handlesPreviousTrack)
            Spacer(minLength: 0)
            Button(media.isAudible ? "Pause" : "Play", systemImage: media.isAudible ? "pause.fill" : "play.fill") {
                page.togglePlayback()
            }
            .help(media.isAudible ? "Pause" : "Play")
            Spacer(minLength: 0)
            Button("Next", systemImage: "forward.end.fill") { page.skipTrack(forward: true) }
                .help("Next")
                .disabled(!media.handlesNextTrack)
            Spacer(minLength: 0)
            Button(page.isAudioMuted ? "Unmute" : "Mute",
                   systemImage: page.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                page.toggleMute()
            }
            .help(page.isAudioMuted ? "Unmute" : "Mute")
            if showsVideoButton {
                Spacer(minLength: 0)
                Button("Maximize", systemImage: "arrow.up.left.and.arrow.down.right") { maximize(page) }
                    .help("Show video in the sidebar")
            }
        }
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark") {
            withAnimation(NookDesign.Motion.standard) { windowState.miniPlayer.dismiss() }
        }
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

    /// The counterpart of the video's minimise button. Falls back to system picture-in-picture
    /// when the video cannot be isolated, or the sidebar is only the hover overlay.
    private func maximize(_ page: PageSession) {
        // Private tabs never report leaving, and another window's tab or PiP would lose its view.
        guard let controller = windowState.sidebarPiPController, !page.isPrivate,
            !tabs.isOnScreen(page.itemID),
            let webView = browserManager.getWebView(for: page.itemID, in: windowState.id) ?? page.assignedWebView
        else { return }
        guard windowState.isSidebarVisible else { return PiPManager.shared.setPiP(true, for: page, webView: webView) }
        if page.hasPiPActive { PiPManager.shared.setPiP(false, for: page, webView: webView) }
        controller.enter(session: page, webView: webView, automatic: false) {
            PiPManager.shared.setPiP(true, for: page, webView: webView)
        }
    }
}
