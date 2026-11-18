#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Exercise a signed Sparkle update using two versions of a disposable Bark app."""

import argparse
import base64
import contextlib
import filecmp
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
sys.path[:0] = [str(REPO / folder) for folder in ("scripts", "Runtime/Chromium", "Tests/Shared")]
import bark_release
from run_browser_tests import (
    QuartzConsole, SCREEN_LOCK, SCREEN_UNAVAILABLE, TEST_FRAMEWORK, ScreenUnavailable, require_idle_console, screen_lock,
)
from signed_walk import Screen, crash_reports, processes, verify_official_sdk, wait_for

LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Versions/Current/"
              "Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister")
DRAFT = "Bark test draft"
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


class UpdateServer(ThreadingHTTPServer):
    def __init__(self, feed):
        super().__init__(("127.0.0.1", 0), UpdateRequest)
        self.feed = "/" + feed
        self.origin = f"http://127.0.0.1:{self.server_port}"
        self.requests = []
        self.mode = "bad"

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
        elif path == "/" + self.server.image.name:
            with self.server.image.open("rb") as source:
                self.headers_for("application/x-apple-diskimage", self.server.image.stat().st_size)
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    shutil.copyfileobj(source, self.wfile)
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


def verify_installed_replacement(installed, newer):
    frameworks = Path("Contents/Frameworks")
    exact_files = [
        Path("Contents/MacOS/Bark"),
        Path("Contents/Info.plist"),
        frameworks / "NookNativeShell.framework/Versions/A/NookNativeShell",
        frameworks / TEST_FRAMEWORK,
    ]
    if icon := outer_icon(newer):
        exact_files.append(icon)
    for relative in exact_files:
        current, expected = installed / relative, newer / relative
        if not current.is_file() or not expected.is_file() or not filecmp.cmp(current, expected, shallow=False):
            raise RuntimeError(f"The installed update differs from v101 at {relative}")


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def versions(check, derived, engine, identity, arch, work, server, output):
    products = derived / "Build/Products/Release"
    sparkle = derived / "SourcePackages/artifacts/sparkle/Sparkle/bin"
    if not (products / "Bark.app/Contents/MacOS/Bark").is_file() or not (sparkle / "sign_update").is_file():
        raise ValueError(f"Build Release/unsigned NookNativeShell with the locked packages in {derived} first.")

    root = work / "Profile"
    root.mkdir(mode=0o700)
    profile = str(uuid4()).upper()
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
    common = {
        # Chromium app shims append a 70-byte suffix to this bundle ID.
        "CFBundleIdentifier": f"ee.qdo.bark.test.{uuid4()}",
        "BarkUpdateRehearsal": {"DataRoot": str(root), "Profile": profile},
        "SUFeedURL": server.origin + server.feed,
        "SUPublicEDKey": keys[0],
        "SUVerifyUpdateBeforeExtraction": True,
        "SUEnableAutomaticChecks": False,
    }
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
        run("/bin/bash", check["STAGE"], "--arch", arch, products / "Bark.app", engine, products, unsigned,
            REPO / "ChromiumApp/Additions.plist", stdout=log, stderr=subprocess.STDOUT)
        base_info = info.read_bytes()
        source = products / "Bark.app"
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
        for version, build in (("1.0.0", "100"), ("1.0.1", "101")):
            expectation = dict(common, CFBundleShortVersionString=version, CFBundleVersion=build)
            settings.append(expectation)
            info.write_bytes(base_info)
            bark_release.configure_release(unsigned, expectation)
            signed = work / ("signed-" + build)
            run(sys.executable, REPO / "scripts/sign-bark-local.py", "--identity", identity, stage, signed,
                stdout=log, stderr=subprocess.STDOUT)
            app = signed / "stable/Bark.app"
            def verify(candidate):
                check["verify_candidate"](candidate, engine=engine, working=work,
                                          architecture=arch, release_info=expectation)
                verify_icon(candidate)

            verify(app)
            if set(bark_release.HANDLER_KEYS).intersection(app_info(app)):
                raise RuntimeError("A rehearsal bundle advertises browser or document handlers.")
            distribution = work / ("distribution-" + build)
            bark_release.make_distribution(app, distribution, arch, identity, server.origin, sparkle, key.name,
                                           work, verify_staged=verify)
            if build == "100":
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
                prepare_feed(server, feed, common["SUPublicEDKey"])
                return installed, app, root, settings


def prepare_feed(server, feed, key):
    payload = feed.read_bytes()
    enclosure = ElementTree.fromstring(payload).find("./channel/item/enclosure")
    if enclosure is None or enclosure.attrib.get("url") != server.origin + "/" + server.image.name:
        raise RuntimeError("The rehearsal enclosure must remain on its own loopback server")
    attr = f"{{{bark_release.SPARKLE}}}edSignature"
    good_signature = enclosure.attrib[attr]
    signature = bytearray(base64.b64decode(good_signature, validate=True))
    if len(signature) != 64:
        raise RuntimeError("Unexpected Ed25519 signature length")
    signature[0] ^= 1
    wrong_signature = base64.b64encode(signature)
    wrong = subprocess.run(["xcrun", "swift", str(REPO / "scripts/VerifyBarkUpdate.swift"), str(server.image),
                            key, wrong_signature.decode()], capture_output=True, timeout=30)
    if wrong.returncode != 1 or b"Update signature does not match" not in wrong.stderr:
        raise RuntimeError("Package verifier did not reject the changed signature")
    server.feeds = {"bad": payload.replace(good_signature.encode(), wrong_signature), "valid": payload}


def exercise(check, installed, newer, root, versions, arch, server, output, *, engine):
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
            wait_for("The shared console did not become idle for rehearsal launch",
                     lambda: owns() and console.available() and console.idle() >= 10, timeout=90)
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

                wait_for(description, action, timeout=timeout)

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
                screen = wait_for("No frontmost app on an idle console for draft input",
                                  lambda: idle_target(proc.pid), proc, timeout=90)
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
                archive_path = "/" + server.image.name
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
                         lambda: server.saw(archive_path, start), proc, timeout=60)

                handoff_started = time.monotonic()
                next_sample = handoff_started
                confirmations = set()

                def note_handoff(event, **details):
                    handoff.append({"elapsed_s": round(time.monotonic() - handoff_started, 2),
                                    "event": event, **details})

                def quit_for_install():
                    nonlocal next_sample
                    if proc.poll() is not None:
                        note_handoff("original-exit", status=proc.returncode)
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
                        "controls": {name: name in enabled for name, button in available if button is not None},
                        "screen_owned": owns(),
                        "console_available": console.available(),
                        "console_idle": console.idle() >= 10,
                        "candidate_frontmost": front is not None and front.processIdentifier() == proc.pid,
                    }
                    if not handoff or handoff[-1].get("status") != status:
                        note_handoff("observation", status=status)
                    # Sparkle owns extraction and relaunch. Only confirm an
                    # offered action on the idle, frontmost candidate.
                    for name, button in available:
                        if name in enabled and name not in confirmations and idle_target(proc.pid):
                            press(button)
                            confirmations.add(name)
                            note_handoff("confirmed", control=name)
                            break
                    return False

                note_handoff("valid-archive-requested", original_pid=proc.pid)
                try:
                    wait_for("The installed app did not exit for Sparkle", quit_for_install, timeout=160)
                except RuntimeError:
                    installed_version = None
                    with contextlib.suppress(OSError, plistlib.InvalidFileException):
                        installed_version = app_info(installed).get("CFBundleVersion")
                    note_handoff("failed-before-cleanup", original_status=proc.poll(),
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
                verify_installed_replacement(installed, newer)
                check["verify_candidate"](installed, engine, root.parent, arch, release_info=new)
                record("Sparkle installed the exact signed v101 with the pinned SDK, relaunched it at the same path "
                       "and restored the draft")

                app = ax.AXUIElementCreateApplication(new_pid)
                final_screen = wait_for("The updated app is not frontmost on an idle console",
                                        lambda: idle_target(new_pid), timeout=90)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True, help="Unsigned Release NookNativeShell build")
    parser.add_argument("--identity", default=os.environ.get("BARK_SIGN_IDENTITY"), help="Local Developer ID Application")
    parser.add_argument("--output", type=Path, required=True, help="New evidence-only directory")
    parser.add_argument("--require-official", action="store_true", help="verify the native official SDK before preparation")
    args = parser.parse_args()
    if not args.identity:
        parser.error("Pass --identity or set BARK_SIGN_IDENTITY.")
    output = args.output.resolve()
    if output.is_relative_to(REPO):
        parser.error("Choose a new evidence directory outside the repository.")
    check = runpy.run_path(str(REPO / "scripts/bark-check.py"))
    arch = check["native_architecture"]()
    qualification = {"architecture": arch}
    try:
        if args.require_official:
            engine, qualification = verify_official_sdk(check, arch)
        else:
            engine = check["cached_engine"](arch)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    if not engine.is_dir():
        parser.error(f"Install this checkout's pinned {arch} Bark SDK first.")
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="bark-update-", dir="/private/tmp") as directory:
        work = Path(directory)
        with UpdateServer(bark_release.feed_name(arch)) as server:
            installed, newer, root, settings = versions(check, args.derived_data.resolve(), engine,
                                                         args.identity, arch, work, server, output)
            (output / "candidate.json").write_text(json.dumps(qualification) + "\n")
            exercise(check, installed, newer, root, settings, arch, server, output, engine=engine)
    print("Installed update rehearsal passed.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except ScreenUnavailable as failure:
        print(failure, file=sys.stderr)
        sys.exit(SCREEN_UNAVAILABLE)
