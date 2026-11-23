#!/usr/bin/env python3
"""Qualify an anonymous visit to Bark's public Actions page from a GitHub Actions macOS job."""

import json
import os
from pathlib import Path
import runpy
import sys
import time

TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TESTS / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

URL = "https://github.com/kuzaxak/Bark/actions"
DOCUMENT_TITLE = "All Workflow Runs · GitHub"
SEARCH_LABEL = "Search runs"
SEARCH_TEXT = "Bark"
OBSERVE_SECONDS = 10


def prepare_fixture(root, _origin, _app, _profile):
    path = root / "App/Tabs/device.json"
    data = json.loads(path.read_text())
    # A distinct placeholder title ensures the initial model cannot satisfy the check.
    data["items"][0]["kind"]["tab"].update(url=URL, pageTitle="Actions qualification")
    path.write_text(json.dumps(data) + "\n")


def exercise(screen, process, _events, output):
    access = Accessibility(screen, process)
    wait_for("The signed candidate did not open a window", screen.windows, process, timeout=30)
    screen.guard()
    access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)

    def document():
        if access.find("This page crashed", ("AXStaticText",)):
            raise RuntimeError("The Actions tab reported a renderer termination")
        return access.find(DOCUMENT_TITLE, ("AXWebArea",))

    def search():
        area = document()
        if area is None:
            return None
        return next((node for node in access.tree(area)
                     if access.attribute(node, "AXRole") in ("AXTextField", "AXComboBox", "AXSearchField")
                     and (access.attribute(node, "AXPlaceholderValue") == SEARCH_LABEL
                          or SEARCH_LABEL in access.names(node))), None)

    field = wait_for(
        "Inconclusive: GitHub's public Actions page and search field did not become available "
        "(check network, authentication redirects, and page changes)", search, process, timeout=45,
    )
    x, y = access.center(field)
    bounds = screen.windows()[0]["kCGWindowBounds"]
    screen.click((x - bounds["X"], y - bounds["Y"]))
    screen.key(SEARCH_TEXT, unicode=True)

    def input_received():
        if not document():
            return False
        focused = access.attribute(access.application, "AXFocusedUIElement")
        return access.attribute(focused, "AXValue") == SEARCH_TEXT

    wait_for("The Actions page mounted but did not respond to typing", input_received, process)
    # Keep the page foregrounded long enough to catch a termination after the first paint.
    until = time.monotonic() + OBSERVE_SECONDS
    while time.monotonic() < until:
        if process.poll() is not None:
            raise RuntimeError(f"The candidate exited while showing Actions (status {process.returncode})")
        screen.guard()
        if not document():
            raise RuntimeError("Inconclusive: the Actions document disappeared after responding")
        time.sleep(0.5)

    if not document():
        raise RuntimeError("Inconclusive: the Actions document disappeared before capture")
    screen.screenshot(output / "actions.png")
    screen.key("q", screen.command)
    screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
    print(f"Actions page accepted keyboard input and stayed mounted for {OBSERVE_SECONDS}s.", flush=True)


def parse_options(parser):
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("Run this walkthrough only in a GitHub Actions job")
    if not args.require_official:
        parser.error("This walkthrough requires --require-official")
    return args


if __name__ == "__main__":
    serve = runpy.run_path(str(TESTS / "ChromiumPeek/walk.py"))["serve"]
    sys.exit(run_walk(__doc__, "github-actions", serve, exercise,
                      prepare_fixture=prepare_fixture, official_qualification=True,
                      parse_options=parse_options))
