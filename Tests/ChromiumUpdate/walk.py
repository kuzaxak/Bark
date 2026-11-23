#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Exercise a signed Sparkle update using two versions of a disposable Bark app."""

import argparse
import base64
import contextlib
import filecmp
import hashlib
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4
from xml.etree import ElementTree

REPO = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path[:0] = [str(REPO / folder) for folder in ("scripts", "Tests/Shared")]
import bark_release
from chromium_sdk_layout import FRAMEWORK_BINARY, file_digest
from bark_icloud_signing import PROFILE_NAME
from bark_macos_console import (
    QuartzConsole, SCREEN_LOCK, SCREEN_UNAVAILABLE, ScreenUnavailable, require_idle_console, screen_lock,
)
from loopback_server import LoopbackHTTPServer
from signed_walk import Screen, crash_reports, processes, verify_pinned_sdk, wait_for
from update_kit import (KIT_FILES, MANIFEST, VERSIONS, image_route, load_kit, mount_app, profile_workspace,
                        rehearsal_settings, write_kit)

LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Versions/Current/"
              "Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister")
SHELL_IMAGES = (Path("Contents/MacOS/Bark"),
                Path("Contents/Frameworks/NookNativeShell.framework/Versions/A/NookNativeShell"))
DRAFT = "Bark test draft"
PREPARATION_TIMEOUT = 300
QUIT_TIMEOUT = 160
PAGE = b"""<!doctype html><meta charset=utf-8><title>Bark update fixture</title>
<style>textarea { position: fixed; inset: 0; width: 100%; height: 100%; box-sizing: border-box; }</style>
<textarea aria-label="Synthetic draft"></textarea>
<script>
const draft = document.querySelector('textarea'), key = 'bark-update-draft';
draft.value = localStorage.getItem(key) || '';
function report(event) {
  fetch('/state?' + new URLSearchParams({event, draft: draft.value}));
}
let pending;
draft.addEventListener('input', () => {
  localStorage.setItem(key, draft.value);
  clearTimeout(pending);
  pending = setTimeout(() => report('saved'), 200);
});
draft.addEventListener('pointerdown', event => {
  if (event.isTrusted) report('pointer');
});
report('restored');
</script>"""


class UpdateServer(LoopbackHTTPServer):
    def __init__(self, feed, port=0):
        super().__init__(UpdateRequest, port)
        self.feed = "/" + feed
        self.origin = f"http://127.0.0.1:{self.server_port}"
        self.requests = []
        self.completed_downloads = []
        self.mode = "bad"
        self.image_route = None

    def saw(self, path, start=0):
        return any(entry.startswith(path) for entry in self.requests[start:])


class UpdateRequest(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.partition("?")[0]
        self.server.requests.append(self.path)
        if path == "/fixture":
            self.reply(PAGE, "text/html")
        elif path == "/state":
            self.reply(b"ok", "text/plain")
        elif path == self.server.feed:
            self.reply(self.server.feeds[self.server.mode], "application/xml")
        elif path == self.server.image_route:
            mode = self.server.mode
            with self.server.image.open("rb") as source:
                self.headers_for("application/x-apple-diskimage", self.server.image.stat().st_size)
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    shutil.copyfileobj(source, self.wfile)
                    self.server.completed_downloads.append(mode)
        else:
            self.send_error(404)

    def headers_for(self, kind, length):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def reply(self, data, kind):
        self.headers_for(kind, len(data))
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(data)

    def log_message(self, *_):
        pass


def app_info(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def outer_icon(app):
    name = app_info(app).get("CFBundleIconFile")
    if not name:
        return None
    relative = Path("Contents/Resources") / name
    if not (app / relative).is_file() and not relative.suffix:
        relative = relative.with_suffix(".icns")
    return relative


def verify_installed_replacement(installed, newer, expected_cdhash):
    frameworks = Path("Contents/Frameworks")
    exact_files = [
        *SHELL_IMAGES,
        Path("Contents/Info.plist"),
        frameworks / FRAMEWORK_BINARY,
    ]
    if icon := outer_icon(newer):
        exact_files.append(icon)
    for relative in exact_files:
        current, expected = installed / relative, newer / relative
        if not current.is_file() or not expected.is_file() or not filecmp.cmp(current, expected, shallow=False):
            raise RuntimeError(f"The installed update differs from v101 at {relative}")
    if bark_release.bundle_cdhash(installed) != expected_cdhash:
        raise RuntimeError("The installed update has a different CDHash from signed v101")


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def build_checkout_shell(check, derived, arch, output):
    """Build the rehearsal shell from the tracked receiver source."""
    with (output / "build.log").open("wb") as log:
        try:
            run(*check["release_shell_build_args"](derived, arch),
                stdout=log, stderr=subprocess.STDOUT)
        finally:
            unsigned = derived / "Build/Products/Release/Bark.app"
            if unsigned.is_dir():
                subprocess.run([LSREGISTER, "-u", str(unsigned)], capture_output=True)


def stage_signed_candidate(check, candidate, stage, engine, work, arch, log):
    app = stage / "Bark.app"
    run("/usr/bin/ditto", candidate, app, stdout=log, stderr=subprocess.STDOUT)
    check["verify_candidate"](app, engine, work, arch)
    source_cdhash = bark_release.bundle_cdhash(app)
    for name in (PROFILE_NAME, "embedded.mobileprovision"):
        (app / "Contents" / name).unlink(missing_ok=True)

    # The ordinary signer consumes the unsigned engine and its signing inputs.
    # The copied engine was already verified against these exact SDK payloads.
    framework = app / "Contents/Frameworks" / check["FRAMEWORK"]
    shutil.rmtree(framework)
    packaging = stage / "Bark Packaging"
    for source, destination in ((engine / check["FRAMEWORK"], framework),
                                (engine / "Bark Packaging", packaging)):
        run("/usr/bin/ditto", source, destination, stdout=log, stderr=subprocess.STDOUT)
        run("/bin/chmod", "-R", "u+w", destination, stdout=log, stderr=subprocess.STDOUT)

    run("/bin/bash", check["STAGE"], "--arch", arch, "--apply-signing-entitlements",
        packaging / "app-entitlements.plist", stdout=log, stderr=subprocess.STDOUT)
    # Sparkle is already signed in the ordinary input, and the signer replaces
    # those signatures itself while preserving Sparkle's entitlements.
    for binary in SHELL_IMAGES:
        run("/usr/bin/codesign", "--remove-signature", app / binary, stdout=log, stderr=subprocess.STDOUT)
    return source_cdhash


def versions(check, derived, engine, identity, arch, work, server, output, *, candidate_app=None, evidence=None, kit_stage=None):
    sparkle = None
    if candidate_app is None:
        products = derived / "Build/Products/Release"
        sparkle = derived / "SourcePackages/artifacts/sparkle/Sparkle/bin"
        if not (products / "Bark.app/Contents/MacOS/Bark").is_file() or not (sparkle / "sign_update").is_file():
            raise ValueError(f"Build Release/unsigned Bark with the locked packages in {derived} first.")

    bundle_uuid = uuid4()
    root = work / "Profile" if kit_stage is None else profile_workspace(bundle_uuid) / "Profile"
    profile = str(uuid4()).upper()
    if kit_stage is None:
        root.mkdir(mode=0o700)
        check["seed_profile"](root, profile, server.origin + "/fixture")
    keys = subprocess.check_output([
        "xcrun", "swift", "-e", """
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.publicKey.rawRepresentation.base64EncodedString())
print(key.rawRepresentation.base64EncodedString())
"""
    ], text=True).splitlines()
    common = rehearsal_settings(bundle_uuid, root, profile, server.origin + server.feed, keys[0])
    stage = work / "stage"
    stage.mkdir()
    unsigned = stage / "Bark.app"
    info = unsigned / "Contents/Info.plist"
    installed = work / "Applications/Bark.app"
    installed.parent.mkdir(mode=0o700)
    settings = []
    with (output / "prepare.log").open("wb") as log, tempfile.NamedTemporaryFile(mode="w", dir=work) as key:
        key.write(keys[1] + "\n")
        key.flush()
        if candidate_app is None:
            source = products / "Bark.app"
            run("/bin/bash", check["STAGE"], "--arch", arch, source, engine, products, unsigned,
                REPO / "ChromiumApp/Additions.plist", stdout=log, stderr=subprocess.STDOUT)
        else:
            evidence["source_bundle_cdhash"] = stage_signed_candidate(check, candidate_app, stage, engine,
                                                                     work, arch, log)
            source = unsigned
        base_info = info.read_bytes()
        icon = outer_icon(source)
        if icon:
            icon_bytes = (source / icon).read_bytes()
            (output / "outer-icon.json").write_text(json.dumps({
                "path": str(icon), "sha256": hashlib.sha256(icon_bytes).hexdigest(),
            }, indent=2) + "\n")

        def verify_icon(candidate):
            if icon and (outer_icon(candidate) != icon or (candidate / icon).read_bytes() != icon_bytes):
                raise RuntimeError("The candidate differs from the app target's declared icon")
        verify_icon(unsigned)
        for build, version in VERSIONS.items():
            expectation = dict(common, CFBundleShortVersionString=version, CFBundleVersion=build)
            settings.append(expectation)
            info.write_bytes(base_info)
            bark_release.configure_release(unsigned, expectation)
            signed = work / ("signed-" + build)
            run(sys.executable, "-B", REPO / "scripts/sign-bark-local.py", "--identity", identity, stage, signed,
                stdout=log, stderr=subprocess.STDOUT)
            app = signed / "stable/Bark.app"
            def verify(candidate):
                check["verify_candidate"](candidate, engine=engine, working=work,
                                          architecture=arch, release_info=expectation)
                verify_icon(candidate)
                if candidate_app is not None:
                    for binary in SHELL_IMAGES:
                        if not check["signed_mach_matches"](source / binary, candidate / binary, work, arch):
                            raise RuntimeError(f"The rehearsal shell differs from the verified source at {binary}")

            verify(app)
            if set(bark_release.HANDLER_KEYS).intersection(app_info(app)):
                raise RuntimeError("A rehearsal bundle advertises browser or document handlers.")
            distribution = work / ("distribution-" + build)
            bark_release.make_distribution(app, distribution, arch, identity, server.origin, sparkle, key.name,
                                           work, verify_staged=verify)
            if sparkle is None:
                sparkle = work / "SourcePackages/artifacts/sparkle/Sparkle/bin"
            if kit_stage is not None:
                image, = distribution.glob("*.dmg")
                shutil.move(image, kit_stage / KIT_FILES[build])
                if build == "101":
                    feed = distribution / server.feed.removeprefix("/")
                    shutil.move(feed, kit_stage / "appcast.xml")
                    write_kit(kit_stage, arch, evidence, common)
                    return
            elif build == "100":
                image, = distribution.glob("*.dmg")
                with tempfile.TemporaryDirectory(dir=work, prefix="mount-") as mount:
                    run("hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, image,
                        stdout=log, stderr=subprocess.STDOUT)
                    try:
                        run("ditto", Path(mount) / "Bark.app", installed)
                        verify(installed)
                    finally:
                        run("hdiutil", "detach", mount, stdout=log, stderr=subprocess.STDOUT)
            else:
                server.image, = distribution.glob("*.dmg")
                feed = distribution / server.feed.removeprefix("/")
                server.image_route = "/" + server.image.name
                prepare_feed(server, feed, common["SUPublicEDKey"])
                return installed, app, root, settings


def prepare_feed(server, feed, key, *, expected_info=None):
    payload = feed.read_bytes()
    enclosure = ElementTree.fromstring(payload).find("./channel/item/enclosure")
    if enclosure is None or enclosure.attrib.get("url") != server.origin + server.image_route:
        raise RuntimeError("The rehearsal enclosure must remain on its own loopback server")
    attr = f"{{{bark_release.SPARKLE}}}edSignature"
    good_signature = enclosure.attrib[attr]
    if expected_info is not None:
        with tempfile.TemporaryDirectory(dir=feed.parent, prefix="feed-") as folder:
            expected = Path(folder) / "appcast.xml"
            bark_release.write_appcast(expected, expected_info, server.origin + server.image_route,
                                       server.image.stat().st_size, good_signature)
            if payload != expected.read_bytes():
                raise ValueError("The appcast is not the exact loopback feed for this replacement disk image.")
        run("xcrun", "swift", REPO / "scripts/VerifyBarkUpdate.swift", server.image, key, good_signature,
            capture_output=True)
    signature = bytearray(base64.b64decode(good_signature, validate=True))
    if len(signature) != 64:
        raise RuntimeError("Unexpected Ed25519 signature length")
    signature[0] ^= 1
    wrong_signature = base64.b64encode(signature)
    wrong = subprocess.run(["xcrun", "swift", str(REPO / "scripts/VerifyBarkUpdate.swift"), str(server.image),
                            key, wrong_signature.decode()], capture_output=True)
    if wrong.returncode != 1 or b"Update signature does not match" not in wrong.stderr:
        raise RuntimeError("Package verifier did not reject the changed signature")
    server.feeds = {"bad": payload.replace(good_signature.encode(), wrong_signature), "valid": payload}


def preparation_handoff_seen(status, extraction_seen):
    """Read the pinned Sparkle driver's transition out of update preparation."""
    # Sparkle can offer a ready control or close its status controller when it
    # dispatches the Cocoa quit event. The disappearance matters only after we
    # observed that update's extraction, and is never itself proof of exit.
    return (any(status["controls"].values()) or "Installing update…" in status["dialog_text"]
            or (extraction_seen and not status["installer_visible"]))


def desktop_wait(description, predicate, console, owns, *, process=None, timeout):
    try:
        return wait_for(description, predicate, process, timeout=timeout)
    except RuntimeError:
        if (process is None or process.poll() is None) and not (
                owns() and console.available() and console.idle() >= 10):
            raise ScreenUnavailable(f"{description}: the Mac was locked or in use") from None
        raise


def exercise(check, installed, newer, root, versions, arch, server, output, *, engine, replacement_cdhash):
    import ApplicationServices as ax
    import Quartz
    from AppKit import NSRunningApplication, NSWorkspace

    old, new = versions
    binary = installed / "Contents/MacOS/Bark"
    bundle_id = old["CFBundleIdentifier"]
    console = QuartzConsole()
    crashes = crash_reports()
    root_digest = hashlib.sha256(os.fsencode(root)).hexdigest()
    domain = "ee.qdo.nook.chromium-verification." + root_digest
    lines = []
    handoff = []

    def record(message):
        lines.append(message)
        print(message, flush=True)

    def installed_app():
        for app in NSRunningApplication.runningApplicationsWithBundleIdentifier_(bundle_id):
            url = app.bundleURL()
            if url and Path(url.path()).resolve() == installed:
                return app
        return None

    def value(element, attribute):
        status, value = ax.AXUIElementCopyAttributeValue(element, attribute, None)
        return value if status == 0 else None

    def accessibility_nodes(roots, max_depth=24):
        pending = [(root, 0) for root in roots]
        while pending:
            node, depth = pending.pop()
            yield node
            if depth < max_depth:
                pending.extend((child, depth + 1) for child in value(node, "AXChildren") or [])

    def find(roots, role, *names):
        for node in accessibility_nodes(roots):
            if value(node, "AXRole") == role and any(
                value(node, field) in names for field in ("AXTitle", "AXDescription", "AXValue", "AXIdentifier")
            ):
                return node
        return None

    def press(element):
        if ax.AXUIElementPerformAction(element, "AXPress") != 0:
            raise RuntimeError("The installed app did not accept its accessibility action")

    def state(event, draft, start=0):
        for request in server.requests[start:]:
            url = urlsplit(request)
            if url.path == "/state" and parse_qs(url.query, keep_blank_values=True) == {
                "event": [event], "draft": [draft]
            }:
                return True
        return False

    if not (ax.AXIsProcessTrusted() and Quartz.CGPreflightPostEventAccess()):
        raise ValueError("Use a Python interpreter with Accessibility and event-posting access.")
    if installed_app() or processes(installed):
        raise ValueError("The disposable app is already running.")
    run("/usr/bin/defaults", "write", domain, "settings.defaultBrowserPromptDismissedAt", "-float", str(time.time()))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with screen_lock(SCREEN_LOCK, wait=30) as owns, (output / "app.log").open("wb") as log:
            desktop_wait("The shared console did not become idle for rehearsal launch",
                         lambda: owns() and console.available() and console.idle() >= 10, console, owns, timeout=90)
            point = console.pointer()
            time.sleep(.4)
            require_idle_console(console, owns, point, 10)
            refusal = subprocess.run([str(binary), f"--barc-app-data-dir={root}", f"--barc-app-profile={uuid4()}"],
                                     capture_output=True, timeout=12)
            if refusal.returncode != 1 or b"Native Chromium startup refused" not in refusal.stderr or server.requests:
                raise RuntimeError("Signed app did not reject a conflicting profile before launch.")
            record("Signed startup refused a conflicting profile override")
            require_idle_console(console, owns, point, 10)
            proc = subprocess.Popen([str(binary)], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            app = ax.AXUIElementCreateApplication(proc.pid)
            def windows():
                return value(app, "AXWindows") or []

            def idle_target(pid):
                current = installed_app()
                if not (current and current.processIdentifier() == pid and owns()
                        and console.available() and console.idle() >= 10):
                    return None
                pointer = console.pointer()
                candidate = Screen(console, owns, pid, pointer, time.monotonic_ns())
                try:
                    require_idle_console(console, owns, pointer, 10)
                    candidate.guard()
                except (ScreenUnavailable, RuntimeError):
                    return None
                return candidate

            def press_control(pid, selector, description, timeout):
                def action():
                    element = selector()
                    if element is not None and value(element, "AXEnabled") and idle_target(pid):
                        press(element)
                        return True
                    return False

                desktop_wait(description, action, console, owns, timeout=timeout)

            def check_updates():
                def menu_item():
                    menu = value(app, "AXMenuBar")
                    return find([menu], "AXMenuItem", "Check for Updates…") if menu is not None else None

                press_control(proc.pid, menu_item, "Check for Updates did not become available", 90)

            def approve_download():
                press_control(proc.pid, lambda: find(windows(), "AXButton", "Install Update"),
                              "The update prompt was not actionable on an idle console", 90)

            try:
                wait_for("Initial signed app did not restore its temporary profile",
                         lambda: state("restored", ""), proc, timeout=40)
                if server.saw(server.feed):
                    raise RuntimeError("The fresh rehearsal app performed an automatic update check")
                screen = desktop_wait("No frontmost app on an idle console for draft input",
                                      lambda: idle_target(proc.pid), console, owns, process=proc, timeout=90)
                window = wait_for("No native app window for text input", lambda: screen.windows() or None, proc)[0]
                bounds = window["kCGWindowBounds"]
                require_idle_console(console, owns, screen.point, 10)
                screen.click((round(bounds["Width"] * .67), round(bounds["Height"] * .60)))
                wait_for("The draft did not receive physical pointer input", lambda: state("pointer", ""), proc)
                screen.key(DRAFT, unicode=True)
                wait_for("The draft was not saved through the page UI", lambda: state("saved", DRAFT), proc)
                record("Installed v100 from its signed DMG and saved a draft through page UI")
                check_updates()
                approve_download()
                archive_path = server.image_route
                wait_for("Sparkle did not request the archive with changed signature",
                         lambda: server.saw(archive_path), proc, timeout=60)
                wait_for("Sparkle did not show an update error after the invalid signature",
                         lambda: find(windows(), "AXStaticText", "Update Error!"), proc, timeout=120)
                if app_info(installed)["CFBundleVersion"] != "100" or proc.poll() is not None:
                    raise RuntimeError("The invalid signature changed or stopped the installed app")
                press_control(proc.pid, lambda: find(windows(), "AXButton", "Cancel Update"),
                              "Could not dismiss the rejected update on an idle console", 90)
                record("Sparkle rejected the changed signature and left v100 running")

                start = len(server.requests)
                server.mode = "valid"
                check_updates()
                approve_download()
                wait_for("Sparkle did not download the valid archive",
                         lambda: "valid" in server.completed_downloads, proc, timeout=60)

                handoff_started = time.monotonic()
                next_sample = handoff_started
                confirmations = set()

                def note_handoff(event, **details):
                    handoff.append({"elapsed_s": round(time.monotonic() - handoff_started, 2),
                                    "event": event, **details})

                extraction_seen = False

                def observe_handoff(*, preparing):
                    nonlocal next_sample, extraction_seen
                    if proc.poll() is not None:
                        return True
                    now = time.monotonic()
                    if now < next_sample:
                        return False
                    next_sample = now + .75
                    roots = windows()
                    available = [
                        ("Install and Relaunch", find(roots, "AXButton", "SUStatusInstallAndRelaunch", "Install and Relaunch")),
                        ("Quit", find(roots, "AXButton", "Quit")),
                    ]
                    enabled = [name for name, button in available if button is not None and value(button, "AXEnabled")]
                    front = NSWorkspace.sharedWorkspace().frontmostApplication()
                    dialogs = [window for window in roots if value(window, "AXTitle") != "Bark update fixture"]
                    texts = []
                    for node in accessibility_nodes(dialogs, max_depth=6):
                        if value(node, "AXRole") == "AXStaticText":
                            if text := value(node, "AXValue") or value(node, "AXTitle"):
                                texts.append(str(text))
                                if len(texts) == 12:
                                    break
                    status = {
                        "windows": [str(value(window, "AXTitle") or "") for window in roots],
                        "dialog_text": texts,
                        "installer_visible": any(value(window, "AXIdentifier") == "SUStatus" for window in roots),
                        "controls": {name: name in enabled for name, button in available if button is not None},
                        "screen_owned": owns(),
                        "console_available": console.available(),
                        "console_idle": console.idle() >= 10,
                        "candidate_frontmost": front is not None and front.processIdentifier() == proc.pid,
                    }
                    if not handoff or handoff[-1].get("status") != status:
                        note_handoff("observation", status=status)
                    if "Update Error!" in texts:
                        raise RuntimeError("Sparkle reported an error for the valid update")
                    if preparing:
                        extraction_seen |= "Extracting update…" in texts
                        return preparation_handoff_seen(status, extraction_seen)
                    # Sparkle owns extraction and relaunch. Only confirm an
                    # offered action on the idle, frontmost candidate.
                    for name, button in available:
                        if name in enabled and name not in confirmations and idle_target(proc.pid):
                            press(button)
                            confirmations.add(name)
                            note_handoff("confirmed", control=name)
                            break
                    return False

                phase = "preparation"
                note_handoff("valid-archive-served", original_pid=proc.pid)
                try:
                    wait_for("Sparkle stalled during signature verification, extraction, or Gatekeeper preparation",
                             lambda: observe_handoff(preparing=True), timeout=PREPARATION_TIMEOUT)
                    note_handoff("preparation-completed", original_status=proc.poll())
                    phase = "quit"
                    next_sample = time.monotonic()
                    wait_for("The installed app did not exit for Sparkle",
                             lambda: observe_handoff(preparing=False), timeout=QUIT_TIMEOUT)
                    note_handoff("original-exit", status=proc.returncode)
                except RuntimeError:
                    installed_version = None
                    with contextlib.suppress(OSError, plistlib.InvalidFileException):
                        installed_version = app_info(installed).get("CFBundleVersion")
                    note_handoff("failed-before-cleanup", phase=phase, original_status=proc.poll(),
                                 installed_version=installed_version)
                    raise
                if proc.returncode != 0:
                    raise RuntimeError(f"Original Bark exited with {proc.returncode}")
                relaunch = wait_for("Sparkle did not relaunch the installed path", installed_app, timeout=80)
                new_pid = int(relaunch.processIdentifier())
                if new_pid == proc.pid:
                    raise RuntimeError("Sparkle did not replace the original app process")
                executable = relaunch.executableURL()
                if not executable or Path(executable.path()).resolve() != binary.resolve():
                    raise RuntimeError("Sparkle did not launch the installed Bark executable")
                wait_for("Updated app lost the saved draft", lambda: state("restored", DRAFT, start), timeout=45)
                final = app_info(installed)
                if any(final.get(key) != val for key, val in new.items()):
                    raise RuntimeError("The installed and relaunched app is not the sealed new version")
                check["verify_candidate"](installed, engine, root.parent, arch, release_info=new)
                verify_installed_replacement(installed, newer, replacement_cdhash)
                record("Sparkle installed the exact signed v101 with the pinned SDK, relaunched it at the same path "
                       "and restored the draft")

                app = ax.AXUIElementCreateApplication(new_pid)
                final_screen = desktop_wait("The updated app is not frontmost on an idle console",
                                            lambda: idle_target(new_pid), console, owns, timeout=90)
                final_screen.key("q", final_screen.command)
                press_control(new_pid, lambda: find(windows(), "AXButton", "Quit"),
                              "Updated Bark did not offer its quit confirmation on an idle console", 90)
                wait_for("Updated app did not quit", lambda: not installed_app() and not processes(installed), timeout=30)
            finally:
                if proc.poll() is None:
                    check["stop"](proc)
                if current := installed_app():
                    current.forceTerminate()
                    wait_for("Disposable updater app did not exit",
                             lambda: not installed_app() and not processes(installed), timeout=15)
    finally:
        server.shutdown()
        thread.join()
        (output / "walk.json").write_text(json.dumps(
            {"results": lines, "requests": server.requests, "bundle_id": bundle_id,
             "sparkle_handoff": handoff}, indent=2
        ) + "\n")
        subprocess.run([LSREGISTER, "-u", str(installed)], capture_output=True)
        for preference in (domain, "ee.qdo.nook.chromium-verification.aiProvider." + root_digest, bundle_id):
            subprocess.run(["/usr/bin/defaults", "delete", preference], capture_output=True)
        cache = Path.home() / "Library/Caches" / bundle_id
        if cache.is_dir() and not cache.is_symlink():
            shutil.rmtree(cache)
    if crash_reports() - crashes or "FATAL:" in (output / "app.log").read_text(errors="replace"):
        raise RuntimeError("The candidate logged a fatal error or a crash report")


def verify_ordinary_source(check, app, engine, work, arch):
    info = app_info(app)
    if info.get("CFBundleIdentifier") != "ee.qdo.bark" or "BarkUpdateRehearsal" in info:
        raise ValueError("Use the non-rehearsal signed Bark.app as the ordinary source.")
    requirement = bark_release.distribution_requirement(app, "ee.qdo.bark")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R",
        requirement + ' and identifier "ee.qdo.bark"', app)
    check["verify_candidate"](app, engine, work, arch)
    return bark_release.bundle_cdhash(app)


def prepare_kit(check, args, engine, qualification, arch):
    candidate = args.candidate_app.resolve(strict=True)
    kit = args.prepare_kit.parent.resolve() / args.prepare_kit.name
    kit.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(kit):
        raise ValueError("Choose a new destination for the rehearsal kit.")
    with tempfile.TemporaryDirectory(prefix=".bark-update-kit-", dir=kit.parent) as directory, \
         tempfile.TemporaryDirectory(prefix="bark-update-build-", dir="/private/tmp") as scratch, \
         UpdateServer(bark_release.feed_name(arch)) as server:
        work = Path(scratch)
        stage = Path(directory) / "kit"
        stage.mkdir(mode=0o700)
        source_hash = verify_ordinary_source(check, candidate, engine, work, arch)
        versions(check, None, engine, args.identity, arch, work, server, args.output or work,
                 candidate_app=candidate, evidence=qualification, kit_stage=stage)
        requirement = bark_release.distribution_requirement(candidate, "ee.qdo.bark")
        for name in KIT_FILES.values():
            run("/usr/bin/codesign", "--verify", "--strict", "-R", requirement, stage / name)
        if qualification["source_bundle_cdhash"] != source_hash:
            raise ValueError("The ordinary source app changed during kit preparation.")
        load_kit(stage, arch, qualification["sdk_pin"], source_hash)
        bark_release.publish_new(stage, kit)
    print(f"Prepared a portable {arch} update kit at {kit}.", flush=True)


def verify_kit_app(check, app, source, engine, work, arch, settings, requirement):
    info = app_info(app)
    if (any(info.get(key) != value for key, value in settings.items())
            or set(bark_release.HANDLER_KEYS).intersection(info)
            or any(os.path.lexists(app / "Contents" / name) for name in
                   (PROFILE_NAME, "embedded.mobileprovision"))):
        raise ValueError("The disk image app does not match the sealed disposable rehearsal.")
    app_requirement = requirement + f' and identifier "{settings["CFBundleIdentifier"]}"'
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", app_requirement, app)
    check["verify_candidate"](app, engine, work, arch, release_info=settings)
    for binary in SHELL_IMAGES:
        if not check["signed_mach_matches"](source / binary, app / binary, work, arch):
            raise ValueError(f"The kit shell differs from its verified ordinary source at {binary}.")


def copy_kit_app(app, destination, requirement):
    image_hash = bark_release.bundle_cdhash(app)
    run("/usr/bin/ditto", app, destination)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, destination)
    if bark_release.bundle_cdhash(destination) != image_hash:
        raise ValueError(f"The copied rehearsal app differs from its signed disk image: {destination}")
    return image_hash


def run_kit(check, args, engine, qualification, arch, work, output):
    source = args.candidate_app.resolve(strict=True)
    source_hash = verify_ordinary_source(check, source, engine, work, arch)
    kit = args.kit.resolve(strict=True)
    # Copy validated regular names into private scratch, then validate the
    # snapshot again. Mounts and downloads use only the verified snapshot.
    load_kit(kit, arch, qualification["sdk_pin"], source_hash)
    snapshot = work / "kit"
    snapshot.mkdir()
    for name in (MANIFEST, *KIT_FILES.values(), "appcast.xml"):
        run("/bin/cp", "-cP", kit / name, snapshot / name)
    common, root, port = load_kit(snapshot, arch, qualification["sdk_pin"], source_hash)
    installed = work / "Applications/Bark.app"
    installed.parent.mkdir()
    original, replacement = (snapshot / KIT_FILES[build] for build in VERSIONS)
    requirement = bark_release.distribution_requirement(source, "ee.qdo.bark")
    for image in original, replacement:
        run("/usr/bin/codesign", "--verify", "--strict", "-R", requirement, image)
    settings = [dict(common, CFBundleShortVersionString=version, CFBundleVersion=build)
                for build, version in VERSIONS.items()]
    with UpdateServer(bark_release.feed_name(arch), port) as server:
        server.image, server.image_route = replacement, image_route(arch)
        feed = snapshot / "appcast.xml"
        prepare_feed(server, feed, common["SUPublicEDKey"], expected_info={
            **settings[1], "LSMinimumSystemVersion": app_info(source)["LSMinimumSystemVersion"],
        })
        with mount_app(original, work, run) as original_app:
            verify_kit_app(check, original_app, source, engine, work, arch, settings[0], requirement)
            original_hash = copy_kit_app(original_app, installed, requirement)
        newer = work / "reference/Bark.app"
        newer.parent.mkdir()
        with mount_app(replacement, work, run) as replacement_app:
            verify_kit_app(check, replacement_app, source, engine, work, arch, settings[1], requirement)
            replacement_hash = copy_kit_app(replacement_app, newer, requirement)
        if original_hash == replacement_hash:
            raise ValueError("The installed original and replacement must be distinct builds.")
        if source_hash != bark_release.bundle_cdhash(source):
            raise ValueError("The ordinary source app changed during verification.")
        print(f"Verified the installed build 100 and reference build 101 from the signed {arch} disk images.",
              flush=True)
        qualification.update(shell_source="signed-candidate", source_bundle_cdhash=source_hash,
                             original_bundle_cdhash=original_hash, replacement_bundle_cdhash=replacement_hash,
                             rehearsal_kit=file_digest(snapshot / MANIFEST))
        with disposable_kit_profile(root, common["CFBundleIdentifier"]):
            root.mkdir(mode=0o700)
            check["seed_profile"](root, common["BarkUpdateRehearsal"]["Profile"], server.origin + "/fixture")
            exercise(check, installed, newer, root, settings, arch, server, output, engine=engine,
                     replacement_cdhash=replacement_hash)
        (output / "candidate.json").write_text(json.dumps(qualification) + "\n")


@contextlib.contextmanager
def disposable_kit_profile(root, bundle_id):
    # mkdir is exclusive, including when a previous attempt left a symlink.
    root.parent.mkdir(mode=0o700)
    try:
        root_digest = hashlib.sha256(os.fsencode(root)).hexdigest()
        domains = (bundle_id, "ee.qdo.nook.chromium-verification." + root_digest,
                   "ee.qdo.nook.chromium-verification.aiProvider." + root_digest)
        if os.path.lexists(Path.home() / "Library/Caches" / bundle_id) or any(
            subprocess.run(["/usr/bin/defaults", "read", domain], capture_output=True).returncode == 0
            for domain in domains
        ):
            raise ValueError("A previous rehearsal left defaults or cache state for this kit.")
        yield
    finally:
        shutil.rmtree(root.parent)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--candidate-app", type=Path,
                        help="Rehearse with the shell and resources of this signed pinned Bark.app")
    source.add_argument("--derived-data", type=Path,
                        help="Reuse existing unsigned Release Bark products (developer only)")
    parser.add_argument("--identity", default=os.environ.get("BARK_SIGN_IDENTITY"), help="Local Developer ID Application")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare-kit", type=Path, help="Sign and export a new portable rehearsal kit without launching")
    mode.add_argument("--kit", type=Path, help="Run a transferred rehearsal kit without signing or building")
    parser.add_argument("--arch", choices=("x86_64", "arm64"), help="Target CPU for kit preparation")
    parser.add_argument("--engine", type=Path, help="Explicit pinned SDK directory for kit preparation")
    parser.add_argument("--output", type=Path, help="New evidence-only directory")
    parser.add_argument("--require-official", action="store_true", help="verify the official SDK for the selected architecture")
    args = parser.parse_args(argv)
    if args.require_official and args.derived_data is not None:
        parser.error("--require-official does not accept unsigned products. Omit --derived-data.")
    if (args.prepare_kit or args.kit) and args.candidate_app is None:
        parser.error("A portable kit requires the exact ordinary --candidate-app.")
    if args.engine and (not args.prepare_kit or not args.engine.is_dir()):
        parser.error("--engine requires an existing SDK directory and --prepare-kit.")
    if args.arch and not args.prepare_kit:
        parser.error("--arch is only available with --prepare-kit. Execution uses the native CPU.")
    if not args.prepare_kit and args.output is None:
        parser.error("--output is required when running a rehearsal.")
    if args.output is not None:
        args.output = args.output.resolve()
    destination = args.prepare_kit or args.output
    if args.kit and args.output.is_relative_to(args.kit.resolve()):
        parser.error("Keep the evidence directory outside the transferred kit.")
    if not args.kit and not args.identity:
        parser.error("Pass --identity or set BARK_SIGN_IDENTITY.")
    for target in (destination, args.output):
        if target is not None and (target.resolve().is_relative_to(REPO)
                                   or (args.candidate_app and
                                       target.resolve().is_relative_to(args.candidate_app.resolve()))):
            parser.error("Choose a new destination outside the repository and source app.")
    return parser, args


def main():
    parser, args = parse_args()
    output = args.output
    check = runpy.run_path(str(REPO / "scripts/bark-check.py"))
    arch = args.arch or check["native_architecture"]()
    try:
        engine, qualification = verify_pinned_sdk(check, arch, require_official=args.require_official,
                                                  engine_directory=args.engine)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    if output is not None:
        output.mkdir(parents=True)
    if args.prepare_kit:
        prepare_kit(check, args, engine, qualification, arch)
        return
    with tempfile.TemporaryDirectory(prefix="bark-update-", dir="/private/tmp") as directory:
        work = Path(directory)
        if args.kit:
            run_kit(check, args, engine, qualification, arch, work, output)
            print("Installed update rehearsal passed.", flush=True)
            return
        if args.candidate_app is not None:
            derived = None
        elif args.derived_data is None:
            derived = work / "DerivedData"
            build_checkout_shell(check, derived, arch, output)
        else:
            derived = args.derived_data.resolve()
        with UpdateServer(bark_release.feed_name(arch)) as server:
            source_options = {}
            if args.candidate_app is not None:
                qualification["shell_source"] = "signed-candidate"
                source_options = {"candidate_app": args.candidate_app.resolve(strict=True), "evidence": qualification}
            else:
                qualification["shell_source"] = "checkout" if args.derived_data is None else "external-derived-data"
            installed, newer, root, settings = versions(check, derived, engine, args.identity,
                                                         arch, work, server, output, **source_options)
            replacement_cdhash = bark_release.bundle_cdhash(newer)
            qualification.update(
                original_bundle_cdhash=bark_release.bundle_cdhash(installed),
                replacement_bundle_cdhash=replacement_cdhash,
            )
            (output / "candidate.json").write_text(json.dumps(qualification) + "\n")
            exercise(check, installed, newer, root, settings, arch, server, output, engine=engine,
                     replacement_cdhash=replacement_cdhash)
    print("Installed update rehearsal passed.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except ScreenUnavailable as failure:
        print(failure, file=sys.stderr)
        sys.exit(SCREEN_UNAVAILABLE)
