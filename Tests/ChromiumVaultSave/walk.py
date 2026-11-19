#!/usr/bin/env python3
"""Check signed Bark vault UI with a loopback-only, in-memory provider."""

from base64 import b64decode, urlsafe_b64encode
from binascii import Error as Base64Error
from contextlib import closing, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import sqlite3
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
UPDATED_PASSWORD = "disposable-replacement-password"
MARKER = "Bark verification vault: "
PUBLIC_KEY_MARKER = MARKER + "assertion public key "


def fixture_public_key(log):
    keys = set()
    for line in log.read_text(errors="replace").splitlines():
        if not line.startswith(PUBLIC_KEY_MARKER):
            continue
        encoded = line[len(PUBLIC_KEY_MARKER):]
        if len(encoded) != 87:
            raise ValueError("invalid P-256 public key encoding")
        key = b64decode(encoded + "=", altchars=b"-_", validate=True)
        if len(key) != 65 or key[0] != 4 or urlsafe_b64encode(key).decode().rstrip("=") != encoded:
            raise ValueError("invalid P-256 uncompressed public key")
        keys.add(key)
    if len(keys) != 1:
        raise ValueError("expected one fixture public key")
    return keys.pop()


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/source", "/new-form", "/saved-form", "/updated-form", "/passkey"):
            self.page()
        elif self.path == "/assertion-public-key" and self.server.assertion_log is not None:
            try:
                key = fixture_public_key(self.server.assertion_log)
            except (OSError, ValueError, Base64Error):
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(key)))
            self.end_headers()
            self.wfile.write(key)
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
            account, password = (EXISTING_ACCOUNT, UPDATED_PASSWORD) if existing else (ACCOUNT, PASSWORD)
            matches = parse_qs(data) == {"username": [account], "password": [password]}
            event = "updated-fixture-submitted" if existing else "fixture-submitted"
            self.server.events.append(event if matches else "unmatched-submission")
            if not matches:
                self.send_error(400)
                return
            self.page()
            return
        if self.path != "/event" or data not in {
            "ready:/source", "ready:/new-form", "ready:/signed-in",
            "ready:/saved-form", "ready:/updated-form", "ready:/passkey", "ready:/existing-signed-in",
            "typed-fields-filled", "saved-fields-filled", "updated-fields-filled", "passkey-started", "passkey-cancelled",
            "passkey-created", "passkey-error", "code-only-filled", "wrong-code-fill",
            "assertion-started", "assertion-verified", "assertion-error",
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
        server.assertion_log = None
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

    def rect(self, element):
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
        return position.x, position.y, size.width, size.height

    def center(self, element):
        bounds = self.rect(element)
        if bounds is None:
            return None
        x, y, width, height = bounds
        return x + width / 2, y + height / 2

    def require_card_layout(self, title, account, action):
        detail_label = f"{account} on localhost"

        def detail_above_actions():
            for window in self.attribute(self.app, "AXWindows") or ():
                if not self.find(title, (), root=window):
                    continue
                detail = self.find(detail_label, ("AXStaticText",), partial=True, root=window)
                decline = self.find("Not Now", ("AXButton",), root=window)
                accept = self.find(action, ("AXButton",), root=window)
                if detail is None or decline is None or accept is None:
                    continue
                detail_rect, decline_rect, accept_rect = map(self.rect, (detail, decline, accept))
                if (detail_rect and decline_rect and accept_rect and
                        detail_rect[1] + detail_rect[3] <= min(decline_rect[1], accept_rect[1])):
                    return True
            return False

        wait_for(f"{title}: account detail must sit above both native action buttons",
                 detail_above_actions, self.process)

    def click_point(self, point):
        bounds = self.screen.windows()[0]["kCGWindowBounds"]
        self.screen.click((point[0] - bounds["X"], point[1] - bounds["Y"]))

    def click(self, label, roles):
        element = self.require(label, roles)
        point = self.center(element)
        if point is None:
            raise RuntimeError(f"Missing visible bounds for {label}")
        self.click_point(point)

    def click_settled_button(self, label, *, dialog_label=None, partial=False):
        previous = None

        def settled_point():
            nonlocal previous
            dialog = self.find(dialog_label, ("AXWindow",)) if dialog_label else None
            if dialog_label and dialog is None:
                previous = None
                return None
            button = self.find(label, ("AXButton",), partial=partial, root=dialog)
            if button is None or not self.attribute(button, "AXEnabled"):
                previous = None
                return None
            point = self.center(button)
            stable = point is not None and previous == (dialog, point)
            previous = (dialog, point)
            return point if stable else None

        point = wait_for(f"{label} did not settle", settled_point, self.process)
        self.click_point(point)

    def dump(self, output):
        labels = [[self.attribute(element, "AXRole"), self.labels(element)]
                  for element in self.elements()]
        (output / "accessibility.json").write_text(json.dumps(labels, indent=2))


def open_password_settings(controls):
    controls.screen.keys[","] = 43
    controls.screen.key(",", controls.screen.command)
    general = controls.require("General", ("AXWindow",))
    controls.press("Privacy", root=general)
    settings = controls.require("Privacy", ("AXWindow",))
    controls.require("Connected", root=settings, partial=True)
    return settings


def open_password_settings_from_palette(controls):
    screen = controls.screen
    screen.keys["t"] = 17
    screen.key("t", screen.command)

    def editing():
        field = controls.attribute(controls.app, "AXFocusedUIElement")
        return field is not None and controls.attribute(field, "AXRole") == "AXTextField"

    wait_for("The command palette did not take focus", editing, controls.process)
    screen.key("chrome://password-manager/passwords", unicode=True)
    controls.require("Open Passwords in Bark Settings", partial=True)
    screen.key("Return")
    settings = controls.require("Privacy", ("AXWindow",))
    controls.require("Connected", root=settings)
    return settings


def close_settings(controls, settings):
    close = controls.attribute(settings, "AXCloseButton")
    if close is None:
        raise RuntimeError("Missing native Settings window close button")
    controls.screen.press_button(close)
    wait_for("Privacy settings stayed open after Close",
             lambda: not controls.find("Privacy", ("AXWindow",)), controls.process)


def require_exclusive_pawl(controls, settings, output):
    if controls.find("Pawl Vault works alongside Chromium", (), partial=True, root=settings):
        raise RuntimeError("This signed Bark uses Pawl alongside Chromium. Exclusive provider selection requires a newer SDK.")
    # The relaunch notice requires an engine-selected provider, and Connected
    # appears only when Pawl is the active provider for this session.
    controls.require("Quit and reopen Bark to change password providers.", root=settings, partial=True)
    controls.require("Connected", root=settings)
    controls.screen.screenshot(output / "pawl-provider-at-launch.png", include_owned_windows=True)
    print("Verified that the signed app selected Pawl at engine startup", flush=True)


def exercise(screen, process, events, output, *, legacy_provider, require_exclusive):
    controls = CandidateControls(screen, process)
    log = output / "app.log"

    def seen(event, timeout=14, *, occurrences=1):
        wait_for(f"Fixture did not report {event}", lambda: events.count(event) >= occurrences,
                 process, timeout=timeout)

    def method(name):
        return sum(line.strip().endswith(MARKER + name)
                   for line in log.read_text(errors="replace").splitlines())

    def writes():
        return tuple(method(name) for name in ("save", "checked create", "checked update"))

    def attempts():
        return method("save attempted"), method("checked commit attempted")

    def quit_app():
        screen.key("q", screen.command)
        controls.press("Quit")

    def decline_manual_card(card, account, screenshot, reads):
        controls.require(card)
        controls.require(f"{account} on localhost", partial=True)
        controls.require("Open Pawl Vault", ("AXButton",))
        controls.require_card_layout(card, account, "Open Pawl Vault")
        if any(controls.find(title, ()) for title in (
            "Save password to Pawl Vault?", "Update password in Pawl Vault?"
        )):
            raise RuntimeError("The legacy provider offered a password write")
        screen.screenshot(output / screenshot, include_owned_windows=True)
        controls.press("Not Now")
        wait_for("The manual management card did not dismiss",
                 lambda: not controls.find(card, ()), process)
        if method("password") != reads or any(writes()) or any(attempts()):
            raise RuntimeError("A manual-only submission fetched or attempted to write a secret")

    try:
        seen("ready:/source", timeout=30)
        screen.guard()
        controls.ax.AXUIElementSetAttributeValue(controls.app, "AXEnhancedUserInterface", True)
        wait_for("Synthetic Pawl provider did not initialize",
                 lambda: method("ready"), process)
        wait_for("The signed fixture did not report its negotiated login mode",
                 lambda: method("conditional login writes") or method("legacy login writes"),
                 process)
        expected_mode = (0, 1) if legacy_provider else (1, 0)
        if (method("conditional login writes"), method("legacy login writes")) != expected_mode:
            raise RuntimeError("The signed fixture selected the wrong login-write mode")
        if require_exclusive:
            settings = open_password_settings(controls)
            require_exclusive_pawl(controls, settings, output)
            close_settings(controls, settings)
        controls.click("Fixture password", ("AXTextField", "AXSecureTextField"))
        controls.require(EXISTING_ACCOUNT, ("AXButton",), partial=True)
        screen.key("Escape")
        wait_for("Escape did not dismiss the Pawl account picker",
                 lambda: not controls.find(EXISTING_ACCOUNT, ("AXButton",), partial=True), process)
        controls.click("Open the passkey fixture", ("AXLink",))
        seen("ready:/passkey")
        controls.press("Back")
        controls.click("Fixture password", ("AXTextField", "AXSecureTextField"))
        picker = controls.require(EXISTING_ACCOUNT, ("AXButton",), partial=True)
        if method("password") or method("code") or "typed-fields-filled" in events:
            raise RuntimeError("Pawl released a secret before the user chose an account")
        print("Dismissed the picker, left the page and returned without reading a secret", flush=True)
        time.sleep(0.5)
        screen.screenshot(output / "picker.png", include_owned_windows=True)
        screen.press_button(picker)
        seen("typed-fields-filled")
        if method("password") != 1 or method("code"):
            raise RuntimeError("The first account choice did not read exactly one password")
        print("Selected the synthetic Pawl login and verified both typed Chromium fields", flush=True)

        reads_before_existing = method("password")
        if any(writes()) or any(attempts()):
            raise RuntimeError("The fixture attempted a write before any submission")
        screen.keys["a"] = 0
        controls.click("Fixture password", ("AXSecureTextField", "AXTextField"))
        screen.key("Escape")
        screen.key("a", screen.command)
        screen.key(UPDATED_PASSWORD, unicode=True)
        controls.click("Sign in to fixture", ("AXButton",))
        seen("updated-fixture-submitted")
        seen("ready:/existing-signed-in")
        if not legacy_provider:
            card = "Update password in Pawl Vault?"
            controls.require(card)
            controls.require(f"{EXISTING_ACCOUNT} on localhost", partial=True)
            controls.require("Update", ("AXButton",))
            controls.require_card_layout(card, EXISTING_ACCOUNT, "Update")
            if controls.find("Review this login in Pawl Vault", ()) or controls.find(
                "Save password to Pawl Vault?", ()
            ):
                raise RuntimeError("Expected only the conditional update card")
            if any(writes()) or any(attempts()) or method("password") != reads_before_existing:
                raise RuntimeError("The existing-account submission fetched or wrote before approval")
            screen.screenshot(output / "update-card.png", include_owned_windows=True)
            controls.press("Update")
            wait_for("Approved update did not reach the conditional transport",
                     lambda: method("checked update") == 1, process)
            wait_for("Native update card stayed open after Update",
                     lambda: not controls.find(card, ()), process)
            if writes() != (0, 0, 1) or attempts() != (0, 1) or method("password") != reads_before_existing:
                raise RuntimeError("Updating the existing login created a record or fetched its secret")
            controls.click("Check the updated fixture account", ("AXLink",))
            seen("ready:/updated-form")
            controls.click("Fixture password", ("AXTextField", "AXSecureTextField"))
            updated = controls.require(EXISTING_ACCOUNT, ("AXButton",), partial=True)
            rows = [element for element in controls.elements()
                    if controls.attribute(element, "AXRole") == "AXButton"
                    and any(EXISTING_ACCOUNT in label for label in controls.labels(element))]
            if len(rows) != 1:
                raise RuntimeError("Expected one picker row for the updated account")
            time.sleep(0.5)
            screen.press_button(updated)
            seen("updated-fields-filled")
            wait_for("Updated synthetic account was not fetched",
                     lambda: method("password") > reads_before_existing, process)
            print("Approved the native update and verified the replacement in the existing login", flush=True)
        else:
            decline_manual_card("Review this login in Pawl Vault", EXISTING_ACCOUNT,
                                "manage-existing-card.png", reads_before_existing)

        new_form = controls.require("Use a new fixture account", ("AXLink",))
        screen.press_button(new_form)
        seen("ready:/new-form")
        for label, value in (("Fixture account", ACCOUNT), ("Fixture password", PASSWORD)):
            controls.click(label, ("AXTextField", "AXSecureTextField"))
            screen.key("Escape")
            screen.key("a", screen.command)
            screen.key(value, unicode=True)
        controls.click("Sign in to fixture", ("AXButton",))
        seen("fixture-submitted")
        seen("ready:/signed-in")
        if legacy_provider:
            decline_manual_card("Open Pawl Vault to save this login", ACCOUNT,
                                "manage-new-card.png", reads_before_existing)
            if "leak_detection_request" in log.read_text(errors="replace"):
                raise RuntimeError("Chromium attempted a password leak check in the disposable fixture")
            quit_app()
            if process.wait(timeout=20) != 0:
                raise RuntimeError("The signed legacy-provider walk did not quit cleanly")
            if method("password") != reads_before_existing or any(writes()) or any(attempts()):
                raise RuntimeError("A manual-only submission sent a delayed credential request")
            print("Both legacy cards left the submitted credentials untouched", flush=True)
            return
        controls.require("Save password to Pawl Vault?")
        controls.require(f"{ACCOUNT} on localhost", partial=True)
        controls.require_card_layout("Save password to Pawl Vault?", ACCOUNT, "Save")
        if writes() != (0, 0, 1) or attempts() != (0, 1):
            raise RuntimeError("The new login was saved before approval")
        screen.screenshot(output / "save-card.png", include_owned_windows=True)
        controls.press("Save")
        wait_for("Synthetic password save did not reach Pawl transport",
                 lambda: method("checked create") == 1, process)
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

        reads = method("password")
        controls.click("Fixture verification code", ("AXTextField",))
        code_label = f"{EXISTING_ACCOUNT} · one-time code"
        controls.require(code_label, ("AXButton",), partial=True)
        if method("code") or controls.find(ACCOUNT, ("AXButton",), partial=True):
            raise RuntimeError("Opening the code picker read a code or offered an account without one")
        # VaultPrompt ignores input during the picker's initial half second.
        time.sleep(0.5)
        screen.screenshot(output / "code-picker.png", include_owned_windows=True)
        controls.click_settled_button(code_label, partial=True)
        seen("code-only-filled")
        if method("code") != 1 or method("password") != reads:
            raise RuntimeError("Selecting the code must request exactly one code and no password")
        print("Filled only the verification code while preserving the other account’s login fields", flush=True)

        controls.click("Open the passkey fixture", ("AXLink",))
        seen("ready:/passkey", occurrences=2)
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
        controls.click_settled_button("Pawl Vault", dialog_label="Choose where to save your passkey for localhost")
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
            controls.click_settled_button("Cancel", dialog_label="Something went wrong")
            seen("passkey-cancelled", timeout=7)
            print("Dismissed Chromium’s cancellation acknowledgement", flush=True)
        if method("register") or "passkey-created" in events:
            raise RuntimeError("Cancelled consent produced a synthetic registration")
        print("Cancelled the native Pawl passkey consent without registering", flush=True)

        controls.click("Sign in with the disposable passkey", ("AXButton",))
        seen("assertion-started")
        kind, button = wait_for("No Pawl entry or Back control for the assertion",
                                chooser_control, process)
        if kind == "back":
            screen.press_button(button)
        controls.click_settled_button("Pawl Vault", dialog_label="Use a saved passkey for localhost")
        controls.require("synthetic-passkey", ("AXButton",), partial=True)
        if method("assert"):
            raise RuntimeError("The provider attempted an assertion before account selection")
        screen.screenshot(output / "passkey-assertion-picker.png", include_owned_windows=True)
        # The picker intentionally ignores input during its opening interval.
        time.sleep(0.5)
        controls.click_settled_button("synthetic-passkey", partial=True)
        result = wait_for("The loopback RP did not finish verifying the assertion",
                          lambda: next((e for e in events if e in ("assertion-verified", "assertion-error")), None),
                          process, timeout=12)
        if result != "assertion-verified" or method("assert") != 1:
            raise RuntimeError("The loopback RP did not accept exactly one Pawl assertion")
        print("The loopback RP verified the selected Pawl passkey assertion", flush=True)

        if (method("password") != reads_before_existing + 2 or
                writes() != (0, 1, 1) or attempts() != (0, 2)):
            raise RuntimeError("Unexpected password reads, creates, or updates in the disposable vault")
        if "leak_detection_request" in log.read_text(errors="replace"):
            raise RuntimeError("Chromium attempted a password leak check in the disposable fixture")

        settings = open_password_settings_from_palette(controls) if require_exclusive else open_password_settings(controls)
        manage = controls.require("Open Pawl Vault", ("AXButton",), root=settings)
        if not controls.attribute(manage, "AXEnabled"):
            raise RuntimeError("A connected vault could not be opened from Passwords settings")
        screen.screenshot(output / "pawl-settings.png", include_owned_windows=True)
        # The in-memory provider deliberately has no installed-app launcher.
        screen.press_button(manage)
        controls.require("Open Pawl Vault from Applications")
        controls.press("OK")
        print("Used the connected vault’s management action and verified its fallback in the disposable app", flush=True)
        close_settings(controls, settings)
        quit_app()
    except Exception:
        controls.dump(output)
        raise


def prepare_fixture(root, origin, app, profile, *, legacy_provider):
    shell = app / "Contents/Frameworks/NookNativeShell.framework/NookNativeShell"
    code = shell.read_bytes()
    markers = ["VaultFixture.json", *(MARKER + name for name in
                                     ("ready", "password", "save", "code", "register"))]
    if any(marker.encode() not in code for marker in markers):
        raise RuntimeError("The signed candidate has no synthetic Pawl fixture support")
    report = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(app)],
        check=True, capture_output=True,
    )
    entitlements = plistlib.loads(report.stdout) if report.stdout else {}
    if {"keychain-access-groups", "com.apple.developer.web-browser.public-key-credential"} & entitlements.keys():
        raise RuntimeError("The vault fixture requires an app without platform credential entitlements")
    mode_markers = ("conditional login writes", "legacy login writes",
                    "checked create", "checked update", "checked commit attempted", "save attempted")
    if any((MARKER + name).encode() not in code for name in mode_markers):
        raise RuntimeError("The signed candidate lacks the current vault fixture modes")
    if not legacy_provider and PUBLIC_KEY_MARKER.encode() not in code:
        raise RuntimeError("The signed candidate lacks the modal passkey assertion fixture")
    (root / "VaultFixture.json").write_text(json.dumps({
        "origin": origin, "conditionalLoginWrites": not legacy_provider,
        "modalPasskey": not legacy_provider,
    }) + "\n")
    # The synthetic submission stays on loopback. Chromium otherwise schedules
    # its own password leak check, independently of the selected save provider.
    engine_profile = root / "Engine" / f"Barc-{profile.lower()}"
    engine_profile.mkdir(parents=True)
    (engine_profile / "Preferences").write_text(json.dumps({
        "profile": {"password_manager_leak_detection": False},
    }) + "\n")
    return engine_profile


def check_chromium_stores(engine_profile, output):
    # Web Data is created by Chromium Autofill in the profile the walk used.
    # Login stores can legitimately be absent when the external provider owns them.
    engine = engine_profile.parent
    if not (engine / "Local State").is_file() or not (engine_profile / "Web Data").is_file():
        raise RuntimeError("Could not identify the Chromium profile used by the vault walk")
    counts = {}
    for name in ("Login Data", "Login Data For Account"):
        databases = sorted(engine.glob(f"*/{name}"))
        rows = 0
        for path in databases:
            if not path.resolve().is_relative_to(engine.resolve()):
                raise RuntimeError("A login store is outside the disposable Chromium directory")
            with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as db:
                rows += db.execute("SELECT COUNT(*) FROM logins").fetchone()[0]
        counts[name] = {"databases": len(databases), "login_rows": rows}
    (output / "chromium-logins.json").write_text(json.dumps(counts, indent=2) + "\n")
    if any(store["login_rows"] for store in counts.values()):
        raise RuntimeError("Chromium stored a login during the disposable Pawl walk")
    print("Verified zero saved rows in Chromium’s profile and account login stores", flush=True)


def main():
    legacy_provider = False
    require_exclusive = False
    server = None
    engine_profile = None

    @contextmanager
    def serve_candidate():
        nonlocal server
        with serve() as running:
            server = running
            yield running

    def parse_options(parser):
        nonlocal legacy_provider, require_exclusive
        parser.add_argument("--legacy-provider", action="store_true",
                            help="exercise manual login management with a legacy Pawl transport")
        parser.add_argument("--require-exclusive", action="store_true",
                            help="require Pawl to be the launch-time provider (included in --require-official)")
        options = parser.parse_args()
        legacy_provider = options.legacy_provider
        require_exclusive = options.require_exclusive or options.require_official
        return options

    def prepare(root, origin, app, profile):
        nonlocal engine_profile
        engine_profile = prepare_fixture(root, origin, app, profile, legacy_provider=legacy_provider)

    def run(screen, process, events, output):
        if not legacy_provider:
            server.assertion_log = output / "app.log"
        exercise(screen, process, events, output, legacy_provider=legacy_provider,
                 require_exclusive=require_exclusive)
        if process.wait(timeout=30) != 0:
            raise RuntimeError("Bark did not quit cleanly before the Chromium store check")
        check_chromium_stores(engine_profile, output)

    return run_walk(
        "Signed Pawl password and code fill, save, update and passkey assertion", "vault", serve_candidate, run,
        preferences=(("settings.pawlVaultEnabled", "-bool", "true"),),
        source_host="localhost",
        prepare_fixture=prepare,
        parse_options=parse_options,
        official_qualification=True,
    )


if __name__ == "__main__":
    sys.exit(main())
