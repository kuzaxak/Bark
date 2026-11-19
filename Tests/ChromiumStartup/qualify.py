#!/usr/bin/env python3
"""Qualify one official Bark candidate on its native Mac using disposable profiles."""

import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import re
import runpy
import subprocess
import sys
import time

TESTS = Path(__file__).resolve().parents[1]
REPO = TESTS.parent
sys.path.insert(0, str(TESTS / "Shared"))
from signed_walk import bundle_cdhash, verify_official_sdk
from run_browser_tests import SCREEN_UNAVAILABLE, ScreenUnavailable
import bark_release
from publish_chromium_sdk import file_digest


def walk(script, arguments, output):
    # Each existing walk owns the idle-console guard and only returns zero
    # after quitting its disposable app and checking the observed result.
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.with_suffix(".log").open("x") as log:
        command = [sys.executable, "-B", script, "--require-official", *arguments, "--output", output]
        child = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        if child.returncode == SCREEN_UNAVAILABLE:
            raise ScreenUnavailable(f"The desktop became unavailable during {output.name}.")
        child.check_returncode()


def checked_measurements(observations, candidate):
    documents = set()
    samples = []
    for result in observations:
        if result["candidate"] != candidate or result["was_discarded"] is not False:
            raise ValueError("A parked-tab observation belongs to another candidate or lost its document.")
        if not result["document_id"] or result["document_id"] in documents:
            raise ValueError("Each startup sample must use a fresh document.")
        documents.add(result["document_id"])
        sample = {key: result[key] for key in
                  ("launch_to_pointer_ms", "switch_back_to_key_ms", "observed_hidden_ms")}
        if not all(isinstance(value, (float, int)) and not isinstance(value, bool)
                   and math.isfinite(value) and value > 0 for value in sample.values()):
            raise ValueError("A startup or parked-tab measurement is missing.")
        samples.append(sample)
    if len(samples) != 3:
        raise ValueError("Three successful native startup samples are required.")
    return samples


def check_update(update, candidate):
    if (any(update.get(key) != candidate[key] for key in ("architecture", "sdk_pin", "official"))
            or update.get("shell_source") != "signed-candidate"
            or update.get("source_bundle_cdhash") != candidate["bundle_cdhash"]):
        raise ValueError("The installed update used a different source app or SDK.")
    original = update["original_bundle_cdhash"]
    replacement = update["replacement_bundle_cdhash"]
    if original == replacement or any(not re.fullmatch(r"[0-9a-f]{40}", value) for value in (original, replacement)):
        raise ValueError("The update must identify two distinct signed rehearsal bundles.")
    return {"original_bundle_cdhash": original, "replacement_bundle_cdhash": replacement}


def qualify(app, image, identity, output):
    contributor = runpy.run_path(str(REPO / "scripts/bark-check.py"))
    architecture = contributor["native_architecture"]()
    _, provenance = verify_official_sdk(contributor, architecture, app)
    requirement = bark_release.distribution_requirement(app, "ee.qdo.bark") + ' and identifier "ee.qdo.bark"'
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, app], check=True)
    candidate = {**provenance, "bundle_cdhash": bundle_cdhash(app)}
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "ee.qdo.bark":
        raise ValueError("Select the signed Bark application.")
    result = {"candidate": candidate, "version": info["CFBundleShortVersionString"],
              "build": info["CFBundleVersion"]}

    def exercise(installed):
        observations = []
        for index in range(1, 4):
            if index > 1:
                # The preceding test's own quit gesture resets macOS's idle timer.
                time.sleep(11)
            trial = output / f"startup-{index}"
            walk(TESTS / "ChromiumStartup/walk.py", ["--app", installed], trial)
            observations.append(json.loads((trial / "result.json").read_text()))
        result["startup"] = checked_measurements(observations, candidate)
        result["hardware"] = observations[0]["hardware"]
        result["macos"] = observations[0]["macos"]
        time.sleep(11)
        update = output / "installed-update"
        walk(TESTS / "ChromiumUpdate/walk.py", ["--candidate-app", installed, "--identity", identity], update)
        result["installed_update"] = check_update(json.loads((update / "candidate.json").read_text()), candidate)
        if bundle_cdhash(installed) != candidate["bundle_cdhash"]:
            raise ValueError("The source candidate changed during qualification.")

    if image:
        result["image_sha256"] = file_digest(image)
        bark_release.verify_installed_image(image, app, output, requirement, None, exercise=exercise)
        if result["image_sha256"] != file_digest(image):
            raise ValueError("The disk image changed during qualification.")
    else:
        exercise(app)
    path = output / "qualification.json"
    temporary = output / "qualification.tmp"
    temporary.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)
    print(f"Qualified {architecture} Bark build {result['build']}. Receipt: {path}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Signed app built with the checkout's official SDK")
    parser.add_argument("--image", type=Path, help="Assess and run the copy installed from this notarized release DMG")
    parser.add_argument("--identity", default=os.environ.get("BARK_SIGN_IDENTITY"), help="Local Developer ID Application")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory outside the checkout")
    args = parser.parse_args()
    if not args.identity:
        parser.error("Pass --identity or set BARK_SIGN_IDENTITY.")
    output = args.output.resolve()
    if output.is_relative_to(REPO) or output.is_relative_to(args.app.resolve()):
        parser.error("Choose an evidence directory outside the checkout and app.")
    try:
        output.mkdir(parents=True, exist_ok=False)
        qualify(args.app.resolve(strict=True), args.image.resolve(strict=True) if args.image else None,
                args.identity, output)
    except ScreenUnavailable as error:
        print(f"{error} See {output} for walk logs.", file=sys.stderr)
        return SCREEN_UNAVAILABLE
    except subprocess.CalledProcessError as error:
        print(f"{error}. See {output} for individual walk logs.", file=sys.stderr)
        return 1
    except (OSError, KeyError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
