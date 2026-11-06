// Licensed under GPL-3.0. See LICENSE.
//
//  MediaScript.swift
//  NookWeb
//
//  The page scripts behind a page's media state and the sidebar's mini player. Both run in
//  every frame, in the page's world. Foundation only, so `Checks/MiniPlayerFramesCheck.swift`
//  runs them in WebKit.
//

import Foundation

public enum MediaScript {
    /// At document start: tracks the frame's audio and video, both in the document and played
    /// outside it (`new Audio()`, whose events reach no one else), and the handlers the page
    /// sets on `navigator.mediaSession`, which WebKit gives no way to read. `window.__nookMedia`
    /// reports and controls them; a `nookmedia` event on the document says something changed.
    public static let recorder = """
        // Nook Media
        (() => {
            if (window.__nookMedia || !window.HTMLMediaElement) return;
            const types = ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'loadeddata',
                'canplay', 'volumechange', 'encrypted', 'webkitneedkey'];
            const inDocument = new Set();
            const outside = new Set();
            const watched = new WeakSet();
            const handlers = new Map();
            let lastAudible = null;
            // Elements that have been the player, and each one's volume before it was last muted.
            const players = new WeakSet();
            const volumes = new WeakMap();
            const changed = () => document.dispatchEvent(new Event('nookmedia'));
            const playing = element => !element.paused && !element.ended && element.readyState >= 2;
            const audible = element => playing(element) && !element.muted && element.volume > 0;
            function heard(element) {
                lastAudible = new WeakRef(element);
                players.add(element);
            }

            function seen(element) {
                if (element.isConnected) inDocument.add(element);
                if (!element.muted && element.volume > 0) volumes.set(element, element.volume);
                if (audible(element) && isPlayer(element)) heard(element);
                changed();
            }
            // Media events do not bubble, so the document hears its own elements' in the capture phase.
            types.forEach(type => document.addEventListener(type, event => {
                if (event.target instanceof HTMLMediaElement) seen(event.target);
            }, true));
            const play = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function () {
                if (!this.isConnected && !watched.has(this)) {
                    watched.add(this);
                    outside.add(new WeakRef(this));
                    types.forEach(type => this.addEventListener(type, () => seen(this)));
                }
                return play.apply(this, arguments);
            };
            if (window.MediaSession) {
                const setActionHandler = MediaSession.prototype.setActionHandler;
                MediaSession.prototype.setActionHandler = function (action, handler) {
                    setActionHandler.call(this, action, handler);
                    if (handler) handlers.set(action, handler); else handlers.delete(action);
                    changed();
                };
            }

            // Some streaming services play through Web Audio, with no media element to watch.
            const host = location.hostname;
            const streamingSelector = host.endsWith('spotify.com') ? '[data-testid="control-button-playpause"]'
                : host.endsWith('soundcloud.com') ? '.playControl'
                : host === 'music.apple.com' ? '.web-chrome-playback-controls' : null;
            let streamingControl = null;
            const controlObserver = new MutationObserver(changed);
            function refreshStreamingControl() {
                if (!streamingSelector || streamingControl?.isConnected) return;
                controlObserver.disconnect();
                streamingControl = document.querySelector(streamingSelector);
                if (streamingControl) controlObserver.observe(streamingControl, {
                    attributes: true, childList: true, subtree: true, attributeFilter: ['aria-label', 'class']
                });
            }
            new MutationObserver(mutations => {
                let found = false;
                for (const mutation of mutations) {
                    for (const node of mutation.addedNodes) {
                        if (node.nodeType !== 1) continue;
                        const media = node instanceof HTMLMediaElement ? [node] : node.querySelectorAll('audio, video');
                        for (const element of media) { inDocument.add(element); found = true; }
                    }
                    if (mutation.removedNodes.length && inDocument.size) found = true;
                }
                if (streamingSelector && !streamingControl?.isConnected) found = true;
                if (found) changed();
            }).observe(document, {childList: true, subtree: true});

            // Sounds of ten seconds or less are notification chimes, not players. An element outside
            // the document counts only once its length is known. One that has been the player stays
            // one on a short source, such as YouTube's six-second bumper ads in its own video.
            const isPlayer = element => players.has(element)
                || (element.isConnected ? !(element.duration <= 10) : element.duration > 10);
            function elements() {
                for (const element of inDocument) if (!element.isConnected) inDocument.delete(element);
                const list = [...inDocument];
                for (const ref of outside) {
                    const element = ref.deref();
                    if (!element) { outside.delete(ref); continue; }
                    if (!element.isConnected) list.push(element);
                }
                return list.filter(isPlayer);
            }

            const youtube = host === 'youtube.com' || host.endsWith('.youtube.com');
            function youtubeButton(forward) {
                const button = youtube && document.querySelector(forward ? '.ytp-next-button' : '.ytp-prev-button');
                return button && getComputedStyle(button).display !== 'none' ? button : null;
            }
            const canSkip = forward => handlers.has(forward ? 'nexttrack' : 'previoustrack') || !!youtubeButton(forward);

            const frame = Math.random().toString(36).slice(2) + Date.now().toString(36);
            // The element that last played with sound, still here: the frame's player.
            function player(list) {
                const last = lastAudible?.deref();
                return list.includes(last) ? last : null;
            }

            function state() {
                refreshStreamingControl();
                const list = elements();
                const video = list.filter(element => element instanceof HTMLVideoElement);
                const nowPlaying = list.filter(playing);
                const sounding = nowPlaying.find(audible);
                if (sounding) heard(sounding);
                const current = player(list);
                let isAudible = !!sounding;
                let isPlaying = isAudible || nowPlaying.includes(current);
                if (streamingControl) {
                    const label = (streamingControl.getAttribute('aria-label') || '').toLowerCase();
                    const streaming = label.includes('pause') || streamingControl.classList.contains('playing') ||
                        !!streamingControl.querySelector('button[aria-label*="pause"], button[aria-label*="Pause"]');
                    isAudible ||= streaming;
                    isPlaying ||= streaming;
                }
                return {
                    frame, hasMedia: list.length > 0 || !!streamingControl, isAudible, isPlaying,
                    isMuted: !isAudible && nowPlaying.includes(current) && (current.muted || current.volume === 0),
                    hasVideo: video.length > 0, isPlayingVideo: video.some(playing),
                    previousTrack: canSkip(false), nextTrack: canSkip(true),
                };
            }

            // Each control answers with the frame's new state.
            async function toggle(play) {
                const list = elements();
                if (play) {
                    const target = player(list)
                        ?? list.find(element => !element.muted && element.currentTime > 0 && !element.ended)
                        ?? list.find(element => !element.muted) ?? list[0];
                    if (target) await Promise.race([target.play().catch(() => {}), new Promise(done => setTimeout(done, 300))]);
                    else handlers.get('play')?.({action: 'play'});
                    return state();
                }
                const current = player(list);
                const stopping = list.filter(element => element === current ? playing(element) : audible(element));
                if (stopping.length) stopping.forEach(element => element.pause());
                else handlers.get('pause')?.({action: 'pause'});
                return state();
            }

            function skip(forward) {
                const action = forward ? 'nexttrack' : 'previoustrack';
                const handler = handlers.get(action);
                if (handler) handler({action});
                else youtubeButton(forward)?.click();
                return state();
            }

            // Undoes the page's mute of its player, at the volume it had before. YouTube's own button
            // does it on YouTube, so the player's controls agree.
            function unmute() {
                const current = player(elements());
                if (!current) return state();
                const button = youtube && document.querySelector('.ytp-mute-button');
                if (button) {
                    button.click();
                    return state();
                }
                current.muted = false;
                if (current.volume === 0) current.volume = volumes.get(current) ?? 1;
                return state();
            }

            Object.defineProperty(window, '__nookMedia', {value: Object.freeze({frame, state, toggle, skip, unmute})});
        })();
        """

    /// At document end: posts the frame's state to `handler` whenever it changes, under the
    /// frame's id, and `gone` when the document goes. A frame that never holds media stays quiet.
    /// Nothing depends on every post arriving: WebKit's own audio signal makes the app ask again.
    public static func reporter(handler: String) -> String {
        """
        // Nook Media Report
        (() => {
            const media = window.__nookMedia;
            if (!media || window.__nookMediaReporting) return;
            window.__nookMediaReporting = true;
            const post = message => window.webkit?.messageHandlers?.['\(handler)']?.postMessage(message);
            const frame = media.frame;
            let pending = null;
            let last = null;
            function report() {
                pending = null;
                const state = media.state();
                const serialized = JSON.stringify(state);
                const quiet = !state.hasMedia && !state.isAudible && !state.previousTrack && !state.nextTrack;
                if (serialized === last || (last === null && quiet)) return;
                last = serialized;
                post(state);
            }
            const schedule = () => { if (pending === null) pending = setTimeout(report, 50); };
            document.addEventListener('nookmedia', schedule);
            document.addEventListener('visibilitychange', schedule);
            // Back from the back/forward cache: the page's commit cleared what this frame had reported.
            window.addEventListener('pageshow', event => { if (event.persisted) { last = null; schedule(); } });
            window.addEventListener('pagehide', () => { if (last !== null) post({frame, gone: true}); });
            report();
        })();
        """
    }
}
