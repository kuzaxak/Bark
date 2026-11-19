#!/usr/bin/env python3
"""Exercise signed Bark's Settings history and native layout controls."""

import json
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

fixture = runpy.run_path(str(HERE.parent / "ChromiumExtensionActions/walk.py"))


def exercise(screen, process, events, output):
    access = Accessibility(screen, process)
    wait_for("The disposable source did not load", lambda: "/ready" in events, process, timeout=30)
    screen.keys[","] = 43
    screen.key(",", screen.command)
    settings = wait_for("Settings did not open",
                        lambda: access.owner("Privacy", ("AXButton",)), process)
    observations = []

    def history_buttons(stage, *, back, forward):
        def matching_buttons():
            buttons = {"Back": [], "Forward": []}
            for element in access.tree(settings):
                if access.attribute(element, "AXRole") != "AXButton":
                    continue
                for label in buttons.keys() & set(access.names(element)):
                    buttons[label].append(element)
            states = {label: [bool(access.attribute(element, "AXEnabled")) for element in entries]
                      for label, entries in buttons.items()}
            row = {"stage": stage, **states}
            if not observations or observations[-1] != row:
                observations.append(row)
                (output / "toolbar-accessibility.json").write_text(json.dumps(observations, indent=2) + "\n")
            if states == {"Back": [back], "Forward": [forward]}:
                return {label: entries[0] for label, entries in buttons.items()}
            return None

        return wait_for(f"{stage}: expected one Back and one Forward with the correct enabled states",
                        matching_buttons, process)

    def privacy():
        access.control("Open Profiles", ("AXButton",), root=settings)
        access.control("Passwords", root=settings)
        return access.control("Use Pawl Vault for passwords and passkeys", root=settings)

    def toolbar_toggle():
        for element in access.tree(settings):
            if access.attribute(element, "AXRole") not in ("AXCheckBox", "AXSwitch"):
                continue
            title = access.attribute(element, "AXTitleUIElement")
            if "Show Toolbar" in access.names(element) + access.names(title):
                return element
        return None

    def layout_controls():
        access.press(access.control("Appearance", ("AXButton",), root=settings))
        toggle = wait_for("Appearance did not offer Show Toolbar", toolbar_toggle, process)
        if not access.attribute(toggle, "AXEnabled"):
            raise RuntimeError("Show Toolbar is disabled")
        previous = access.attribute(toggle, "AXValue")
        if previous not in (0, 1):
            raise RuntimeError(f"Unexpected initial toolbar value {previous!r}")

        def press_and_wait(expected):
            access.press(wait_for("No live toolbar toggle", toolbar_toggle, process))
            wait_for("Show Toolbar did not update its bound state",
                     lambda: access.attribute(toolbar_toggle(), "AXValue") == expected, process)

        press_and_wait(1 - previous)
        press_and_wait(previous)
        retired = ("Sidebar Position", "Show URL bar in the web view",
                   "Preview link URL on hover", "Show meetings and mail on favorites", "Hide border")
        present = [label for label in retired if access.find(label, root=settings)]
        if present:
            raise RuntimeError(f"Retired Appearance controls are visible: {present}")
        (output / "appearance-controls.json").write_text(json.dumps({
            "toolbar_control": "Show Toolbar", "values": [previous, 1 - previous, previous],
        }, indent=2) + "\n")

    try:
        history_buttons("General", back=False, forward=False)
        access.press(access.control("Privacy", ("AXButton",), root=settings))
        privacy()
        history_buttons("Privacy", back=True, forward=False)
        access.press(access.control("Open Profiles", ("AXButton",), root=settings))
        access.control("Your Profiles", root=settings)
        buttons = history_buttons("Profiles", back=True, forward=False)
        access.press(buttons["Back"])
        privacy()
        buttons = history_buttons("After Back", back=True, forward=True)
        access.press(buttons["Forward"])
        access.control("Your Profiles", root=settings)
        history_buttons("After Forward", back=True, forward=False)
        screen.screenshot(output / "profiles-after-forward.png", include_owned_windows=True)
        layout_controls()
        print("Settings history navigates Privacy and Profiles, and Appearance changes the Show Toolbar setting.",
              flush=True)
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
    finally:
        access.dump(output / "final-ax.json")


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "settings-history", fixture["serve"], exercise, official_qualification=True))
