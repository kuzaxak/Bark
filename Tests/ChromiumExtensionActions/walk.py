#!/usr/bin/env python3
"""Exercise a real installed extension action in a signed Bark window."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import sys
from threading import Thread
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import run_walk, wait_for

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


class Accessibility:
    def __init__(self, screen, process):
        self.screen = screen
        self.process = process
        self.ax = screen.ax
        self.application = self.ax.AXUIElementCreateApplication(process.pid)

    def attribute(self, element, key):
        if element is None:
            return None
        status, value = self.ax.AXUIElementCopyAttributeValue(element, key, None)
        return value if status == 0 else None

    def names(self, element):
        return [value for name in ("AXTitle", "AXDescription", "AXValue")
                if isinstance(value := self.attribute(element, name), str)]

    def tree(self, root):
        pending = [(root, 0)] if root is not None else []
        while pending:
            element, depth = pending.pop()
            yield element
            if depth < 24:
                pending.extend((child, depth + 1)
                               for child in self.attribute(element, "AXChildren") or ())

    def windows(self):
        return self.attribute(self.application, "AXWindows") or ()

    def find(self, label, roles=(), root=None):
        for start in (root,) if root is not None else self.windows():
            for element in self.tree(start):
                if (not roles or self.attribute(element, "AXRole") in roles) and label in self.names(element):
                    return element
        return None

    def control(self, label, roles=(), root=None):
        return wait_for(f"Missing {label}", lambda: self.find(label, roles, root), self.process, timeout=10)

    def owner(self, label, roles=()):
        return next((window for window in self.windows() if self.find(label, roles, root=window)), None)

    def press(self, element):
        self.screen.press_button(element)

    def center(self, element):
        self.screen.guard()

        def position(key, kind):
            ref = self.attribute(element, key)
            if ref is None:
                raise RuntimeError(f"Missing {key} on the candidate control")
            ok, value = self.ax.AXValueGetValue(ref, kind, None)
            if not ok:
                raise RuntimeError(f"Unreadable {key} on the candidate control")
            return value

        origin = position("AXPosition", self.ax.kAXValueCGPointType)
        size = position("AXSize", self.ax.kAXValueCGSizeType)
        return (origin.x + size.width / 2, origin.y + size.height / 2)

    def hover(self, element):
        point = self.center(element)
        if not any(bounds["X"] <= point[0] < bounds["X"] + bounds["Width"]
                   and bounds["Y"] <= point[1] < bounds["Y"] + bounds["Height"]
                   for window in self.screen.windows()
                   if (bounds := window["kCGWindowBounds"])):
            raise RuntimeError("The address control is outside the disposable candidate")
        quartz = self.screen.quartz
        event = quartz.CGEventCreateMouseEvent(self.screen.source, quartz.kCGEventMouseMoved, point, 0)
        quartz.CGEventPost(quartz.kCGHIDEventTap, event)
        time.sleep(0.15)
        self.screen.guard(point)
        self.screen.point = point

    def menu(self, label):
        menu = self.attribute(self.application, "AXMenuBar")
        self.press(self.control(label, ("AXMenuItem",), root=menu))

    def dump(self, path):
        labels = []
        for window in self.windows():
            for element in self.tree(window):
                if names := self.names(element):
                    labels.append([self.attribute(element, "AXRole"), names[:2]])
        path.write_text(json.dumps(labels, default=str, indent=2)[:200_000])


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
