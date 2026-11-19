#!/usr/bin/env python3
"""Exercise signed Bark's Settings history using accessibility actions."""

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
        print("Settings exposes distinct Back and Forward buttons and they navigate between Privacy and Profiles.",
              flush=True)
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
    finally:
        access.dump(output / "final-ax.json")


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "settings-history", fixture["serve"], exercise, official_qualification=True))
