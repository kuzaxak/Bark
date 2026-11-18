#!/usr/bin/env python3
"""Measure observed physical input and return to a live parked Bark tab."""

import json
from pathlib import Path
import runpy
import subprocess
import sys
import time
from uuid import uuid4

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import run_walk, wait_for

peek_fixture = runpy.run_path(str(HERE.parent / "ChromiumPeek/walk.py"))
serve = peek_fixture["serve"]
source_point = peek_fixture["source_point"]


def prepare_fixture(root, origin, _app, space):
    path = root / "App/Tabs/device.json"
    seed = json.loads(path.read_text())
    seed["items"].append({
        "id": str(uuid4()).upper(),
        "kind": {"tab": {"url": f"{origin}/target", "pageTitle": "Park alternate"}},
        "order": "W",
        "parent": {"tabs": {"spaceID": space}},
        "modifiedAt": seed["items"][0]["modifiedAt"],
    })
    path.write_text(json.dumps(seed) + "\n")


def mounted_web_areas(screen):
    screen.guard()
    ax = screen.ax
    app = ax.AXUIElementCreateApplication(screen.pid)

    def get(element, attribute):
        status, result = ax.AXUIElementCopyAttributeValue(element, attribute, None)
        return result if status == 0 else None

    pending = [(window, 0) for window in get(app, "AXWindows") or ()]
    titles = set()
    while pending:
        node, depth = pending.pop()
        if get(node, "AXRole") == "AXWebArea":
            for attribute in ("AXTitle", "AXDescription"):
                if value := get(node, attribute):
                    titles.add(str(value))
        if depth < 24:
            pending.extend((child, depth + 1) for child in get(node, "AXChildren") or ())
    return titles


def exercise(screen, process, events, output):
    def event(page, name, since=0, **where):
        def matching():
            return next((row for row in events[since:]
                         if row["page"] == page and row["event"] == name
                         and all(row.get(key) == value for key, value in where.items())), None)
        return wait_for(f"Missing {name} event on {page}", matching, process)

    screen.keys.update({"1": 18, "2": 19})
    source = event("/source", "ready", wasDiscarded=False)
    wait_for("The seeded window did not reach its saved size",
             lambda: any(row["kCGWindowBounds"]["Width"] == 900 for row in screen.windows()), process)
    screen.click(source_point(source, "draftPoint"))
    first = event("/source", "pointer", trusted=True, documentID=source["documentID"])
    screen.key("parked draft", unicode=True)
    event("/source", "input", trusted=True, documentID=source["documentID"], value="parked draft")

    before_switch = len(events)
    screen.key("2", screen.command)
    target = event("/target", "ready")
    event("/target", "visibility", before_switch, visibility="visible",
          documentID=target["documentID"])
    hidden = event("/source", "visibility", before_switch, visibility="hidden",
                   documentID=source["documentID"], value="parked draft", wasDiscarded=False)
    screen.guard()
    screen.ax.AXUIElementSetAttributeValue(screen.ax.AXUIElementCreateApplication(screen.pid),
                                           "AXEnhancedUserInterface", True)

    source_title, target_title = "Peek fixture source", "Peek fixture target"

    def alternate_mounted():
        titles = mounted_web_areas(screen)
        return titles if target_title in titles and source_title not in titles else None

    titles = wait_for("Source remained in the window or alternate page did not mount",
                      alternate_mounted, process)
    if len(screen.windows()) != 1:
        raise RuntimeError("Switching tabs created another physical window")

    before_return = len(events)
    return_started = time.monotonic_ns()
    screen.key("1", screen.command)
    visible = event("/source", "visibility", before_return, visibility="visible",
                    documentID=source["documentID"], value="parked draft", wasDiscarded=False)
    screen.key("s")
    resumed = event("/source", "key", before_return, key="s", trusted=True,
                    documentID=source["documentID"], value="parked draft", focused="draft",
                    target="draft", wasDiscarded=False)
    event("/source", "input", before_return, trusted=True, value="parked drafts",
          documentID=source["documentID"], wasDiscarded=False)
    if sum(row["page"] == "/source" and row["event"] == "ready" for row in events) != 1:
        raise RuntimeError("Returning to the source loaded a second document")

    # These are observed bounds and include event dispatch and local receipt.
    results = {
        "profile": "fresh disposable verification profile; machine caches uncontrolled",
        "hardware": subprocess.check_output(["sysctl", "-n", "hw.model", "machdep.cpu.brand_string", "hw.memsize"],
                                           text=True).splitlines(),
        "macos": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
        "launch_to_pointer_ms": round((first["received_ns"] - screen.launch_started_ns) / 1e6, 2),
        "switch_back_to_key_ms": round((resumed["received_ns"] - return_started) / 1e6, 2),
        "observed_hidden_ms": round((visible["received_ns"] - hidden["received_ns"]) / 1e6, 2),
        "document_id": source["documentID"],
        "parked_window_web_areas": sorted(titles),
        "was_discarded": resumed["wasDiscarded"],
    }
    (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results), flush=True)
    screen.key("q", screen.command)
    wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process)
    screen.press_button(screen.button("Quit"))


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "startup-parked", serve, exercise, prepare_fixture=prepare_fixture))
