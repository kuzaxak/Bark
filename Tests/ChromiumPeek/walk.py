#!/usr/bin/env python3
"""Walk a signed Intel Bark candidate with a new disposable profile."""

import argparse
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
from threading import Thread
import time
from uuid import uuid4

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SIDEBAR_WIDTH = 247
PAGE_MARGIN = 10


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/source", "/target"):
            self.send_error(404)
            return
        data = self.server.html.replace("PAGE", self.path[1:]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/events":
            self.send_error(404)
            return
        row = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        row["time"] = time.time()
        self.server.events.append(row)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.html = (HERE / "fixture.html").read_text()
        server.events = []
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def wait_for(description, predicate, process=None, timeout=12):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = predicate()
        if result is not None and result is not False:
            return result
        if process is not None and process.poll() is not None:
            raise RuntimeError(f"{description} (candidate exit status {process.returncode})")
        time.sleep(0.15)
    raise RuntimeError(description)


def processes(app):
    rows = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
    prefix = str(app) + "/"
    return [row for row in rows if row.startswith("/") and os.path.realpath(row).startswith(prefix)]


def crash_reports():
    return {p.name for p in (Path.home() / "Library/Logs/DiagnosticReports").glob("Bark*")}


class Screen:
    keys = {"Escape": 53, "s": 1, "p": 35, "q": 12}
    command = 1 << 20
    shift = 1 << 17

    def __init__(self, console, owns_screen, pid, point):
        import ApplicationServices as ax
        import Quartz as quartz
        from Foundation import NSURL

        self.ax, self.quartz, self.url = ax, quartz, NSURL
        self.console, self.owns_screen, self.pid, self.point = console, owns_screen, pid, point
        self.source = quartz.CGEventSourceCreate(quartz.kCGEventSourceStateHIDSystemState)

    def guard(self, target=None):
        if not self.owns_screen() or not self.console.available():
            raise RuntimeError("The screen lock or unlocked console was lost")
        expected = target if target is not None else self.point
        actual = self.console.pointer()
        if math.dist(expected, actual) > 6:
            raise RuntimeError(f"Pointer moved from {expected} to {actual}")
        asn = subprocess.check_output(["lsappinfo", "front"], text=True).strip()
        front = subprocess.check_output(["lsappinfo", "info", "-only", "pid", asn], text=True).strip()
        if front.split("=")[-1] != str(self.pid):
            raise RuntimeError("The disposable candidate is no longer frontmost")

    def windows(self):
        q = self.quartz
        rows = q.CGWindowListCopyWindowInfo(q.kCGWindowListOptionOnScreenOnly, q.kCGNullWindowID)
        return [row for row in rows if row["kCGWindowOwnerPID"] == self.pid
                and row["kCGWindowLayer"] == 0 and row["kCGWindowBounds"]["Width"] >= 400
                and row["kCGWindowBounds"]["Height"] >= 200]

    def click(self, relative, flags=0):
        self.guard()
        q = self.quartz
        bounds = self.windows()[0]["kCGWindowBounds"]
        x, y = relative
        if not 0 <= x < bounds["Width"] or not 0 <= y < bounds["Height"]:
            raise RuntimeError(f"Click {relative} is outside the target window")
        point = (bounds["X"] + x, bounds["Y"] + y)

        def post(kind, event_flags=0):
            event = q.CGEventCreateMouseEvent(self.source, kind, point, 0)
            q.CGEventSetFlags(event, event_flags)
            q.CGEventPost(q.kCGHIDEventTap, event)

        post(q.kCGEventMouseMoved)
        time.sleep(0.08)
        self.guard(point)
        post(q.kCGEventLeftMouseDown, flags)
        time.sleep(0.05)
        post(q.kCGEventLeftMouseUp, flags)
        self.guard(point)
        self.point = point

    def key(self, name, flags=0, unicode=False):
        self.guard()
        q = self.quartz
        for down in (True, False):
            event = q.CGEventCreateKeyboardEvent(self.source, self.keys.get(name, 0), down)
            if unicode:
                q.CGEventKeyboardSetUnicodeString(event, len(name), name)
            q.CGEventSetFlags(event, flags)
            q.CGEventPost(q.kCGHIDEventTap, event)
            time.sleep(0.025)

    def button(self, title):
        self.guard()
        ax = self.ax

        def get(el, name):
            status, result = ax.AXUIElementCopyAttributeValue(el, name, None)
            return result if status == 0 else None

        pending = [(item, 0) for item in get(ax.AXUIElementCreateApplication(self.pid), "AXWindows") or []]
        while pending:
            element, depth = pending.pop()
            if (get(element, "AXRole") == "AXButton" and
                    title in (get(element, "AXTitle"), get(element, "AXDescription"))):
                return element
            if depth < 25:
                pending.extend((child, depth + 1) for child in get(element, "AXChildren") or [])
        return None

    def press_button(self, button):
        self.guard()
        if self.ax.AXUIElementPerformAction(button, "AXPress") != 0:
            raise RuntimeError("The candidate refused the accessibility button action")

    def screenshot(self, path):
        self.guard()
        q = self.quartz
        picture = q.CGWindowListCreateImage(q.CGRectNull, q.kCGWindowListOptionIncludingWindow,
                                           self.windows()[0]["kCGWindowNumber"], q.kCGWindowImageBoundsIgnoreFraming)
        if not picture:
            raise RuntimeError("Candidate window capture failed")
        destination = q.CGImageDestinationCreateWithURL(self.url.fileURLWithPath_(str(path)), "public.png", 1, None)
        q.CGImageDestinationAddImage(destination, picture, None)
        if not q.CGImageDestinationFinalize(destination):
            raise RuntimeError("Writing the candidate window capture failed")


def source_point(event, name):
    x, y = event[name]
    return SIDEBAR_WIDTH + x, PAGE_MARGIN + y


def exercise(screen, proc, events, output):
    steps = []

    def note(step, row):
        steps.append({"step": step, **row})
        (output / "result.json").write_text(json.dumps(steps, indent=2) + "\n")
        print(step, flush=True)

    def event(page, kind, since=0, **where):
        return wait_for(f"{kind} did not reach {page}",
                        lambda: next((row for row in events[since:] if row["page"] == page and row["event"] == kind
                                      and all(row.get(key) == value for key, value in where.items())), None), proc)

    def draft(page, ready, text):
        if page == "/source":
            screen.click(source_point(ready, "draftPoint"))
        since = len(events)
        for char in text:
            screen.key(char, unicode=True)
        return event(page, "input", since, trusted=True, value=text, documentID=ready["documentID"])

    source = event("/source", "ready")
    wait_for("the seeded window never reached its saved size",
             lambda: any(row["kCGWindowBounds"]["Width"] == 900 for row in screen.windows()), proc)
    draft("/source", source, "sourcedraft")
    screen.screenshot(output / "source.png")

    def peek():
        since = len(events)
        screen.click(source_point(source, "linkPoint"), flags=screen.shift)
        linked = event("/source", "link", since, trusted=True, shift=True, documentID=source["documentID"])
        target = event("/target", "ready", since)
        wait_for("Missing Peek card actions", lambda: screen.button("Open in Split View"), proc)
        if len(screen.windows()) != 1:
            raise RuntimeError("Shift-click opened a new window")
        note("Trusted Shift-click opened Peek", {"link": linked, "target": target})
        return target

    first = peek()
    screen.screenshot(output / "peek.png")
    draft("/target", first, "firstpeek")
    since = len(events)
    screen.key("Escape")
    event("/target", "key", since, key="Escape", trusted=True)
    wait_for("Escape left the Peek actions visible", lambda: screen.button("Open in Split View") is None, proc)
    screen.key("s")
    note("Escape restored the same source draft and keyboard focus",
         event("/source", "key", since, key="s", trusted=True, documentID=source["documentID"], value="sourcedraft"))

    second = peek()
    if second["documentID"] == first["documentID"]:
        raise RuntimeError("The dismissed Peek document was reused")
    card = draft("/target", second, "keptinpeek")
    since = len(events)
    screen.press_button(wait_for("Missing Peek split action", lambda: screen.button("Open in Split View"), proc))
    wait_for("Opening a split did not resize the Peek into a pane",
             lambda: any(row["documentID"] == second["documentID"] and row["event"] == "resize"
                         and row["viewport"] < card["viewport"] * 0.80 for row in events[since:]), proc)
    wait_for("The split action remained in the window after promotion",
             lambda: screen.button("Open in Split View") is None, proc)
    screen.key("p")
    note("Split promotion retained the same Peek document, draft and keyboard focus",
         event("/target", "key", since, key="p", trusted=True, documentID=second["documentID"], value="keptinpeek"))
    screen.screenshot(output / "split.png")
    screen.key("q", flags=screen.command)
    screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), proc))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Signed Intel Bark.app")
    parser.add_argument("--output", type=Path, required=True, help="New directory for test evidence")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This walk requires macOS")
    sys.path.insert(0, str(REPO / "Runtime/Chromium"))
    from run_browser_tests import (SCREEN_LOCK, SCREEN_UNAVAILABLE, QuartzConsole, ScreenUnavailable,
                                   require_idle_console, screen_lock)
    import ApplicationServices as ax
    import Quartz as quartz

    if not (ax.AXIsProcessTrusted() and quartz.CGPreflightPostEventAccess() and quartz.CGPreflightScreenCaptureAccess()):
        parser.error("The runner needs existing Accessibility, event-posting and Screen Recording access")
    app = args.app.resolve(strict=True)
    binary = app / "Contents/MacOS/Bark"
    if not binary.is_file() or processes(app):
        parser.error("Pass a candidate that is not already running")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    contributor = runpy.run_path(str(REPO / "scripts/bark-check.py"))
    console = QuartzConsole()
    crashes = crash_reports()

    try:
        with serve() as server, tempfile.TemporaryDirectory(prefix="bark-peek-", dir="/private/tmp") as folder:
            profile = str(uuid4()).upper()
            root = Path(folder)
            domain = "ee.qdo.nook.chromium-verification." + hashlib.sha256(os.fsencode(root)).hexdigest()
            contributor["seed_profile"](root, profile, f"http://127.0.0.1:{server.server_port}/source")
            preferences = [("settings.peekOnShiftClick", "-bool", "true"),
                           ("settings.defaultBrowserPromptDismissedAt", "-float", str(time.time()))]
            try:
                for key, kind, value in preferences:
                    subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
                with screen_lock(SCREEN_LOCK, wait=30) as owns_screen, (output / "app.log").open("wb") as log:
                    start_pointer = console.pointer()
                    time.sleep(0.4)
                    require_idle_console(console, owns_screen, start_pointer, min_idle=10)
                    proc = subprocess.Popen([str(binary), f"--barc-app-data-dir={root}", f"--barc-app-profile={profile}"],
                                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        screen = Screen(console, owns_screen, proc.pid, start_pointer)
                        exercise(screen, proc, server.events, output)
                        if proc.wait(timeout=30) != 0:
                            raise RuntimeError("The signed candidate did not quit cleanly")
                        wait_for("Candidate processes were left behind", lambda: not processes(app))
                    finally:
                        if proc.poll() is None or processes(app):
                            contributor["stop"](proc)
                if crash_reports() - crashes or "FATAL:" in (output / "app.log").read_text(errors="replace"):
                    raise RuntimeError("The candidate wrote a fatal log or a crash report")
                print("Quit confirmation exited cleanly and left no candidate processes", flush=True)
            finally:
                (output / "events.json").write_text(json.dumps(server.events, indent=2) + "\n")
                subprocess.run(["defaults", "delete", domain], capture_output=True)
    except ScreenUnavailable as failure:
        print(failure, file=sys.stderr)
        return SCREEN_UNAVAILABLE
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    sys.exit(main())
