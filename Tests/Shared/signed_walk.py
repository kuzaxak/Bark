"""Launch a signed Bark candidate and drive its windows in a disposable profile."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time
from uuid import uuid4


REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / folder) for folder in ("Runtime/Chromium", "scripts")]
from bark_release import bundle_cdhash
from run_browser_tests import ScreenUnavailable


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
    keys = {"Return": 36, "Escape": 53, "s": 1, "p": 35, "q": 12}
    command = 1 << 20
    shift = 1 << 17

    def __init__(self, console, owns_screen, pid, point, launch_started_ns):
        import ApplicationServices as ax
        import Quartz as quartz
        from Foundation import NSURL

        self.ax, self.quartz, self.url = ax, quartz, NSURL
        self.console, self.owns_screen, self.pid, self.point = console, owns_screen, pid, point
        self.launch_started_ns = launch_started_ns
        self.source = quartz.CGEventSourceCreate(quartz.kCGEventSourceStateHIDSystemState)

    def guard(self, target=None):
        if not self.owns_screen() or not self.console.available():
            raise ScreenUnavailable("The screen lock or unlocked console was lost")
        expected = target if target is not None else self.point
        actual = self.console.pointer()
        if math.dist(expected, actual) > 6:
            if target is None:
                raise ScreenUnavailable(f"Pointer moved between test inputs from {expected} to {actual}")
            raise RuntimeError(f"Posted pointer event missed {target}, observed {actual}")
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

    def hover(self, point):
        self.guard()
        if not any(bounds["X"] <= point[0] < bounds["X"] + bounds["Width"]
                   and bounds["Y"] <= point[1] < bounds["Y"] + bounds["Height"]
                   for window in self.windows() if (bounds := window["kCGWindowBounds"])):
            raise RuntimeError("The hover target is outside the disposable candidate")
        q = self.quartz
        event = q.CGEventCreateMouseEvent(self.source, q.kCGEventMouseMoved, point, 0)
        q.CGEventPost(q.kCGHIDEventTap, event)
        time.sleep(0.15)
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

    def screenshot(self, path, *, include_owned_windows=False):
        self.guard()
        q = self.quartz
        if include_owned_windows:
            rows = q.CGWindowListCopyWindowInfo(q.kCGWindowListOptionOnScreenOnly, q.kCGNullWindowID)
            ids = [row["kCGWindowNumber"] for row in rows if row["kCGWindowOwnerPID"] == self.pid]
            picture = q.CGWindowListCreateImageFromArray(q.CGRectNull, ids, q.kCGWindowImageBoundsIgnoreFraming)
        else:
            picture = q.CGWindowListCreateImage(q.CGRectNull, q.kCGWindowListOptionIncludingWindow,
                                               self.windows()[0]["kCGWindowNumber"], q.kCGWindowImageBoundsIgnoreFraming)
        if not picture:
            raise RuntimeError("Candidate window capture failed")
        destination = q.CGImageDestinationCreateWithURL(self.url.fileURLWithPath_(str(path)), "public.png", 1, None)
        q.CGImageDestinationAddImage(destination, picture, None)
        if not q.CGImageDestinationFinalize(destination):
            raise RuntimeError("Writing the candidate window capture failed")


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
        self.screen.hover(self.center(element))

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


def verify_native_candidate(contributor, app):
    architecture = contributor["native_architecture"]()
    contributor["verify_signed_shell"](app, architecture)
    return architecture


def verify_pinned_sdk(contributor, architecture, app=None, *, require_official=False):
    """Return the cached SDK and evidence only after the required checks pass."""
    cached = contributor["cached_engine"](architecture)
    if not cached.is_dir():
        raise ValueError(f"Install this checkout's pinned {architecture} Bark SDK first.")
    with tempfile.TemporaryDirectory(prefix="bark-sdk-preflight-", dir="/private/tmp") as folder:
        working = Path(folder)
        with contributor["pinned_engine"](str(cached), working, architecture, require_official=require_official) as engine:
            if app is not None:
                contributor["verify_candidate"](app, engine, working, architecture)
            digest = hashlib.sha256((engine / "SHA256SUMS").read_bytes()).hexdigest()
            if digest != contributor["read_pin"](contributor["PACKAGE"], architecture):
                raise ValueError("The checkout SDK pin changed during verification.")
            return engine, {"architecture": architecture, "sdk_pin": digest,
                            "official": True if require_official else None}


def verify_official_sdk(contributor, architecture, app=None):
    return verify_pinned_sdk(contributor, architecture, app, require_official=True)


def launch_verified(app, cdhash, root, profile, log, app_output_lock):
    with app_output_lock(app):
        if bundle_cdhash(app) != cdhash:
            raise RuntimeError("The signed Bark app changed before launch.")
        started = time.monotonic_ns()
        process = subprocess.Popen([str(app / "Contents/MacOS/Bark"), f"--barc-app-data-dir={root}",
                                    f"--barc-app-profile={profile}"],
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    return process, started


def run_walk(description, name, serve, exercise, preferences=(), *,
             source_host="127.0.0.1", prepare_fixture=None, official_qualification=False, relaunch=None,
             parse_options=None):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--app", type=Path, required=True, help="Signed Bark.app for this Mac’s native architecture")
    parser.add_argument("--output", type=Path, required=True, help="New directory for test evidence")
    if official_qualification:
        verification = parser.add_mutually_exclusive_group()
        verification.add_argument("--require-official", action="store_true",
                                  help="verify the native official SDK and signed payload")
        verification.add_argument("--verify-sdk", action="store_true",
                                  help="verify the pinned native SDK and signed payload without checking official provenance")
    args = parser.parse_args() if parse_options is None else parse_options(parser)
    if sys.platform != "darwin":
        parser.error("This walk requires macOS")
    from run_browser_tests import (SCREEN_LOCK, SCREEN_UNAVAILABLE, QuartzConsole,
                                   require_idle_console, screen_lock)
    app = args.app.resolve(strict=True)
    binary = app / "Contents/MacOS/Bark"
    if not binary.is_file() or processes(app):
        parser.error("Pass a candidate that is not already running")
    contributor = runpy.run_path(str(REPO / "scripts/bark-check.py"))
    with contributor["app_output_lock"](app):
        if getattr(args, "require_official", False) or getattr(args, "verify_sdk", False):
            architecture = contributor["native_architecture"]()
            try:
                _, qualification = verify_pinned_sdk(contributor, architecture, app,
                                                      require_official=args.require_official)
            except (OSError, ValueError, subprocess.CalledProcessError) as error:
                parser.error(str(error))
        else:
            qualification = {"architecture": verify_native_candidate(contributor, app)}
        qualification["bundle_cdhash"] = bundle_cdhash(app)
    import ApplicationServices as ax
    import Quartz as quartz

    if not (ax.AXIsProcessTrusted() and quartz.CGPreflightPostEventAccess() and quartz.CGPreflightScreenCaptureAccess()):
        parser.error("The runner needs existing Accessibility, event-posting and Screen Recording access")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "candidate.json").write_text(json.dumps(qualification) + "\n")
    console = QuartzConsole()
    crashes = crash_reports()

    try:
        with serve() as server, tempfile.TemporaryDirectory(prefix=f"bark-{name}-", dir="/private/tmp") as folder:
            profile = str(uuid4()).upper()
            root = Path(folder)
            domain = "ee.qdo.nook.chromium-verification." + hashlib.sha256(os.fsencode(root)).hexdigest()
            origin = f"http://{source_host}:{server.server_port}"
            contributor["seed_profile"](root, profile, f"{origin}/source")
            if prepare_fixture:
                prepare_fixture(root, origin, app, profile)
            preferences = [*preferences, ("settings.defaultBrowserPromptDismissedAt", "-float", str(time.time()))]
            try:
                for key, kind, value in preferences:
                    subprocess.run(["defaults", "write", domain, key, kind, value], check=True)
                phases = [(exercise, "app.log")]
                if relaunch is not None:
                    phases.append((relaunch, "relaunch.log"))
                with screen_lock(SCREEN_LOCK, wait=30) as owns_screen:
                    pointer = console.pointer()
                    time.sleep(0.4)
                    for phase, log_name in phases:
                        path = output / log_name
                        require_idle_console(console, owns_screen, pointer, min_idle=10)
                        with path.open("wb") as log:
                            proc, launch_started_ns = launch_verified(
                                app, qualification["bundle_cdhash"], root, profile, log, contributor["app_output_lock"])
                            try:
                                screen = Screen(console, owns_screen, proc.pid, pointer, launch_started_ns)
                                phase(screen, proc, server.events, output)
                                pointer = screen.point
                                if proc.wait(timeout=30) != 0:
                                    raise RuntimeError("The signed candidate did not quit cleanly")
                                wait_for("Candidate processes were left behind", lambda: not processes(app))
                            finally:
                                if proc.poll() is None or processes(app):
                                    contributor["stop"](proc)
                        if crash_reports() - crashes or "FATAL:" in path.read_text(errors="replace"):
                            raise RuntimeError("The candidate wrote a fatal log or a crash report")
                        print("Quit confirmation exited cleanly and left no candidate processes", flush=True)
                        if phase is exercise and relaunch is not None:
                            time.sleep(max(0, 10 - console.idle()))
            finally:
                (output / "events.json").write_text(json.dumps(server.events, indent=2) + "\n")
                subprocess.run(["defaults", "delete", domain], capture_output=True)
    except ScreenUnavailable as failure:
        print(failure, file=sys.stderr)
        return SCREEN_UNAVAILABLE
    return 0
