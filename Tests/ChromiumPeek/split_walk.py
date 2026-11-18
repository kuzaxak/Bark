#!/usr/bin/env python3
"""Verify Peek from a pre-existing split in a signed Bark window."""

import json
import signal
import sys

from walk import serve, source_point
from signed_walk import run_walk, wait_for


def exercise(screen, process, events, output):
    def event(page, kind, since=0, **fields):
        return wait_for(f"{page} did not report {kind} {fields}", lambda: next((
            row for row in events[since:] if row["page"] == page and row["event"] == kind
            and all(row.get(key) == value for key, value in fields.items())), None), process)

    def open_peek(source, link_point):
        start = len(events)
        screen.click(link_point, screen.shift)
        event("/source", "link", start, documentID=source["documentID"], trusted=True, shift=True)
        page = event("/target", "ready", start)
        wait_for("Missing Peek card", lambda: screen.button("Open in Split View"), process)
        if len(screen.windows()) != 1:
            raise RuntimeError("Peek opened a separate window")
        return page

    source = event("/source", "ready")
    wait_for("The seeded window did not reach its saved size",
             lambda: any(row["kCGWindowBounds"]["Width"] == 900 for row in screen.windows()), process)
    sibling = open_peek(source, source_point(source, "linkPoint"))
    start = len(events)
    screen.press_button(screen.button("Open in Split View"))
    wait_for("The sibling did not enter the split", lambda: screen.button("Open in Split View") is None, process)
    pane = event("/source", "resize", start, documentID=source["documentID"])
    if pane["viewport"] >= source["viewport"]:
        raise RuntimeError("The original source did not become a smaller split pane")

    start = len(events)
    draft_point = source_point(pane, "draftPoint")
    screen.click(draft_point)
    event("/source", "page-pointer", start, documentID=source["documentID"], trusted=True)
    screen.click(draft_point)
    screen.key("p")
    event("/source", "input", start, documentID=source["documentID"], value="p", trusted=True)
    screen.click((source_point(source, "draftPoint")[0], 360))
    screen.keys["ArrowDown"] = 125
    screen.key("ArrowDown")
    scrolled = event("/source", "scrollend", start, documentID=source["documentID"])
    scroll = scrolled["scrollY"]
    if not 0 < scroll < pane["linkPoint"][1]:
        raise RuntimeError("The source link did not stay visible after scrolling")
    link_x, link_y = source_point(scrolled, "linkPoint")
    start = len(events)
    peek = open_peek(source, (link_x, link_y))
    before = event("/source", "link", start, documentID=source["documentID"], trusted=True)
    if before["scrollY"] != scroll or before["value"] != "p" or before["viewport"] != pane["viewport"]:
        raise RuntimeError("The source was not scrolled with its draft before opening Peek")
    screen.screenshot(output / "split-peek.png")

    start = len(events)
    screen.key("Escape")
    event("/target", "key", start, key="Escape", documentID=peek["documentID"], trusted=True)
    wait_for("Escape did not close the Peek card", lambda: screen.button("Open in Split View") is None, process)
    screen.key("s")
    restored = event("/source", "key", start, documentID=source["documentID"],
                     target="target", key="s", trusted=True, value="p",
                     viewport=before["viewport"], scrollY=before["scrollY"])
    screen.screenshot(output / "split-restored.png")

    open_peek(source, source_point(restored, "linkPoint"))
    start = len(events)
    bounds = screen.windows()[0]["kCGWindowBounds"]
    # The trailing gutter is outside the card and its buttons, but within
    # the sibling pane. A whole-window wash would swallow this pointer.
    screen.click((bounds["Width"] - 18, bounds["Height"] * 0.7))
    sibling_hit = event("/target", "page-pointer", start, documentID=sibling["documentID"], trusted=True)
    (output / "split-peek.json").write_text(json.dumps({
        "source_before_peek": before,
        "source_restored_after_escape": restored,
        "sibling_pointer_during_peek": sibling_hit,
    }, indent=2) + "\n")

    screen.key("q", screen.command)
    wait_for("Bark did not offer to quit", lambda: screen.button("Quit"), process)
    screen.key("Return")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    sys.exit(run_walk(__doc__, "split-peek", serve, exercise,
                      [("settings.peekOnShiftClick", "-bool", "true")]))
