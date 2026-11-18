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


def install_extension(screen, access, fixture):
    access.menu("Manage Extensions")
    developer_mode = access.control("Developer mode", ("AXCheckBox", "AXSwitch", "AXButton"))
    if access.attribute(developer_mode, "AXValue") in (False, None, 0, "0"):
        access.press(developer_mode)
    access.press(access.control("Load unpacked", ("AXButton",)))
    access.control("Select", ("AXButton",))
    screen.keys["g"] = 5
    screen.key("g", screen.command | screen.shift)

    def focused_folder_field():
        for window in access.windows():
            for element in access.tree(window):
                if (access.attribute(element, "AXRole") in ("AXTextField", "AXComboBox")
                        and access.attribute(element, "AXFocused")
                        and not any("Find" in label for label in access.names(element))):
                    return element
        return None

    field = wait_for("Missing Go to Folder input", focused_folder_field, access.process, timeout=5)
    screen.guard()
    path = str(fixture)
    if access.ax.AXUIElementSetAttributeValue(field, "AXValue", path) != 0:
        screen.key(path, unicode=True)
    screen.key("Return")
    access.control(fixture.name, ("AXPopUpButton",))

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
        fixture = output / "fixture"
        shutil.copytree(HERE / "fixture", fixture)
        install_extension(screen, access, fixture)
        utility = wait_for("Missing extension utility window",
                           lambda: access.owner("Load unpacked", ("AXButton",)), process)
        if utility == source:
            raise RuntimeError("The extension manager replaced the source window")
        close = access.find("Close Window", ("AXButton",), root=utility)
        close = close or access.attribute(utility, "AXCloseButton")
        if close is None:
            raise RuntimeError("Missing extension utility close button")
        access.press(close)
        wait_for("Extension utility did not close",
                 lambda: not access.owner("Load unpacked", ("AXButton",)), process)
        wait_for("Source window did not regain focus",
                 lambda: access.attribute(access.application, "AXFocusedWindow") == source,
                 process)

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

        screen.key("q", screen.command)
        quit_button = wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process, timeout=5)
        screen.press_button(quit_button)
    except BaseException:
        access.dump(output / "accessibility.json")
        raise


if __name__ == "__main__":
    sys.exit(run_walk("Signed extension action sidebar", "actions", serve, exercise))
