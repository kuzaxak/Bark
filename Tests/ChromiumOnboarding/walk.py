#!/usr/bin/env python3
"""Interrupt a signed Bark first launch and verify onboarding resumes."""

import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import plistlib
import runpy
import signal
import subprocess
import sys
import tempfile
import time
from uuid import UUID, uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Shared"))
from signed_walk import (REPO, Screen, ScreenUnavailable, crash_reports, processes,
                         verify_native_candidate, wait_for)
from run_browser_tests import (SCREEN_LOCK, SCREEN_UNAVAILABLE, QuartzConsole,
                               require_idle_console, screen_lock)


def starter_spaces(root):
    tabs = root / "App/Tabs"
    try:
        structure = json.loads((tabs / "structure.json").read_text())
        device = json.loads((tabs / "device.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    if device["state"]["firstLaunchCompleted"] is not True:
        return None
    return sorted(str(UUID(space["id"])) for space in structure["spaces"]
                  if space.get("deletedAt") is None) or None


@contextmanager
def launch(app, root, profile, log, console, owns_screen, stop):
    if processes(app):
        raise RuntimeError("A process from this signed app is already running")
    point = console.pointer()
    require_idle_console(console, owns_screen, point, min_idle=10)
    with log.open("wb") as stream:
        started = time.monotonic_ns()
        proc = subprocess.Popen([app / "Contents/MacOS/Bark", f"--barc-app-data-dir={root}",
                                 f"--barc-app-profile={profile}"],
                                stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            yield Screen(console, owns_screen, proc.pid, point, started), proc
        finally:
            if proc.poll() is None or processes(app):
                stop(proc)
            wait_for("Candidate processes were left behind", lambda: not processes(app))
    if "FATAL:" in log.read_text(errors="replace"):
        raise RuntimeError(f"The candidate wrote a fatal log in {log.name}")


def onboarding_button(screen, proc, name):
    from AppKit import NSApplicationActivateIgnoringOtherApps, NSRunningApplication

    def frontmost():
        asn = subprocess.check_output(["lsappinfo", "front"], text=True).strip()
        front = subprocess.check_output(["lsappinfo", "info", "-only", "pid", asn], text=True).strip()
        return front.split("=")[-1] == str(proc.pid)

    def sole_window():
        return len(screen.windows()) == 1

    wait_for(f"Expected a sole candidate window before {name!r}", sole_window, proc, timeout=30)
    if not frontmost():
        require_idle_console(screen.console, screen.owns_screen, screen.point, min_idle=10)
        candidate = NSRunningApplication.runningApplicationWithProcessIdentifier_(proc.pid)
        if candidate is None or candidate.processIdentifier() != proc.pid:
            raise RuntimeError("The disposable candidate could not be targeted for activation")
        if not candidate.activateWithOptions_(NSApplicationActivateIgnoringOtherApps):
            raise RuntimeError("macOS declined to activate the disposable candidate")
        wait_for("The disposable candidate did not become frontmost", frontmost, proc)
    return wait_for(f"Expected an onboarding button with {name!r}",
                    lambda: screen.button(name) if sole_window() else None, proc)


def run(app, output, contributor, console):
    launched_crashes = crash_reports()
    result = {"architecture": verify_native_candidate(contributor, app), "phases": {}}
    output.mkdir(parents=True, exist_ok=False)

    def record(phase, **values):
        result["phases"][phase] = values
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")

    with tempfile.TemporaryDirectory(prefix="bark-onboarding-", dir="/private/tmp") as folder:
        root = Path(folder).resolve(strict=True)
        if root.parent != Path("/private/tmp") or any(root.iterdir()):
            raise RuntimeError("Expected a fresh private verification root")
        profile = str(uuid4()).upper()
        marker = root / "App/onboarding-state"
        domain = "ee.qdo.nook.chromium-verification." + hashlib.sha256(root.as_posix().encode()).hexdigest()
        record("isolated", profile=profile, preferences_domain=domain)
        try:
            with screen_lock(SCREEN_LOCK, wait=30) as owns_screen:
                subprocess.run(["/usr/bin/defaults", "write", domain,
                                "settings.defaultBrowserPromptDismissedAt", "-float", str(time.time())], check=True)
                with launch(app, root, profile, output / "first-launch.log",
                            console, owns_screen, contributor["stop"]) as (screen, proc):
                    onboarding_button(screen, proc, "Get Started")
                    spaces = wait_for("Starter Tabs were never persisted", lambda: starter_spaces(root), proc)
                    initial_marker = marker.read_text() if marker.is_file() else None
                    record("first_launch", windows=1, onboarding_button="Get Started",
                           saved_spaces=spaces, marker=initial_marker)
                    require_idle_console(console, owns_screen, screen.point, min_idle=2)
                    screen.guard()
                    proc.kill()
                    if proc.wait(timeout=10) != -signal.SIGKILL:
                        raise RuntimeError("The first candidate exited before interruption")
                record("interrupted", signal="SIGKILL")

                with launch(app, root, profile, output / "relaunch.log",
                            console, owns_screen, contributor["stop"]) as (screen, proc):
                    start = onboarding_button(screen, proc, "Get Started")
                    if starter_spaces(root) != spaces:
                        raise RuntimeError("Relaunch did not retain the starter space identities")
                    require_idle_console(console, owns_screen, screen.point, min_idle=2)
                    screen.press_button(start)
                    # Observe the explicit skip control on the next stage. Do
                    # not start an import or finish setup in this test.
                    onboarding_button(screen, proc, "Skip")
                    current_marker = marker.read_text() if marker.is_file() else None
                    record("resumed", windows=1, onboarding_button="Skip",
                           saved_spaces=spaces, marker=current_marker)
                    if initial_marker != "pending\n" or current_marker != "pending\n":
                        raise RuntimeError("Onboarding did not retain its pending marker")
        finally:
            subprocess.run(["/usr/bin/defaults", "delete", domain], capture_output=True)
    if crash_reports() - launched_crashes:
        raise RuntimeError("A Bark crash report appeared during the walk")
    print("Signed Bark resumed onboarding with its original starter spaces and pending marker")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This walk requires macOS")
    app = args.app.resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if (info.get("CFBundleIdentifier") != "ee.qdo.bark" or "BarkUpdateRehearsal" in info
            or info.get("SUFeedURL")):
        parser.error("Pass the signed Bark developer candidate with updater and rehearsal metadata absent")
    import ApplicationServices as ax

    if not ax.AXIsProcessTrusted():
        parser.error("The runner needs existing Accessibility permission")
    try:
        run(app, args.output.resolve(), runpy.run_path(str(REPO / "scripts/bark-check.py")), QuartzConsole())
    except ScreenUnavailable as failure:
        print(failure, file=sys.stderr)
        return SCREEN_UNAVAILABLE
    return 0


if __name__ == "__main__":
    sys.exit(main())
