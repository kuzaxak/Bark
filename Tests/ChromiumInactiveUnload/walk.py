#!/usr/bin/env python3
"""Verify signed Bark retains a hidden draft during bulk tab unloading."""

import json
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

startup = runpy.run_path(str(HERE.parent / "ChromiumStartup/walk.py"))


def exercise(screen, process, events, output):
    access = Accessibility(screen, process)

    def event(page, name, since=0, **facts):
        return wait_for(f"Missing {name} on {page}", lambda: next(
            (row for row in events[since:] if row["page"] == page and row["event"] == name
             and all(row.get(key) == value for key, value in facts.items())), None), process)

    screen.keys.update({"1": 18, "2": 19, ",": 43})
    draft = "disposable hidden draft"
    try:
        source = event("/source", "ready", wasDiscarded=False)
        document = source["documentID"]
        wait_for("The seeded browser window did not reach its saved size",
                 lambda: any(row["kCGWindowBounds"]["Width"] == 900 for row in screen.windows()), process)
        screen.click(startup["source_point"](source, "draftPoint"))
        event("/source", "pointer", trusted=True, documentID=document)
        screen.key(draft, unicode=True)
        event("/source", "input", trusted=True, documentID=document, value=draft)

        before_switch = len(events)
        screen.key("2", screen.command)
        target = event("/target", "ready")
        event("/target", "visibility", before_switch, visibility="visible", documentID=target["documentID"])
        event("/source", "visibility", before_switch, visibility="hidden",
              documentID=document, value=draft, wasDiscarded=False)

        screen.key(",", screen.command)
        settings = wait_for("Missing native General settings",
                            lambda: access.owner("Unload All Inactive Tabs", ("AXButton",)), process)
        access.press(access.control("Unload All Inactive Tabs", ("AXButton",), root=settings))
        summary = "Unloaded: 0. Kept open: 2. Activity unknown: 1."
        access.control(summary, ("AXStaticText",), root=settings)
        screen.screenshot(output / "bulk-result.png", include_owned_windows=True)
        close = access.attribute(settings, "AXCloseButton")
        if close is None:
            raise RuntimeError("Missing Settings Close button")
        access.press(close)
        wait_for("Settings did not close", lambda: settings not in access.windows(), process)

        before_return = len(events)
        screen.key("1", screen.command)
        event("/source", "visibility", before_return, visibility="visible",
              documentID=document, value=draft, wasDiscarded=False)
        screen.key("s")
        resumed = event("/source", "input", before_return, trusted=True, documentID=document,
                        value=draft + "s", wasDiscarded=False)
        if sum(row["page"] == "/source" and row["event"] == "ready" for row in events) != 1:
            raise RuntimeError("Returning to the hidden draft created a second document")
        (output / "bulk-unload.json").write_text(json.dumps({
            "summary": summary, "document_id": document, "same_document": resumed["documentID"] == document,
            "draft_still_editable": True, "was_discarded": resumed["wasDiscarded"],
        }, indent=2) + "\n")

        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
    except Exception:
        access.dump(output / "accessibility.json")
        raise


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "bulk-unload", startup["serve"], exercise,
                      prepare_fixture=startup["prepare_fixture"], official_qualification=True))
