#!/usr/bin/env python3
"""Walk Arc and Chrome import in a signed Bark app with a disposable profile."""

import argparse
import hashlib
from contextlib import suppress
from http.server import HTTPServer
import json
import math
import os
from pathlib import Path
import runpy
import signal
import sqlite3
import subprocess
import sys
import tempfile
from threading import Thread
import time
from uuid import uuid4

import fixtures

REPO = Path(__file__).resolve().parents[2]
MENU = "Import from Another Browser…"
EXPECTED = {
    "Chrome": (["Work", "Fixture Person"],
               ["2 spaces", "6 tabs and bookmarks", "4 history visits", "3 extensions found", "Skipped Gone"]),
    "Arc": (["Fixture Space", "Arc Work Space", "Fixture Errands"],
            ["3 spaces", "6 tabs and bookmarks", "2 history visits", "1 extension found"]),
}


def wait_for(description, condition, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(0.2)
    raise RuntimeError(description)


def app_processes(app):
    rows = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
    return [row for row in rows if row.startswith("/") and os.path.realpath(row).startswith(str(app) + "/")]


def manifest(path):
    return {str(f.relative_to(path)): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in path.rglob("*") if f.is_file()}


def tree(root):
    directory = root / "App/Tabs"
    structure = json.loads((directory / "structure.json").read_text())
    device = json.loads((directory / "device.json").read_text())
    spaces = sorted((s for s in structure["spaces"] if not s.get("deletedAt")),
                    key=lambda s: (s.get("isAgent", False), s.get("order", ""), s["id"]))
    items = {i["id"]: {k: i[k] for k in ("parent", "order", "kind", "customTitle") if k in i}
             for i in structure.get("items", []) + device["items"] if not i.get("deletedAt")}
    return spaces, items


def add_seeded_spaces(root, address):
    directory = root / "App/Tabs"
    structure_path, device_path = directory / "structure.json", directory / "device.json"
    structure, device = [json.loads(path.read_text()) for path in (structure_path, device_path)]
    now = time.time() - 978307200
    for order, name in [("k", "Personal fixture"), ("s", "Research fixture")]:
        space, tab = (str(uuid4()).upper() for _ in range(2))
        structure["spaces"].append({"id": space, "name": name, "icon": "globe", "accentHex": "#265A8F",
                                    "order": order, "modifiedAt": now})
        device["items"].append({"id": tab, "kind": {"tab": {"url": address, "pageTitle": name}},
                                "order": "V", "parent": {"tabs": {"spaceID": space}}, "modifiedAt": now})
        device["state"]["windows"][0]["selectedItemBySpace"].extend((space, tab))
    for path, data in [(structure_path, structure), (device_path, device)]:
        path.write_text(json.dumps(data))


def history_count(root):
    database = (root / "App/default.store").as_uri() + "?mode=ro"
    with sqlite3.connect(database, uri=True) as connection:
        return connection.execute("SELECT COALESCE(SUM(ZVISITCOUNT), 0) FROM ZHISTORYENTITY "
                                  "WHERE ZURL LIKE 'https://fixture.test/%'").fetchone()[0]


class ImportWalk:
    def __init__(self, proc, lock, output):
        import ApplicationServices as ax
        from Foundation import NSURL
        import Quartz as cg

        self.proc, self.lock, self.output = proc, lock, output
        self.ax, self.cg, self.url = ax, cg, NSURL
        self.console, self.owns_screen, self.pointer = lock
        self.app = self.ax.AXUIElementCreateApplication(self.proc.pid)
        self.source = cg.CGEventSourceCreate(cg.kCGEventSourceStateHIDSystemState)
        self.results = []

    def guard(self, point=None):
        if not self.owns_screen() or not self.console.available():
            raise RuntimeError("Lost the screen lock or unlocked console")
        expected = point if point is not None else self.pointer
        if math.dist(self.console.pointer(), expected) > 6:
            raise RuntimeError("The pointer moved unexpectedly")
        asn = subprocess.check_output(["lsappinfo", "front"], text=True).strip()
        front = subprocess.check_output(["lsappinfo", "info", "-only", "pid", asn], text=True).strip()
        if front.split("=")[-1] != str(self.proc.pid):
            raise RuntimeError("The disposable candidate lost foreground focus")

    def note(self, step, **details):
        self.results.append({"step": step, **details})
        (self.output / "result.json").write_text(json.dumps(self.results, indent=2) + "\n")
        print(step, flush=True)

    def get(self, element, name):
        if element is None:
            return None
        status, value = self.ax.AXUIElementCopyAttributeValue(element, name, None)
        return value if status == 0 else None

    def names(self, element):
        return [t for key in ("AXTitle", "AXDescription", "AXValue")
                if isinstance(t := self.get(element, key), str)]

    def search(self, *, focused=True):
        self.guard()
        windows = ([self.get(self.app, "AXFocusedWindow")] if focused else self.get(self.app, "AXWindows")) or []
        pending = [(window, 0) for window in windows if window is not None]
        while pending:
            element, depth = pending.pop()
            yield element
            if depth < 30:
                pending.extend((child, depth + 1) for child in self.get(element, "AXChildren") or [])

    def named(self, name, role=None, *, contains=False):
        return next((el for el in self.search()
                     if (role is None or self.get(el, "AXRole") == role)
                     and any(name in word if contains else name == word for word in self.names(el))), None)

    def locate(self, name, role=None, contains=False, timeout=15):
        return wait_for(f"Missing {name}", lambda: self.named(name, role, contains=contains), timeout)

    def windows(self):
        q = self.cg
        return [row for row in q.CGWindowListCopyWindowInfo(q.kCGWindowListOptionOnScreenOnly, q.kCGNullWindowID)
                if row["kCGWindowOwnerPID"] == self.proc.pid and row["kCGWindowLayer"] == 0
                and row["kCGWindowBounds"]["Width"] >= 400 and row["kCGWindowBounds"]["Height"] >= 200]

    def click(self, point):
        self.guard()
        x, y = point
        if not any(b["X"] <= x < b["X"] + b["Width"] and b["Y"] <= y < b["Y"] + b["Height"]
                   for b in (w["kCGWindowBounds"] for w in self.windows())):
            raise RuntimeError("Click target is outside the candidate's windows")
        q = self.cg

        def post(kind):
            event = q.CGEventCreateMouseEvent(self.source, kind, point, 0)
            q.CGEventPost(q.kCGHIDEventTap, event)

        post(q.kCGEventMouseMoved)
        time.sleep(0.08)
        self.guard(point)
        post(q.kCGEventLeftMouseDown)
        time.sleep(0.04)
        post(q.kCGEventLeftMouseUp)
        self.guard(point)
        self.pointer = point

    def click_control(self, name, role="AXButton"):
        el = self.locate(name, role)
        ax = self.ax
        _, pos = ax.AXValueGetValue(self.get(el, "AXPosition"), ax.kAXValueCGPointType, None)
        _, size = ax.AXValueGetValue(self.get(el, "AXSize"), ax.kAXValueCGSizeType, None)
        if size.width <= 0 or size.height <= 0:
            raise RuntimeError(f"Empty accessibility frame for {name}")
        self.click((pos.x + size.width / 2, pos.y + size.height / 2))

    def key(self, code):
        self.guard()
        q = self.cg
        for down in (True, False):
            event = q.CGEventCreateKeyboardEvent(self.source, code, down)
            q.CGEventSetFlags(event, q.kCGEventFlagMaskCommand)
            q.CGEventPost(q.kCGHIDEventTap, event)
            time.sleep(0.04)

    def menu(self):
        self.guard()
        bar = self.get(self.app, "AXMenuBar")
        for top in self.get(bar, "AXChildren") or []:
            for menu in self.get(top, "AXChildren") or []:
                for item in self.get(menu, "AXChildren") or []:
                    if MENU in self.names(item):
                        if self.ax.AXUIElementPerformAction(item, "AXPress") != 0:
                            raise RuntimeError("The candidate refused its app menu command")
                        self.locate("Import from Another Browser")
                        return
        raise RuntimeError(f"Missing app menu command {MENU}")

    def capture(self, name):
        self.guard()
        q = self.cg
        img = q.CGWindowListCreateImage(q.CGRectNull, q.kCGWindowListOptionIncludingWindow,
                                        self.windows()[0]["kCGWindowNumber"], q.kCGWindowImageBoundsIgnoreFraming)
        path = self.output / (name + ".png")
        destination = q.CGImageDestinationCreateWithURL(self.url.fileURLWithPath_(str(path)), "public.png", 1, None)
        q.CGImageDestinationAddImage(destination, img, None)
        if not q.CGImageDestinationFinalize(destination):
            raise RuntimeError("Writing the candidate window capture failed")

    def select(self, browser):
        button = f"Import from {browser}"
        if self.named(button, "AXButton") is None:
            self.click_control(browser, "AXRadioButton")
        self.locate(button, "AXButton")
        return button

    def repeat(self, browser, root):
        names, counts = EXPECTED[browser]
        before, original_items = tree(root)
        for attempt in (1, 2):
            self.menu()
            button = self.select(browser)
            if attempt == 2:
                self.locate(f"Last imported from {browser} on", contains=True)
                self.capture("last-import")
            self.click_control(button)
            self.locate("Done", "AXButton", timeout=90)
            for label in counts:
                self.locate(label, contains=True)
            self.locate("Cookies and passwords", contains=True)
            self.capture(f"result-{attempt}")
            self.click_control("Done")
            wait_for("Clicking Done did not dismiss the result", lambda: self.named("Done", "AXButton") is None)

            def persisted():
                spaces, items = tree(root)
                return (spaces, items) if len(spaces) == len(before) + attempt * len(names) else None

            spaces, items = wait_for("Imported spaces were not persisted", persisted)
            assert [s["id"] for s in spaces[:len(before)]] == [s["id"] for s in before]
            assert {k: items.get(k) for k in original_items} == original_items
            assert [s["name"] for s in spaces[len(before):]] == names * attempt
            self.note("Import preserved existing items and appended the selected browser’s spaces",
                      browser=browser, attempt=attempt, spaces=[s["name"] for s in spaces])
        assert browser.lower() in json.loads((root / "App/LastImports.json").read_text())

    def stop_shared(self, root):
        before = len(tree(root)[0])
        self.menu()
        self.click_control(self.select("Chrome"))
        self.locate("Stop Import", "AXButton")
        self.locate("Importing history:", contains=True)
        bounds = self.windows()[0]["kCGWindowBounds"]
        self.click((bounds["X"] + 40, bounds["Y"] + bounds["Height"] - 40))
        self.locate("Stop Import", "AXButton")
        self.capture("after-scrim")
        self.note("Clicking the scrim left the running import visible")
        previous_window = self.get(self.app, "AXFocusedWindow")
        self.key(45)  # Cmd+N
        wait_for("A second browser window did not become key",
                 lambda: len(self.windows()) == 2 and self.get(self.app, "AXFocusedWindow") != previous_window)
        self.menu()
        self.locate("Stop Import", "AXButton")
        assert self.named("Import from Chrome", "AXButton") is None
        self.capture("second-window")
        self.click_control("Stop Import")
        self.locate("The import was stopped.", contains=True)
        self.click_control("Done")
        self.menu()
        self.locate("Import from Chrome", "AXButton")
        self.click_control("Maybe later")
        assert len(tree(root)[0]) == before + 1
        self.note("The second window shared the running import and its Stop result")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--session", choices=("repeat", "stop-shared"), required=True)
    parser.add_argument("--browser", choices=EXPECTED, default="Chrome", help="Browser for the repeat session")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This walk requires macOS")
    import ApplicationServices as ax
    import Quartz as cg
    sys.path.insert(0, str(REPO / "scripts"))
    from bark_macos_console import SCREEN_LOCK, QuartzConsole, require_idle_console, screen_lock

    if not (ax.AXIsProcessTrusted() and cg.CGPreflightPostEventAccess() and cg.CGPreflightScreenCaptureAccess()):
        parser.error("Existing Accessibility, input posting and Screen Recording access is required")
    app = args.app.resolve(strict=True)
    binary = app / "Contents/MacOS/Bark"
    if not binary.is_file() or app_processes(app):
        parser.error("Pass a signed Bark candidate that is not running")
    contributor = runpy.run_path(str(REPO / "scripts/bark-check.py"))
    contributor["verify_signed_shell"](app)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    console = QuartzConsole()

    with tempfile.TemporaryDirectory(prefix="bark-import-", dir="/private/tmp") as tmp,             HTTPServer(("127.0.0.1", 0), contributor["SmokePage"]) as fixture:
        root = Path(tmp)
        profile = str(uuid4()).upper()
        address = f"http://127.0.0.1:{fixture.server_port}/"
        contributor["seed_profile"](root, profile, address)
        add_seeded_spaces(root, address)
        if args.session == "repeat":
            fixtures.write(root, int(time.time()))
        else:
            fixtures.chrome_big(root, int(time.time()), 50_000, 0)
        source_manifest = manifest(root / "Import")
        domain = "ee.qdo.nook.chromium-verification." + hashlib.sha256(os.fsencode(root)).hexdigest()
        crash_dir = Path.home() / "Library/Logs/DiagnosticReports"
        crashes = set(crash_dir.glob("Bark*"))
        server = Thread(target=fixture.serve_forever, daemon=True)
        server.start()
        try:
            for key, kind, value in [("settings.defaultBrowserPromptDismissedAt", "-float", str(time.time())),
                                     ("settings.startupLoadMode", "-string", "nothing")]:
                subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
            with screen_lock(SCREEN_LOCK, wait=30) as owns_screen, (output / "app.log").open("wb") as log:
                pointer = console.pointer()
                time.sleep(0.4)
                require_idle_console(console, owns_screen, pointer, min_idle=10)
                proc = subprocess.Popen([str(binary), f"--barc-app-data-dir={root}", f"--barc-app-profile={profile}"],
                                        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    wait_for("The candidate did not load the seeded page", lambda: getattr(fixture, "rendered", False), 45)
                    walk = ImportWalk(proc, (console, owns_screen, pointer), output)
                    if args.session == "repeat":
                        walk.repeat(args.browser, root)
                    else:
                        walk.stop_shared(root)
                    walk.key(12)  # Cmd+Q
                    walk.click_control("Quit")
                    if proc.wait(timeout=30) != 0:
                        raise RuntimeError("The candidate did not quit cleanly")
                    wait_for("Candidate left processes behind", lambda: not app_processes(app))
                    walk.note("Quit confirmation exited cleanly with no candidate processes")
                except Exception:
                    if proc.poll() is None and "walk" in locals():
                        with suppress(Exception):
                            walk.capture("failure")
                            (output / "accessibility.txt").write_text("\n".join(
                                f"{walk.get(element, 'AXRole')}: {walk.names(element)}"
                                for element in walk.search(focused=False)))
                    raise
                finally:
                    if proc.poll() is None or app_processes(app):
                        contributor["stop"](proc)
            if args.session == "repeat":
                count = history_count(root)
                assert count == (8 if args.browser == "Chrome" else 4), count
                walk.note("Persisted both imports’ history visits", visits=count)
            assert manifest(root / "Import") == source_manifest
            assert not any((root / "App/ImportCopies").glob("*"))
            assert not set(crash_dir.glob("Bark*")) - crashes
            assert not any(word in (output / "app.log").read_text(errors="replace") for word in ("FATAL", "Check failed"))
        finally:
            subprocess.run(["defaults", "delete", domain], capture_output=True)
            fixture.shutdown()
            server.join()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    main()
