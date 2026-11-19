#!/usr/bin/env python3
"""Resize a signed Bark split using physical keys and macOS accessibility actions."""

import json
import sys

from walk import serve, source_point
from signed_walk import Accessibility, run_walk, wait_for


def exercise(screen, process, events, output):
    access = Accessibility(screen, process)

    def event(page, kind, since=0, predicate=lambda _: True, **fields):
        return wait_for(f"{page} did not report {kind} {fields}", lambda: next((
            row for row in events[since:] if row["page"] == page and row["event"] == kind
            and all(row.get(key) == value for key, value in fields.items()) and predicate(row)
        ), None), process)

    def resize(start, width, *, growing):
        return event("/source", "resize", start, documentID=source["documentID"],
                     predicate=lambda row: (row["viewport"] - width) * (1 if growing else -1) > 8)

    def focus_divider():
        access.menu("Resize Split Panes")

        def focused():
            target = access.attribute(access.application, "AXFocusedUIElement")
            return target if access.attribute(target, "AXRole") == "AXSplitter" else None

        return wait_for("View → Resize Split Panes did not focus the splitter", focused, process)

    def adjust(divider, action):
        screen.guard()
        if access.ax.AXUIElementPerformAction(divider, action) != 0:
            raise RuntimeError(f"The focused splitter refused {action}")

    source = event("/source", "ready")
    wait_for("The split fixture did not restore its saved size",
             lambda: len(screen.windows()) == 1 and screen.windows()[0]["kCGWindowBounds"]["Width"] == 900,
             process)
    access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)

    screen.click(source_point(source, "linkPoint"), screen.shift)
    link = event("/source", "link", documentID=source["documentID"], trusted=True, shift=True)
    target = event("/target", "ready")
    open_in_split = wait_for("The Peek did not offer Open in Split View",
                             lambda: screen.button("Open in Split View"), process)
    start = len(events)
    screen.press_button(open_in_split)
    left = resize(start, link["viewport"], growing=False)
    right = event("/target", "resize", start, documentID=target["documentID"],
                  predicate=lambda row: abs(row["viewport"] - left["viewport"]) <= 2)
    wait_for("The Peek promotion left a card open", lambda: not screen.button("Open in Split View"), process)

    start = len(events)
    screen.click(source_point(left, "draftPoint"))
    event("/source", "page-pointer", start, documentID=source["documentID"], trusted=True)
    screen.keys.update({"Left": 123, "Right": 124, "Tab": 48})
    screen.key("p")
    event("/source", "input", start, documentID=source["documentID"], value="p", trusted=True)

    divider = focus_divider()
    actions = access.ax.AXUIElementCopyActionNames(divider, None)[1] or ()
    value = access.attribute(divider, "AXValue")
    limits = [access.attribute(divider, key) for key in ("AXMinValue", "AXMaxValue")]
    if ("Split Divider" not in access.names(divider) or not {"AXIncrement", "AXDecrement"} <= set(actions)
            or not all(isinstance(v, (int, float)) for v in [value, *limits])
            or not limits[0] < value < limits[1]):
        raise RuntimeError(f"The focused divider lacks usable accessibility metadata: {value}, {limits}, {actions}")
    screen.screenshot(output / "divider.png")

    sizes = [{"action": "initial", "source_width": left["viewport"], "sibling_width": right["viewport"],
              "divider_percent": value}]
    for action, growing in (("Right", True), ("Left", False), ("AXIncrement", True), ("AXDecrement", False)):
        start = len(events)
        if action.startswith("AX"):
            adjust(divider, action)
        else:
            screen.key(action)
        left = resize(start, left["viewport"], growing=growing)
        previous_sibling_width = right["viewport"]
        right = event("/target", "resize", start, documentID=target["documentID"],
                      predicate=lambda row: (row["viewport"] - previous_sibling_width) * (-1 if growing else 1) > 8)
        observed = access.attribute(divider, "AXValue")
        if not isinstance(observed, (int, float)) or (observed - value) * (1 if growing else -1) <= 0:
            raise RuntimeError(f"{action} resized the panes without updating AXValue")
        value = observed
        sizes.append({"action": action, "source_width": left["viewport"], "sibling_width": right["viewport"],
                      "divider_percent": value})

    restored = []
    for exit_key, text in (("Escape", "ps"), ("Tab", "pss"), ("Shift-Tab", "psss")):
        if exit_key != "Escape":
            focus_divider()
        start = len(events)
        if exit_key == "Shift-Tab":
            screen.key("Tab", screen.shift)
        else:
            screen.key(exit_key)
        screen.key("s")
        row = event("/source", "input", start, documentID=source["documentID"],
                    value=text, trusted=True, focused="draft")
        if any(item["page"] != "/source" and item["event"] == "input" for item in events[start:]):
            raise RuntimeError("Leaving the divider sent input to another pane")
        restored.append({"key": exit_key, "document": row["documentID"], "draft": row["value"]})

    (output / "divider.json").write_text(json.dumps({
        "actions": list(actions), "limits": limits,
        "sizes": sizes,
        "focus_restored": restored,
    }, indent=2) + "\n")
    screen.key("q", screen.command)
    screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "divider", serve, exercise,
                      [("settings.peekOnShiftClick", "-bool", "true")], official_qualification=True))
