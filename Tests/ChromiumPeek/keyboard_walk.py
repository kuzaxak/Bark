#!/usr/bin/env python3
"""Verify keyboard opening, dismissal and split promotion in a signed Bark window."""

import json
import signal
import sys

from walk import serve
from signed_walk import run_walk, wait_for


def exercise(screen, process, events, output):
    def event(page, kind, since=0, **fields):
        def matching():
            return next((row for row in events[since:]
                         if row["page"] == page and row["event"] == kind
                         and all(row.get(key) == value for key, value in fields.items())), None)
        return wait_for(f"{page} did not report {kind} {fields}", matching, process)

    source = event("/source", "ready")["documentID"]
    screen.keys.update({"Tab": 48, "=": 24})
    screen.key("p")
    event("/source", "input", documentID=source, value="p", trusted=True)
    screen.key("Tab")

    def open_focused_link():
        start = len(events)
        screen.key("Return", screen.shift)
        event("/source", "key", start, documentID=source, key="Enter", target="target", trusted=True)
        event("/source", "link", start, documentID=source, shift=True, trusted=True)
        peek = event("/target", "ready", start)
        wait_for("Missing Peek card", lambda: screen.button("Open in Split View"), process)
        if len(screen.windows()) != 1:
            raise RuntimeError("Keyboard link activation opened a separate window")
        return peek

    first = open_focused_link()
    screen.key("Escape")
    wait_for("Escape left the card visible", lambda: screen.button("Open in Split View") is None, process)
    screen.key("s")
    event("/source", "key", documentID=source, target="target", key="s", value="p", trusted=True)

    second = open_focused_link()
    if first["documentID"] == second["documentID"]:
        raise RuntimeError("The closed Peek document was reused")
    screen.key("p")
    event("/target", "input", documentID=second["documentID"], value="p", trusted=True)
    start = len(events)
    screen.key("=", screen.quartz.kCGEventFlagMaskControl | screen.shift)
    wait_for("Add Split View left Peek open", lambda: screen.button("Open in Split View") is None, process)
    wait_for("The same Peek document did not become a split pane", lambda: any(
        row["event"] == "resize" and row["documentID"] == second["documentID"]
        and row["viewport"] < second["viewport"] * 0.8 for row in events[start:]), process)
    screen.key("s")
    after = event("/target", "input", start, documentID=second["documentID"], value="ps", trusted=True)
    (output / "keyboard-peek.json").write_text(json.dumps({
        "source": source, "dismissed": first["documentID"], "promoted": second["documentID"],
        "peek_width": second["viewport"], "pane_width": after["viewport"], "restored_draft": after["value"],
    }, indent=2) + "\n")
    screen.key("q", screen.command)
    wait_for("Bark did not offer to quit", lambda: screen.button("Quit"), process)
    screen.key("Return")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    sys.exit(run_walk(__doc__, "peek-keys", serve, exercise,
                      [("settings.peekOnShiftClick", "-bool", "true")]))
