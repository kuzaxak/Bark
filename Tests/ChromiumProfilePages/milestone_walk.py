#!/usr/bin/env python3
"""Follow one signed Bark session across profiles, Peek, split, permission, and restart."""

import argparse
import json
import sys
from urllib.parse import urlsplit

from walk import controls, focus_snapshot, peek, prepare, select_named_page, serve
from signed_walk import run_walk, wait_for

allow_pointer_focus = False


def quit_bark(screen, process):
    screen.key("q", screen.command)
    wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process)
    screen.key("Return")


class Session:
    def __init__(self, screen, process, events, output):
        self.screen, self.process, self.events, self.output = screen, process, events, output
        self.access = controls["Accessibility"](screen, process)
        self.begin = len(events)
        screen.keys.update({"t": 17, "s": 1, "h": 4, "a": 0, "r": 15, "e": 14, "d": 2, "w": 13,
                            "p": 35, "Tab": 48, "=": 24, "Right": 124})

    def event(self, kind, since, **values):
        return wait_for(f"Missing {kind} event with {values}", lambda: next(
            (row for row in self.events[since:] if row["event"] == kind
             and all(row.get(key) == value for key, value in values.items())), None), self.process)

    def selected(self, space):
        return self.access.find(space, ("AXMenuButton",))

    def select(self, space, profile):
        return select_named_page(self.screen, self.process, self.events, self.output, self.access,
                                 self.selected, space, profile, keyboard=True)

    def typed(self, document, key, expected):
        start = len(self.events)
        self.screen.key(key)
        self.event("key", start, id=document, key=key, focused="draft", trusted=True)
        return self.event("input", start, id=document, value=expected, stored=expected, trusted=True)

    def require_space(self, name):
        wait_for(f"{name} is not selected", lambda: self.selected(name), self.process)

    def focus_inbox(self, destination, document, since, draft):
        ready = self.inbox_ready(document, since, draft)
        if not ready["hasFocus"]:
            access = self.access
            element = access.attribute(access.application, "AXFocusedUIElement")
            self.record("focus-" + destination, {"dom": ready, "ax": access.names(element),
                                                  "ax_role": access.attribute(element, "AXRole")})
            if allow_pointer_focus:
                beginning = len(self.events)
                self.screen.click(peek["source_point"](ready, "draftPoint"))
                self.event("pointer", beginning, id=document, trusted=True)

    def inbox_ready(self, document, since, draft):
        return self.event("layout", since, id=document, viewport=643, visible="visible",
                          focused="draft", stored=draft)

    def pane(self, path, since, value, *, document=None):
        def match():
            windows = self.screen.windows()
            if len(windows) != 1:
                return None
            width = windows[0]["kCGWindowBounds"]["Width"]
            half_page = (width - peek["SIDEBAR_WIDTH"] - peek["PAGE_MARGIN"]) / 2
            return next((row for row in self.events[since:] if row["event"] == "layout"
                         and urlsplit(row["url"]).path == path and row["visible"] == "visible"
                         and abs(row["viewport"] - half_page) < 12 and row["stored"] == value
                         and (document is None or row["id"] == document)), None)
        return wait_for(f"Missing mounted split pane {path} with draft {value}", match, self.process)

    def ready(self, since, **values):
        return self.event("ready", since, **values)

    def record(self, name, value):
        (self.output / f"{name}.json").write_text(json.dumps(value, indent=2) + "\n")


def exercise(screen, process, events, output):
    test = Session(screen, process, events, output)
    work = test.ready(0)
    test.require_space("Office")
    test.inbox_ready(work["id"], 0, None)
    test.typed(work["id"], "w", "w")
    since = test.select("Home", "Personal")
    home = test.ready(since, url=work["url"])
    if home["id"] == work["id"] or home["stored"] is not None:
        raise RuntimeError("The two profiles do not have separate inbox documents and storage")
    test.focus_inbox("Home", home["id"], since, None)
    home = test.typed(home["id"], "p", "p")
    since = test.select("Office", "Work")
    test.focus_inbox("Office", work["id"], since, "w")
    work = test.typed(work["id"], "w", "ww")

    screen.key("Tab")
    start = len(events)
    screen.key("Return", screen.shift)
    test.event("link", start, id=work["id"], trusted=True, shift=True)
    thread = test.ready(start)
    target_url = thread["url"]
    if urlsplit(target_url).path != "/target":
        raise RuntimeError("The activated link did not load the expected thread")
    wait_for("Missing Peek card", lambda: screen.button("Open in Split View"), process)
    test.typed(thread["id"], "s", "s")
    start = len(events)
    screen.key("=", screen.quartz.kCGEventFlagMaskControl | screen.shift)
    test.pane("/target", start, "s", document=thread["id"])
    test.pane("/source", start, "ww", document=work["id"])
    if screen.button("Open in Split View") or len(screen.windows()) != 1:
        raise RuntimeError("The thread did not promote in place")
    test.typed(thread["id"], "s", "ss")
    if sum(row["event"] == "ready" and row["url"] == target_url for row in events) != 1:
        raise RuntimeError("Promotion recreated the thread document")

    screen.key("Tab")
    start = len(events)
    screen.key("Return")
    issuer = test.event("request", start, id=thread["id"], focused="request", trusted=True)
    # Return requested a permission. Do not press Return against the prompt,
    # where the default action could allow access.
    wait_for("Missing thread location prompt", lambda: screen.button("Never allow") or screen.button("Block"), process)
    origin = issuer["url"].removesuffix("/target")
    access = test.access
    wait_for("The prompt did not show the thread's origin", lambda: any(
        origin in label and "location" in label.lower() for window in access.windows()
        for element in access.tree(window) for label in access.names(element)), process)
    screen.key("Escape")
    denied = test.event("error", start, id=thread["id"], code=1)
    wait_for("The thread permission prompt stayed open", lambda: not (
        screen.button("Never allow") or screen.button("Block")), process)
    if any(row["event"] in ("error", "granted") and row is not denied for row in events[start:]):
        raise RuntimeError("Permission result was delivered outside the requesting thread")
    # Restore the renderer's draft focus before quit. On relaunch the test
    # sends a key before selecting a tab, pane, or input.
    screen.key("Tab", screen.shift)
    screen.key("Right")
    thread = test.typed(thread["id"], "s", "sss")
    test.record("before-quit", {"work": work, "home": home, "thread": thread,
                               "permission_issuer": issuer, "denied": denied})
    quit_bark(screen, process)


def restored(screen, process, events, output, fixture):
    test = Session(screen, process, events, output)
    before = json.loads((output / "before-quit.json").read_text())
    device = json.loads((fixture["root"] / "App/Tabs/device.json").read_text())
    (window,) = device["state"]["windows"]
    selection = window["selectedItemBySpace"]
    active = dict(zip(selection[::2], selection[1::2]))[fixture["work"]]
    leading, trailing = window["split"]["itemIDs"]
    by_id = {entry["id"]: entry for entry in device["items"]}
    if (window["spaceID"] != fixture["work"] or active != trailing
            or by_id[leading]["kind"]["tab"]["url"] != before["work"]["url"]
            or by_id[trailing]["kind"]["tab"]["url"] != before["thread"]["url"]):
        raise RuntimeError("Relaunch did not restore Office with its original thread as the active split item")
    test.record("saved-active-pane", {"window": window, "active_item": active})
    test.require_space("Office")
    work = test.pane("/source", test.begin, "ww")
    thread = test.pane("/target", test.begin, "sss")
    if work["id"] == before["work"]["id"] or thread["id"] == before["thread"]["id"]:
        raise RuntimeError("Relaunch did not create new renderer documents")
    # The actual renderer focus must settle before the first key. Read
    # renderer reports here rather than inferring focus from pane selection.
    def focused_thread():
        return next((row for row in reversed(events[test.begin:]) if row["event"] == "layout"
                     and row["id"] == thread["id"] and row["viewport"] == thread["viewport"]
                     and row["focused"] == "draft" and row["hasFocus"]), None)

    test.record("focus-restored-thread", {"dom": thread, "ax": focus_snapshot(test.access, test.selected)})
    if not allow_pointer_focus:
        thread = wait_for("The restored active thread never received native Draft focus", focused_thread, process)
        test.record("focus-before-first-key", {"dom": thread, "ax": focus_snapshot(test.access, test.selected)})
    if allow_pointer_focus and not thread["hasFocus"]:
        windows = screen.windows()
        if len(windows) != 1:
            raise RuntimeError("The saved split did not restore in one physical window")
        x, y = thread["draftPoint"]
        width = windows[0]["kCGWindowBounds"]["Width"]
        start = len(events)
        screen.click((width - thread["viewport"] + x, peek["PAGE_MARGIN"] + y))
        test.event("pointer", start, id=thread["id"], trusted=True)
    start = len(events)
    screen.key("Right")
    test.event("key", start, id=thread["id"], key="ArrowRight", focused="draft", trusted=True)
    thread = test.typed(thread["id"], "s", "ssss")
    since = test.select("Home", "Personal")
    home = test.ready(since, url=work["url"], stored="p")
    test.focus_inbox("Home-relaunched", home["id"], since, "p")
    home = test.typed(home["id"], "p", "pp")
    test.record("after-relaunch", {"work": work, "home": home, "thread": thread,
                                  "active_space": "Office", "key_recipient": thread["id"]})
    quit_bark(screen, process)


if __name__ == "__main__":
    options = argparse.ArgumentParser(add_help=False)
    options.add_argument("--allow-pointer-focus", action="store_true")
    arguments, rest = options.parse_known_args()
    allow_pointer_focus = arguments.allow_pointer_focus
    sys.argv[1:] = rest
    fixture = {}

    def prepare_fixture(root, origin, app, work):
        fixture.update(root=root, work=work)
        prepare(root, origin, app, work)

    def relaunch(screen, process, events, output):
        restored(screen, process, events, output, fixture)

    sys.exit(run_walk(__doc__, "profile-milestone", serve, exercise,
                      [("settings.peekOnShiftClick", "-bool", "true")],
                      prepare_fixture=prepare_fixture, relaunch=relaunch))
