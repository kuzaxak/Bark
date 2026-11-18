#!/usr/bin/env python3
"""Walk duplicate-site tabs and a site permission across two signed Bark profiles."""

from contextlib import contextmanager
import json
from pathlib import Path
import runpy
import sys
from urllib.parse import urlsplit
from uuid import uuid4

HERE = Path(__file__).resolve().parent
peek = runpy.run_path(str(HERE.parent / "ChromiumPeek/walk.py"))
from signed_walk import Accessibility, run_walk, wait_for


@contextmanager
def serve():
    with peek["serve"]() as server:
        server.html = (HERE / "fixture.html").read_text()
        yield server


def prepare(root, _origin, _app, work_id):
    tabs = root / "App/Tabs"
    structure = json.loads((tabs / "structure.json").read_text())
    office = structure["spaces"][0]
    office.update(name="Office", profileName="Work")
    home_id, home_tab = (str(uuid4()).upper() for _ in range(2))
    structure["spaces"].append(dict(office, id=home_id, order="W", name="Home", profileName="Personal", icon="house"))
    device = json.loads((tabs / "device.json").read_text())
    work_tab = device["items"][0]
    work_tab["kind"]["tab"]["pageTitle"] = "Shared Inbox"
    device["items"].append(dict(work_tab, id=home_tab, parent={"tabs": {"spaceID": home_id}}))
    device["state"]["windows"][0]["selectedItemBySpace"] += [home_id, home_tab]
    for name, value in [("structure", structure), ("device", device)]:
        (tabs / f"{name}.json").write_text(json.dumps(value) + "\n")


def focus_snapshot(access, selected):
    focus = access.attribute(access.application, "AXFocusedUIElement")
    window = access.attribute(access.application, "AXFocusedWindow")
    return {"role": access.attribute(focus, "AXRole"), "labels": access.names(focus),
            "identifier": access.attribute(focus, "AXIdentifier"),
            "window": access.names(window), "window_role": access.attribute(window, "AXRole"),
            "window_subrole": access.attribute(window, "AXSubrole"),
            "window_identifier": access.attribute(window, "AXIdentifier"),
            "selected_spaces": [space for space in ("Office", "Home") if selected(space)]}


def select_named_page(screen, process, events, output, access, selected, space, profile, *,
                      keyboard=False, query="shared", title="Shared Inbox"):
    action = f"Switch to {space} ({profile} profile)" if profile else "Switch to Tab"
    screen.key("t", screen.command)
    focused = lambda: access.attribute(access.application, "AXFocusedUIElement")
    wait_for("Missing command palette text field",
             lambda: access.attribute(focused(), "AXRole") == "AXTextField", process)
    for key in query:
        screen.key(key)

    def row():
        screen.guard()
        field = focused()
        if access.attribute(field, "AXRole") != "AXTextField":
            return None
        x, y = access.center(field)
        limit = screen.windows()[0]["kCGWindowBounds"]
        # Hit-test the app's palette overlay. Its rows aren't in the
        # tab window's ordinary accessibility children.
        for offset in range(35, 360, 12):
            if y + offset >= limit["Y"] + limit["Height"]:
                break
            status, hit = access.ax.AXUIElementCopyElementAtPosition(access.application, x, y + offset, None)
            if not status and any(action in text and title.casefold() in text.casefold()
                                  for text in access.names(hit)):
                return hit
        return None

    hit = wait_for(f"Missing named palette destination for {space}", row, process)
    (output / f"palette-{space}.json").write_text(json.dumps(access.names(hit), indent=2) + "\n")
    screen.screenshot(output / f"palette-{space}.png")
    since = len(events)
    focus = {"before": focus_snapshot(access, selected)}
    if keyboard:
        screen.keys["Down"] = 125
        siblings = access.attribute(access.attribute(hit, "AXParent"), "AXChildren") or ()
        for sibling in siblings:
            if access.names(sibling) == access.names(hit):
                screen.key("Down")
                break
            if any("Switch to " in label for label in access.names(sibling)):
                screen.key("Down")
        else:
            raise RuntimeError("The named result was not in the keyboard palette rows")
        screen.key("Return")
    else:
        x, y = access.center(hit)
        bounds = screen.windows()[0]["kCGWindowBounds"]
        screen.click((x - bounds["X"], y - bounds["Y"]))
    focus["immediate"] = focus_snapshot(access, selected)
    wait_for(f"The palette did not select {space}", lambda: selected(space), process)
    focus["selected"] = focus_snapshot(access, selected)
    (output / f"palette-focus-{space}.json").write_text(json.dumps(focus, indent=2) + "\n")
    return since


def exercise(screen, process, events, output):
    access = Accessibility(screen, process)
    screen.keys.update({"t": 17, "s": 1, "h": 4, "a": 0, "r": 15, "e": 14, "d": 2, "w": 13, "p": 35})

    def record(name, value):
        (output / (name + ".json")).write_text(json.dumps(value, indent=2) + "\n")

    def event(kind, since=0, **properties):
        return wait_for(f"Missing {kind} event for {properties}", lambda: next(
            (row for row in events[since:] if row["event"] == kind
             and all(row.get(key) == value for key, value in properties.items())), None), process)

    def selected(space):
        return access.find(space, ("AXMenuButton",), root=source)

    def layout(space, document, since, *, exclude=None):
        def ready():
            windows = screen.windows()
            if not selected(space) or len(windows) != 1:
                return None
            width = windows[0]["kCGWindowBounds"]["Width"] - peek["SIDEBAR_WIDTH"] - peek["PAGE_MARGIN"]
            rows = [row for row in events[since:] if row["event"] == "layout"
                    and row["visible"] == "visible" and row["viewport"] == width
                    and (document is None or row["id"] == document) and row["id"] != exclude]
            if len(rows) < 2:
                return None
            first, last = rows[-2:]
            if all(first[key] == last[key] for key in ("id", "viewport", "draftPoint", "requestPoint")):
                return last
            return None
        return wait_for(f"{space} did not mount the expected live document at full viewport", ready, process)

    def click(element):
        x, y = access.center(element)
        bounds = screen.windows()[0]["kCGWindowBounds"]
        screen.click((x - bounds["X"], y - bounds["Y"]))

    def write(space, document, since, key, previous, *, exclude=None):
        page = layout(space, document, since, exclude=exclude)
        before = len(events)
        screen.click(peek["source_point"](page, "draftPoint"))
        event("pointer", before, id=page["id"], trusted=True, stored=previous or None)
        expected = previous + key
        screen.key(key)
        event("key", before, id=page["id"], trusted=True, key=key, focused="draft")
        typed = event("input", before, id=page["id"], trusted=True, value=expected, stored=expected)
        if not selected(space):
            raise RuntimeError("The selected space changed during typing")
        return typed

    def palette(space, profile):
        return select_named_page(screen, process, events, output, access, selected, space, profile)

    def deny_button():
        return next((node for label in ("Never allow", "Block")
                     if (node := access.find(label, ("AXButton",))) is not None), None)

    try:
        event("ready")
        screen.guard()
        source = wait_for("Missing initial Bark window", lambda: access.owner("Shared Inbox", ("AXWindow",)), process)
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        work = write("Office", None, 0, "w", "")
        personal = write("Home", None, palette("Home", "Personal"), "p", "", exclude=work["id"])
        if personal["url"] != work["url"]:
            raise RuntimeError("The two profiles did not open the same URL")
        work = write("Office", work["id"], palette("Office", "Work"), "w", "w")
        page = layout("Office", work["id"], len(events))
        start = len(events)
        screen.click(peek["source_point"](page, "requestPoint"))
        issuer = event("request", start, id=work["id"], trusted=True, url=work["url"])
        wait_for("Missing the Work page's location prompt", deny_button, process)
        requesting_url = urlsplit(issuer["url"])
        origin = f"{requesting_url.scheme}://{requesting_url.netloc}"
        wait_for("The permission prompt did not identify the requesting origin",
                 lambda: any(origin in name and "location" in name.lower() for window in access.windows()
                             for node in access.tree(window) for name in access.names(node)), process)
        access.dump(output / "work-prompt-ax.json")
        screen.screenshot(output / "work-permission.png")

        since = len(events)
        click(access.control("Home", ("AXButton",), root=source))
        wait_for("The Work prompt remained over Personal", lambda: selected("Home") and not deny_button(), process)
        personal = write("Home", personal["id"], since, "p", "p")
        since = len(events)
        click(access.control("Office", ("AXButton",), root=source))
        wait_for("Work prompt did not return to Office", lambda: selected("Office") and deny_button(), process)
        layout("Office", work["id"], since)
        deny = wait_for("The remounted Work prompt lost its deny button", deny_button, process)
        denial_start = len(events)
        click(deny)
        denied = event("error", denial_start, id=work["id"], code=1)
        wait_for("Denied prompt stayed visible", lambda: not deny_button(), process)
        if any(row["event"] in ("error", "granted") and row is not denied for row in events[start:]):
            raise RuntimeError("An unexpected document received a permission result")
        record("result", {"work": work, "personal": personal, "issuer": issuer, "denied": denied})
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
    finally:
        access.dump(output / "last-ax.json")


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "shared-inbox", serve, exercise, prepare_fixture=prepare))
