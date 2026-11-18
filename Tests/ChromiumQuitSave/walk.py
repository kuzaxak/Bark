#!/usr/bin/env python3
"""Quit signed Bark while its disposable Network Service cannot finish flushing."""

import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import run_walk, wait_for


def network_child(parent):
    # macOS ps keeps the full executable path in comm even if argv is modified.
    parent_path = executable(parent)
    if parent_path.name != "Bark" or parent_path.parent.name != "MacOS":
        raise RuntimeError("Expected the signed Bark candidate as the parent")
    frameworks = parent_path.parents[1] / "Frameworks"
    rows = subprocess.check_output(["ps", "-ww", "-axo", "pid=,ppid=,command="], text=True)
    matches = []
    for row in rows.splitlines():
        fields = row.strip().split(None, 2)
        if len(fields) != 3 or fields[1] != str(parent):
            continue
        if "--utility-sub-type=network.mojom.NetworkService" in fields[2].split():
            child = int(fields[0])
            image = executable(child)
            if image.is_relative_to(frameworks) and image.name.startswith("Bark Helper"):
                matches.append(child)
    if len(matches) == 1:
        return matches[0]
    if matches:
        raise RuntimeError("Expected one Network Service for the disposable app")
    return None


def executable(pid):
    result = subprocess.run(["ps", "-ww", "-p", str(pid), "-o", "comm="],
                            capture_output=True, text=True)
    return Path(result.stdout.strip())


def identity(pid):
    result = subprocess.run(["ps", "-ww", "-p", str(pid), "-o", "lstart=,comm="],
                            capture_output=True, text=True)
    return result.stdout.strip()


def exercise(screen, process, events, output):
    wait_for("Loopback page did not load", lambda: any(e.get("event") == "ready" for e in events), process)
    screen.key("q", screen.command)
    confirm = wait_for("Bark did not offer to quit", lambda: screen.button("Quit"), process)
    child = wait_for("Bark did not launch its Network Service", lambda: network_child(process.pid), process)
    original = identity(child)
    screen.guard()
    if not original or network_child(process.pid) != child or identity(child) != original:
        raise RuntimeError("The fixture Network Service changed before Quit")

    start = time.monotonic()
    try:
        os.kill(child, signal.SIGSTOP)
        screen.press_button(confirm)
        status = process.wait(timeout=30)
        elapsed = time.monotonic() - start
        (output / "network-shutdown.json").write_text(
            json.dumps({"exit_status": status, "elapsed_seconds": round(elapsed, 2)}) + "\n"
        )
        if status != 0:
            raise RuntimeError(f"Bark exited with status {status} after {elapsed:.2f}s during the flush")
        # A stuck child gets ten seconds to flush. Catch a shortcut that skips
        # the wait and reports a successful exit by terminating it immediately.
        if elapsed < 9.5:
            raise RuntimeError(f"Bark quit before the held Network Service got its flush interval ({elapsed:.2f}s)")
    finally:
        # A stopped child may have outlived its parent. Only resume the process
        # captured for this run. The shared harness checks that every helper exits.
        if identity(child) == original:
            try:
                os.kill(child, signal.SIGCONT)
            except ProcessLookupError:
                pass
    print(f"Bark quit cleanly after the held Network Service flush ({elapsed:.2f}s).", flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    fixture = runpy.run_path(str(HERE.parent / "ChromiumPeek/walk.py"))
    sys.exit(run_walk(__doc__, "network-quit", fixture["serve"], exercise))
