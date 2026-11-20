#!/usr/bin/env python3
"""Exercise a real installed extension action in a signed Bark window."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import sys
from threading import Thread

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

SOURCE = "Bark action source"
EXTENSION = "Bark action fixture"
ACTION = "Bark fixture action"
POPUP = "Extension popup is open"


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/source":
            body = (b"<!doctype html><title>Bark action source</title>"
                    b"<h1>Bark action source</h1><script>fetch('/ready')</script>")
        elif self.path == "/ready":
            body = b""
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.server.events.append(self.path)

    def log_message(self, *_):
        pass


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.events = []
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield server
        finally:
            server.shutdown()
            worker.join()


def install_extension(screen, access, source, fixture):
    manager = open_manager(access, source)
    developer_mode = access.control("Developer mode", ("AXCheckBox", "AXSwitch", "AXButton"))
    if access.attribute(developer_mode, "AXValue") in (False, None, 0, "0"):
        access.press(developer_mode)
    access.press(access.control("Load unpacked", ("AXButton",)))
    select = access.control("Select", ("AXButton",))
    panel = select
    while panel is not None and access.attribute(panel, "AXRole") not in ("AXSheet", "AXWindow"):
        panel = access.attribute(panel, "AXParent")
    if panel is None:
        raise RuntimeError("Select is outside the open panel")
    screen.keys["g"] = 5
    previous = access.attribute(access.application, "AXFocusedUIElement")
    screen.key("g", screen.command | screen.shift)

    def focused_folder_field():
        # AppKit can host the path field outside the presented sheet's AX children.
        field = access.attribute(access.application, "AXFocusedUIElement")
        if (field is not None and field != previous and
                access.attribute(field, "AXRole") in ("AXTextField", "AXComboBox") and
                access.attribute(field, "AXSubrole") != "AXSearchField"):
            return field
        return None

    field = wait_for("Missing Go to Folder input", focused_folder_field, access.process)
    screen.guard()
    # Go to Folder resolves completions asynchronously. Deliver an edit event
    # and wait for the resolved directory before confirming the path.
    screen.keys["a"] = 0
    screen.key("a", screen.command)
    screen.key(str(fixture) + "/", unicode=True)
    access.control(fixture.name, ("AXStaticText",), root=panel)
    screen.key("Return")
    access.control(fixture.name, ("AXPopUpButton",), root=panel)

    def enabled_select():
        select = access.find("Select", ("AXButton",))
        return select if access.attribute(select, "AXEnabled") else None

    select = wait_for("Select did not enable for the fixture directory",
                      enabled_select, access.process, timeout=5)
    access.press(select)
    wait_for("Open panel did not dismiss",
             lambda: not access.find("Select", ("AXButton",)), access.process, timeout=5)
    access.control(EXTENSION)
    print("Installed the fixture in Chromium’s extension manager", flush=True)
    return manager


def open_manager(access, source):
    access.menu("Manage Extensions")
    manager = wait_for("Missing extension manager tab",
                       lambda: access.owner("Developer mode", ("AXCheckBox", "AXSwitch", "AXButton")), access.process)
    if manager != source:
        raise RuntimeError("The extension manager opened outside the invoking window")
    return manager


def close_manager(screen, access, source):
    screen.keys["w"] = 13
    screen.key("w", screen.command)
    wait_for("The source tab did not return after closing the manager",
             lambda: access.find(SOURCE, ("AXHeading",), root=source)
             and access.attribute(access.application, "AXFocusedWindow") == source, access.process)


def fixture_remove_button(access, manager):
    heading = access.find(EXTENSION, ("AXHeading",), root=manager)
    parent = access.attribute(heading, "AXParent")
    # Chromium exposes each card as siblings beginning with its heading.
    in_card = False
    for node in access.attribute(parent, "AXChildren") or ():
        role = access.attribute(node, "AXRole")
        if role == "AXHeading":
            if in_card:
                break
            in_card = node == heading
        elif (in_card and role == "AXButton" and "Remove" in access.names(node)
              and access.attribute(node, "AXEnabled")):
            return node
    return None


def fixture_removal_dialog(access, manager):
    titles = {f'Remove "{EXTENSION}"?', f'Remove “{EXTENSION}”?'}
    for element in access.tree(manager):
        if (access.attribute(element, "AXRole") in ("AXSheet", "AXDialog")
                or access.attribute(element, "AXSubrole") in ("AXDialog", "AXApplicationAlertDialog")):
            if any(titles.intersection(access.names(node)) for node in access.tree(element)):
                return element
    return None


def verify_removal(screen, access, source, events, output):
    screen.keys["r"] = 15
    for choice in ("Cancel", "Remove"):
        manager = open_manager(access, source)
        remove = wait_for("Missing Remove on the fixture's card",
                          lambda: fixture_remove_button(access, manager), access.process)
        access.press(remove)
        dialog = wait_for("Missing fixture removal confirmation in the extension manager",
                          lambda: fixture_removal_dialog(access, manager), access.process)
        screen.screenshot(output / f"uninstall-{choice.lower()}.png", include_owned_windows=True)
        access.press(access.control(choice, ("AXButton",), root=dialog))
        wait_for("Fixture removal confirmation did not dismiss",
                 lambda: not fixture_removal_dialog(access, manager), access.process)
        access.control("Load unpacked", ("AXButton",), root=manager)
        if choice == "Cancel":
            access.control(EXTENSION, ("AXHeading",), root=manager)
        else:
            wait_for("The uninstalled fixture remained in the manager",
                     lambda: not access.find(EXTENSION, ("AXHeading",), root=manager), access.process)
        close_manager(screen, access, source)

        ready = events.count("/ready")
        screen.key("r", screen.command)
        wait_for("The source did not reload after extension removal confirmation",
                 lambda: events.count("/ready") > ready, access.process)
        access.control(SOURCE, ("AXHeading",), root=source)
        print(f"The source reloaded after {choice}.", flush=True)


def show_site_controls(screen, access, source):
    def address():
        return next((element for element in access.tree(source)
                     if access.attribute(element, "AXRole") == "AXButton"
                     and (any("127.0.0.1" in name for name in access.names(element))
                          or access.attribute(element, "AXHelp") == "Search or Enter URL...")), None)

    screen.guard()
    button = wait_for("Missing source address control",
                      lambda: address() or access.find("Site Controls", ("AXButton",), root=source),
                      access.process, timeout=8)
    access.hover(button)
    access.press(access.control("Site Controls", ("AXButton",), root=source))


def exercise(screen, process, events, output):
    access = Accessibility(screen, process)
    try:
        wait_for("Source page did not load", lambda: "/ready" in events, process, timeout=30)
        screen.guard()
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        source = wait_for("Missing source window", lambda: access.owner(SOURCE), process)
        fixture = output / "Bark unpacked action fixture"
        shutil.copytree(HERE / "fixture", fixture)
        install_extension(screen, access, source, fixture)
        close_manager(screen, access, source)

        pin, unpin = f"Pin {ACTION}", f"Unpin {ACTION}"
        show_site_controls(screen, access, source)
        access.press(access.control(pin, ("AXButton",), root=source))
        access.control(unpin, ("AXButton",), root=source)
        access.press(access.control("Site Controls", ("AXButton",), root=source))
        wait_for("Site Controls stayed open", lambda: not access.find(unpin, root=source), process)
        def invoke_pinned(control, evidence):
            access.press(control)
            access.control(POPUP, ("AXButton",))
            screen.screenshot(output / evidence, include_owned_windows=True)
            screen.key("Escape")
            wait_for("Extension popup stayed open", lambda: not access.find(POPUP), process)

        pinned = access.control(ACTION, ("AXButton",), root=source)
        sidebar_center = access.center(pinned)
        screen.screenshot(output / "pinned.png")
        invoke_pinned(pinned, "sidebar-popup.png")
        print("Opened the pinned extension popup from the sidebar", flush=True)

        access.menu("Show Toolbar")

        def toolbar_action():
            control = access.find(ACTION, ("AXButton",), root=source)
            if control is not None and access.center(control) != sidebar_center:
                return control
            return None

        toolbar = wait_for("Pinned action did not move to the shown toolbar",
                           toolbar_action, process)
        invoke_pinned(toolbar, "toolbar-popup.png")
        print("Opened the same pinned extension popup from the shown toolbar", flush=True)
        show_site_controls(screen, access, source)
        access.press(access.control(unpin, ("AXButton",), root=source))
        access.control(pin, ("AXButton",), root=source)
        access.press(access.control("Site Controls", ("AXButton",), root=source))
        wait_for("Site Controls stayed open", lambda: not access.find(pin, root=source), process)
        if access.find(ACTION, ("AXButton",), root=source):
            raise RuntimeError("The unpinned action remained in the address bar")
        print("Unpinned the action in the presenting profile", flush=True)

        verify_removal(screen, access, source, events, output)

        screen.key("q", screen.command)
        quit_button = wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process, timeout=5)
        screen.press_button(quit_button)
    except BaseException:
        access.dump(output / "accessibility.json")
        raise


if __name__ == "__main__":
    sys.exit(run_walk("Signed Bark extension actions and removal", "actions", serve,
                      exercise, official_qualification=True))
