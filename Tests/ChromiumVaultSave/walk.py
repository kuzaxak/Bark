#!/usr/bin/env python3
"""Check signed Bark vault UI with a loopback-only, in-memory provider."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from threading import Thread
import time
from urllib.parse import parse_qs

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import run_walk, wait_for

ACCOUNT = "synthetic-new"
PASSWORD = "disposable-new-password"
EXISTING_ACCOUNT = "synthetic-existing"
EXISTING_PASSWORD = "fixture-password"
MARKER = "Bark verification vault: "


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/source", "/new-form", "/saved-form", "/passkey"):
            self.page()
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 512:
            self.send_error(400)
            return
        data = self.rfile.read(length).decode()
        if self.path in ("/signed-in", "/existing-signed-in"):
            existing = self.path == "/existing-signed-in"
            account, password = (EXISTING_ACCOUNT, EXISTING_PASSWORD) if existing else (ACCOUNT, PASSWORD)
            matches = parse_qs(data) == {"username": [account], "password": [password]}
            event = "existing-fixture-submitted" if existing else "fixture-submitted"
            self.server.events.append(event if matches else "unmatched-submission")
            if not matches:
                self.send_error(400)
                return
            self.page()
            return
        if self.path != "/event" or data not in {
            "ready:/source", "ready:/new-form", "ready:/signed-in",
            "ready:/saved-form", "ready:/passkey", "ready:/existing-signed-in",
            "typed-fields-filled", "saved-fields-filled", "passkey-started", "passkey-cancelled",
            "passkey-created", "passkey-error",
        }:
            self.send_error(400)
            return
        self.server.events.append(data)
        self.send_response(204)
        self.end_headers()

    def page(self):
        body = self.server.html
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.html = (HERE / "fixture.html").read_bytes()
        server.events = []
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield server
        finally:
            server.shutdown()
            worker.join()


class CandidateControls:
    def __init__(self, screen, process):
        self.screen = screen
        self.process = process
        self.ax = screen.ax
        self.app = self.ax.AXUIElementCreateApplication(process.pid)

    def attribute(self, element, key):
        status, result = self.ax.AXUIElementCopyAttributeValue(element, key, None)
        return result if status == 0 else None

    def elements(self, root=None):
        windows = (root,) if root is not None else self.attribute(self.app, "AXWindows") or ()
        pending = [(window, 0) for window in windows]
        while pending:
            element, depth = pending.pop()
            yield element
            if depth < 24:
                pending.extend((child, depth + 1)
                               for child in self.attribute(element, "AXChildren") or ())

    def labels(self, element):
        keys = ("AXTitle", "AXDescription")
        if self.attribute(element, "AXRole") == "AXStaticText":
            keys += ("AXValue",)
        return tuple(value for key in keys
                     if isinstance(value := self.attribute(element, key), str))

    def find(self, label, roles, partial=False, root=None):
        for element in self.elements(root):
            if roles and self.attribute(element, "AXRole") not in roles:
                continue
            if any((label in text if partial else label == text) for text in self.labels(element)):
                return element
        return None

    def require(self, label, roles=(), *, partial=False, timeout=12, root=None):
        return wait_for(f"Missing candidate control {label}",
                        lambda: self.find(label, roles, partial, root), self.process, timeout=timeout)

    def press(self, label, *, root=None):
        self.screen.press_button(self.require(label, ("AXButton",), root=root))

    def sheet_for(self, element):
        for _ in range(12):
            if self.attribute(element, "AXRole") == "AXSheet":
                return element
            element = self.attribute(element, "AXParent")
            if element is None:
                break
        raise RuntimeError("Native Pawl consent was not in an attached sheet")

    def center(self, element):
        self.screen.guard()

        def rect_component(name, kind):
            ref = self.attribute(element, name)
            if ref is None:
                return None
            okay, value = self.ax.AXValueGetValue(ref, kind, None)
            return value if okay else None

        position = rect_component("AXPosition", self.ax.kAXValueCGPointType)
        size = rect_component("AXSize", self.ax.kAXValueCGSizeType)
        if position is None or size is None or size.width <= 0 or size.height <= 0:
            return None
        return position.x + size.width / 2, position.y + size.height / 2

    def click_point(self, point):
        bounds = self.screen.windows()[0]["kCGWindowBounds"]
        self.screen.click((point[0] - bounds["X"], point[1] - bounds["Y"]))

    def click(self, label, roles):
        element = self.require(label, roles)
        point = self.center(element)
        if point is None:
            raise RuntimeError(f"Missing visible bounds for {label}")
        self.click_point(point)

    def click_dialog_action(self, dialog_label, action_label):
        previous = None

        def settled_point():
            nonlocal previous
            dialog = self.find(dialog_label, ("AXWindow",))
            button = self.find(action_label, ("AXButton",), root=dialog) if dialog is not None else None
            if button is None or not self.attribute(button, "AXEnabled"):
                previous = None
                return None
            point = self.center(button)
            stable = point is not None and previous == (dialog, point)
            previous = (dialog, point)
            return point if stable else None

        point = wait_for(f"{action_label} did not settle in {dialog_label}",
                         settled_point, self.process)
        self.click_point(point)

    def dump(self, output):
        labels = [[self.attribute(element, "AXRole"), self.labels(element)]
                  for element in self.elements()]
        (output / "accessibility.json").write_text(json.dumps(labels, indent=2))


def exercise(screen, process, events, output):
    controls = CandidateControls(screen, process)
    log = output / "app.log"

    def seen(event, timeout=14):
        wait_for(f"Fixture did not report {event}", lambda: event in events,
                 process, timeout=timeout)

    def method(name):
        return sum(line.strip().endswith(MARKER + name)
                   for line in log.read_text(errors="replace").splitlines())

    try:
        seen("ready:/source", timeout=30)
        screen.guard()
        controls.ax.AXUIElementSetAttributeValue(controls.app, "AXEnhancedUserInterface", True)
        wait_for("Synthetic Pawl provider did not initialize",
                 lambda: method("ready"), process)
        controls.click("Fixture password", ("AXTextField", "AXSecureTextField"))
        picker = controls.require(EXISTING_ACCOUNT, ("AXButton",), partial=True)
        time.sleep(0.5)
        screen.screenshot(output / "picker.png", include_owned_windows=True)
        screen.press_button(picker)
        seen("typed-fields-filled")
        wait_for("Synthetic password provider was not called", lambda: method("password"), process)
        print("Selected the synthetic Pawl login and verified both typed Chromium fields", flush=True)

        reads_before_existing, saves_before_existing = method("password"), method("save")
        controls.click("Sign in to fixture", ("AXButton",))
        seen("existing-fixture-submitted")
        seen("ready:/existing-signed-in")
        card = "This login is already in Pawl Vault"
        controls.require(card)
        controls.require(f"{EXISTING_ACCOUNT} on localhost", partial=True)
        controls.require("Open Pawl Vault", ("AXButton",))
        if controls.find("Save password to Pawl Vault?", ()):
            raise RuntimeError("The existing login offered a new password save")
        screen.screenshot(output / "existing-login-card.png", include_owned_windows=True)
        controls.press("Not Now")
        wait_for("The existing-login card did not dismiss",
                 lambda: not controls.find(card, ()), process)
        if (method("password"), method("save")) != (reads_before_existing, saves_before_existing):
            raise RuntimeError("The existing-login submission fetched or stored a secret")
        print("Declined the existing-login card without a password fetch or save", flush=True)

        new_form = controls.require("Use a new fixture account", ("AXLink",))
        screen.press_button(new_form)
        seen("ready:/new-form")
        screen.keys["a"] = 0
        for label, value in (("Fixture account", ACCOUNT), ("Fixture password", PASSWORD)):
            controls.click(label, ("AXTextField", "AXSecureTextField"))
            screen.key("Escape")
            screen.key("a", screen.command)
            screen.key(value, unicode=True)
        controls.click("Sign in to fixture", ("AXButton",))
        seen("fixture-submitted")
        seen("ready:/signed-in")
        controls.require("Save password to Pawl Vault?")
        controls.require(f"{ACCOUNT} on localhost", partial=True)
        screen.screenshot(output / "save-card.png", include_owned_windows=True)
        controls.press("Save")
        wait_for("Synthetic password save did not reach Pawl transport",
                 lambda: method("save"), process)
        wait_for("Native save card stayed open after Save",
                 lambda: not controls.find("Save password to Pawl Vault?", ()), process)
        print("Approved the native Pawl save card for the synthetic account", flush=True)

        controls.click("Check the saved fixture account", ("AXLink",))
        seen("ready:/saved-form")
        reveals = method("password")
        controls.click("Fixture password", ("AXTextField", "AXSecureTextField"))
        saved = controls.require(ACCOUNT, ("AXButton",), partial=True)
        time.sleep(0.5)
        screen.press_button(saved)
        seen("saved-fields-filled")
        wait_for("Saved synthetic account was not fetched",
                 lambda: method("password") > reveals, process)
        print("Selected the newly saved account and verified both fields in a new document", flush=True)

        controls.click("Open the passkey fixture", ("AXLink",))
        seen("ready:/passkey")
        controls.click("Start disposable passkey", ("AXButton",))
        seen("passkey-started")
        def chooser_control():
            pawl = controls.find("Pawl Vault", ("AXButton",))
            if pawl is not None:
                return ("pawl", pawl)
            if controls.find("Passkeys & Security Keys", ()):
                back = controls.find("Back", ("AXButton",))
                if back is not None:
                    return ("back", back)
            return None

        kind, button = wait_for("No Pawl entry or Back control in the Chromium chooser",
                                chooser_control, process)
        if kind == "back":
            screen.press_button(button)
        controls.click_dialog_action("Choose where to save your passkey for localhost", "Pawl Vault")
        consent = controls.require("Create a passkey for localhost?")
        sheet = controls.sheet_for(consent)
        controls.require("Pawl Vault will save a passkey for synthetic-passkey.", root=sheet)
        screen.screenshot(output / "passkey-consent.png", include_owned_windows=True)
        controls.press("Cancel", root=sheet)
        wait_for("Native Pawl consent sheet did not close",
                 lambda: not controls.find("Create a passkey for localhost?", ()), process)
        def cancellation():
            if "passkey-cancelled" in events:
                return "page"
            if controls.find("Your identity couldn't be verified", ()):
                return "browser-dialog"
            return None

        outcome = wait_for("Passkey cancellation did not reach the browser",
                           cancellation, process, timeout=7)
        if outcome == "browser-dialog":
            controls.click_dialog_action("Something went wrong", "Cancel")
            seen("passkey-cancelled", timeout=7)
            print("Dismissed Chromium’s cancellation acknowledgement", flush=True)
        if method("register") or "passkey-created" in events:
            raise RuntimeError("Cancelled consent produced a synthetic registration")
        print("Cancelled the native Pawl passkey consent without registering", flush=True)

        if (method("password"), method("save")) != (reads_before_existing + 1, saves_before_existing + 1):
            raise RuntimeError("Only the approved new save and its readback may add vault operations")
        if "leak_detection_request" in log.read_text(errors="replace"):
            raise RuntimeError("Chromium attempted a password leak check in the disposable fixture")
        screen.key("q", screen.command)
        controls.press("Quit")
    except Exception:
        controls.dump(output)
        raise


def prepare_fixture(root, origin, app, profile):
    shell = app / "Contents/Frameworks/NookNativeShell.framework/NookNativeShell"
    code = shell.read_bytes()
    markers = ["VaultFixture.json", *(MARKER + name for name in
                                     ("ready", "password", "save", "register"))]
    if any(marker.encode() not in code for marker in markers):
        raise RuntimeError("The signed candidate has no synthetic Pawl fixture support")
    report = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(app)],
        check=True, capture_output=True,
    )
    entitlements = plistlib.loads(report.stdout) if report.stdout else {}
    if {"keychain-access-groups", "com.apple.developer.web-browser.public-key-credential"} & entitlements.keys():
        raise RuntimeError("The vault fixture requires an app without platform credential entitlements")
    (root / "VaultFixture.json").write_text(json.dumps({"origin": origin}) + "\n")
    # The synthetic submission stays on loopback. Chromium otherwise schedules
    # its own password leak check, independently of the selected save provider.
    engine_profile = root / "Engine" / f"Barc-{profile.lower()}"
    engine_profile.mkdir(parents=True)
    (engine_profile / "Preferences").write_text(json.dumps({
        "profile": {"password_manager_leak_detection": False},
    }) + "\n")


if __name__ == "__main__":
    sys.exit(run_walk(
        "Signed Pawl vault fill, existing login, save and passkey cancellation", "vault", serve, exercise,
        preferences=(("settings.pawlVaultEnabled", "-bool", "true"),),
        source_host="localhost",
        prepare_fixture=prepare_fixture,
        official_qualification=True,
    ))
