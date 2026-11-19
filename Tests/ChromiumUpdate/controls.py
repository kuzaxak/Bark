#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Exercise Bark's automatic update controls with the pinned Sparkle framework."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import select
import shutil
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from uuid import uuid4

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.dont_write_bytecode = True
sys.path[:0] = [str(REPO / path) for path in ("Tests/Shared", "Runtime/Chromium", "scripts")]
from chromium_sdk_layout import native_architecture
from run_browser_tests import (SCREEN_LOCK, SCREEN_UNAVAILABLE, QuartzConsole,
                               ScreenUnavailable, require_idle_console, screen_lock)
from signed_walk import Accessibility, wait_for

CHECK = "Check for updates automatically"
DOWNLOAD = "Download and install updates automatically"
CHECK_KEY = "SUEnableAutomaticChecks"
DOWNLOAD_KEY = "SUAutomaticallyUpdate"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def build(root, sparkle):
    lock = REPO / "Bark.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    version = next(pin["state"]["version"] for pin in json.loads(lock.read_text())["pins"]
                   if pin["identity"] == "sparkle")
    actual = plistlib.loads((sparkle / "Resources/Info.plist").read_bytes())
    if actual["CFBundleShortVersionString"] != version:
        raise ValueError(f"This checkout pins Sparkle {version}")
    binary = root / "UpdateControls"
    sources = REPO / "App/Chromium"
    run("xcrun", "swiftc", "-parse-as-library", "-target", f"{native_architecture()}-apple-macosx15.5",
        "-F", sparkle.parent, "-framework", "Sparkle", "-Xlinker", "-rpath",
        "-Xlinker", "@executable_path/../Frameworks", "-o", binary, HERE / "Controls.swift",
        *(sources / name for name in ("ChromiumStartup.swift", "ChromiumUpdateConfiguration.swift",
                                      "ChromiumAppUpdater.swift")))
    return binary


def stage(root, binary, sparkle, port, mode):
    identifier = "ee.qdo.bark.test." + str(uuid4())
    app = root / f"{mode}.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    shutil.copy2(binary, contents / "MacOS" / binary.name)
    run("ditto", sparkle, contents / "Frameworks/Sparkle.framework")
    # This bound port never serves responses. Both test feeds can reach
    # only this machine, even if Sparkle attempts an unexpected check.
    scheme = "http" if mode == "rehearsal" else "https"
    info = {"CFBundleIdentifier": identifier, "CFBundleName": "Sparkle Settings Fixture",
            "CFBundlePackageType": "APPL", "CFBundleExecutable": binary.name,
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "SUFeedURL": f"{scheme}://127.0.0.1:{port}/bark-macos-{native_architecture()}.xml",
            "SUPublicEDKey": "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=",
            CHECK_KEY: False}
    if mode == "rehearsal":
        info["BarkUpdateRehearsal"] = {"DataRoot": str(root), "Profile": str(uuid4())}
    if mode == "no-download":
        info["SUAllowsAutomaticUpdates"] = False
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--deep", "--sign", "-", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    return identifier, contents / "MacOS" / binary.name


def stored(identifier):
    result = subprocess.check_output(["defaults", "export", identifier, "-"])
    return plistlib.loads(result)


class FixtureAccessibility:
    """Address only the fixture's AX elements, without taking keyboard focus."""

    def __init__(self, ax, process, console, owns_screen, pointer):
        self.ax = ax
        self.process = process
        self.console = console
        self.owns_screen = owns_screen
        self.pointer = pointer

    def guard(self):
        require_idle_console(self.console, self.owns_screen, self.pointer, min_idle=10)

    def press_button(self, element):
        self.guard()
        status, pid = self.ax.AXUIElementGetPid(element, None)
        if status != 0 or pid != self.process.pid:
            raise RuntimeError("Update control belongs to a different application")
        if self.ax.AXUIElementPerformAction(element, "AXPress") != 0:
            raise RuntimeError("The fixture refused the accessibility action")


def launch(binary, mode, ax, console, owns_screen, pointer, exercise):
    require_idle_console(console, owns_screen, pointer, min_idle=10)
    args = [str(binary)]
    if mode == "without-start":
        args.append("--without-start")
    with subprocess.Popen(args) as proc:
        try:
            access = Accessibility(FixtureAccessibility(ax, proc, console, owns_screen, pointer), proc)
            finish = access.control("Finish", ("AXButton",))
            exercise(access)
            access.press(finish)
            if proc.wait(timeout=10) != 0:
                raise RuntimeError(f"{mode} fixture did not quit normally")
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


def expect(access, label, *, value=None, enabled=None):
    def lookup():
        matches = []
        for window in access.windows():
            for element in access.tree(window):
                if access.attribute(element, "AXRole") not in ("AXCheckBox", "AXSwitch"):
                    continue
                title = access.attribute(element, "AXTitleUIElement")
                if label in access.names(element) or label in access.names(title):
                    matches.append(element)
        if len(matches) > 1:
            raise RuntimeError(f"More than one update control is named {label}")
        return matches[0] if matches else None

    # The fixture's Finish button confirms the form has rendered.
    if value is None:
        if lookup() is not None:
            raise RuntimeError(f"Unexpected control: {label}")
        return None

    def matches():
        element = lookup()
        if element is not None and (
            access.attribute(element, "AXValue") == value
            and access.attribute(element, "AXEnabled") == enabled
        ):
            return element
        return None

    return wait_for(f"{label} did not reach value={value}, enabled={enabled}",
                    matches, access.process, timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sparkle", type=Path, required=True,
                        help="Sparkle.framework from this checkout's locked Xcode products")
    args = parser.parse_args()
    import ApplicationServices as ax

    if not ax.AXIsProcessTrusted():
        parser.error("Run with existing Accessibility access")
    sparkle = args.sparkle.absolute()
    console = QuartzConsole()
    with TemporaryDirectory(prefix="bark-update-controls-", dir="/private/tmp") as folder, socket.socket() as feed:
        root = Path(folder)
        feed.bind(("127.0.0.1", 0))
        feed.listen()
        binary = build(root, sparkle)
        port = feed.getsockname()[1]
        candidates = {mode: stage(root, binary, sparkle, port, mode)
                      for mode in ("release", "rehearsal", "no-download")}
        try:
            defaults = root / "InitialDefaults.plist"
            defaults.write_bytes(plistlib.dumps(
                {"SULastCheckTime": datetime.now(timezone.utc).replace(tzinfo=None)}))
            for identifier, _ in candidates.values():
                run("defaults", "import", identifier, defaults)
            release, release_binary = candidates["release"]

            def hidden(access):
                expect(access, CHECK)
                expect(access, DOWNLOAD)

            def check_persisted(key, value):
                wait_for(f"Sparkle did not persist {key}={value}",
                         lambda: stored(release).get(key) is value, timeout=5)

            def change(access):
                download = expect(access, DOWNLOAD, value=False, enabled=False)
                check = expect(access, CHECK, value=False, enabled=True)
                if access.center(check)[1] >= access.center(download)[1]:
                    raise RuntimeError("Update controls do not occupy distinct ordered form rows")
                access.press(check)
                check_persisted(CHECK_KEY, True)
                access.press(expect(access, DOWNLOAD, value=False, enabled=True))
                check_persisted(DOWNLOAD_KEY, True)
                access.press(expect(access, CHECK, value=True, enabled=True))
                check_persisted(CHECK_KEY, False)
                expect(access, DOWNLOAD, value=True, enabled=False)
                check_persisted(DOWNLOAD_KEY, True)

            def restored(access):
                expect(access, DOWNLOAD, value=True, enabled=False)
                access.press(expect(access, CHECK, value=False, enabled=True))
                access.press(expect(access, DOWNLOAD, value=True, enabled=True))
                check_persisted(DOWNLOAD_KEY, False)
                access.press(expect(access, CHECK, value=True, enabled=True))
                check_persisted(CHECK_KEY, False)

            def policy(access):
                expect(access, CHECK, value=False, enabled=True)
                expect(access, DOWNLOAD)

            with screen_lock(SCREEN_LOCK, wait=30) as owns_screen:
                pointer = console.pointer()
                time.sleep(0.4)
                for mode, candidate, exercise in (
                    ("without-start", release_binary, hidden),
                    ("rehearsal", candidates["rehearsal"][1], hidden),
                    ("no-download", candidates["no-download"][1], policy),
                    ("release", release_binary, change),
                    ("reopened", release_binary, restored),
                ):
                    launch(candidate, mode, ax, console, owns_screen, pointer, exercise)
                    print(f"Passed {mode} automatic update controls", flush=True)
            if select.select([feed], [], [], 0)[0]:
                raise RuntimeError("Sparkle attempted an update request during the settings check")
        finally:
            for identifier, executable in candidates.values():
                subprocess.run(["defaults", "delete", identifier], capture_output=True)
                subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                                "LaunchServices.framework/Support/lsregister", "-u",
                                str(executable.parents[2])], capture_output=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ScreenUnavailable as error:
        print(error, file=sys.stderr)
        sys.exit(SCREEN_UNAVAILABLE)
