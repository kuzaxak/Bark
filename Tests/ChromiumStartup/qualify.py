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
import stat
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
from chromium_sdk_layout import read_pin


MEASUREMENTS = ("launch_to_pointer_ms", "switch_back_to_key_ms", "observed_hidden_ms")


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
        samples.append({key: result[key] for key in MEASUREMENTS})
    validate_samples(samples)
    return samples


def validate_samples(samples):
    if not isinstance(samples, list) or len(samples) != 3:
        raise ValueError("Three successful native startup samples are required.")
    for sample in samples:
        for key in MEASUREMENTS:
            value = sample.get(key) if isinstance(sample, dict) else None
            if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value <= 0:
                raise ValueError("A startup or parked-tab measurement is missing.")


def check_update(update, candidate):
    if (any(update.get(key) != candidate[key] for key in ("architecture", "sdk_pin", "official"))
            or update.get("shell_source") != "signed-candidate"
            or update.get("source_bundle_cdhash") != candidate["bundle_cdhash"]):
        raise ValueError("The installed update used a different source app or SDK.")
    return checked_update_identities(update)


def checked_update_identities(update):
    original = update["original_bundle_cdhash"]
    replacement = update["replacement_bundle_cdhash"]
    if original == replacement or any(not re.fullmatch(r"[0-9a-f]{40}", value) for value in (original, replacement)):
        raise ValueError("The update must identify two distinct signed rehearsal bundles.")
    return {"original_bundle_cdhash": original, "replacement_bundle_cdhash": replacement}


def installed_size_bytes(app):
    """Logical payload bytes, counting regular files once regardless of framework aliases."""
    engine = app / "Contents/Frameworks/Bark Framework.framework"
    pending = [app]
    files, engine_files = {}, {}
    while pending:
        for path in pending.pop().iterdir():
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                pending.append(path)
            elif stat.S_ISREG(info.st_mode):
                file_id = (info.st_dev, info.st_ino)
                files[file_id] = info.st_size
                if path.is_relative_to(engine):
                    engine_files[file_id] = info.st_size
    return {"installed_app": sum(files.values()), "chromium_framework": sum(engine_files.values())}


def verify_release_signature(app):
    requirement = bark_release.distribution_requirement(app, "ee.qdo.bark") + ' and identifier "ee.qdo.bark"'
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, app], check=True)
    return requirement


def qualify(app, image, identity, output, *, update_kit=None):
    contributor = runpy.run_path(str(REPO / "scripts/bark-check.py"))
    architecture = contributor["native_architecture"]()
    _, provenance = verify_official_sdk(contributor, architecture, app)
    requirement = verify_release_signature(app)
    candidate = {**provenance, "bundle_cdhash": bundle_cdhash(app)}
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "ee.qdo.bark":
        raise ValueError("Select the signed Bark application.")
    result = {"candidate": candidate, "version": info["CFBundleShortVersionString"],
              "installation": "notarized-dmg" if image else "signed-app",
              "build": info["CFBundleVersion"]}

    def exercise(installed):
        result["size_bytes"] = installed_size_bytes(installed)
        if image:
            result["size_bytes"]["download_dmg"] = image.stat().st_size
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
        signing = ["--kit", update_kit] if update_kit else ["--identity", identity]
        walk(TESTS / "ChromiumUpdate/walk.py", ["--candidate-app", installed, *signing], update)
        evidence = json.loads((update / "candidate.json").read_text())
        result["installed_update"] = check_update(evidence, candidate)
        if update_kit:
            fingerprint = evidence.get("rehearsal_kit")
            if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
                raise ValueError("The installed update did not identify its pre-signed rehearsal kit.")
            result["installed_update"]["rehearsal_kit"] = fingerprint
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
    print(f"Qualified {architecture} Bark build {result['build']} ({result['installation']}). "
          f"Receipt: {path}", flush=True)


def check_release_receipt(receipt, image, architecture, app):
    result = json.loads(receipt.read_text())
    if result.get("installation") != "notarized-dmg":
        raise ValueError("Release qualification requires a notarized DMG installation.")
    candidate = result["candidate"]
    if candidate["architecture"] != architecture or candidate["official"] is not True:
        raise ValueError("The release receipt requires the official SDK for the release architecture.")
    if candidate["bundle_cdhash"] != bundle_cdhash(app):
        raise ValueError("The release app does not match the app in the qualification receipt.")
    if result["image_sha256"] != file_digest(image):
        raise ValueError("The release DMG does not match the image in the qualification receipt.")
    if candidate.get("sdk_pin") != read_pin(REPO / "Packages/BarkEngine", architecture):
        raise ValueError("The release receipt belongs to a different SDK pin.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (result.get("build"), result.get("version")) != (info["CFBundleVersion"], info["CFBundleShortVersionString"]):
        raise ValueError("The release receipt belongs to a different Bark build.")
    validate_samples(result.get("startup"))
    checked_update_identities(result["installed_update"])
    verify_release_signature(app)


def release_receipt_main(argv):
    parser = argparse.ArgumentParser(description="Check a native qualification receipt before release transfer.")
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--arch", choices=("x86_64", "arm64"), required=True)
    args = parser.parse_args(argv)
    try:
        check_release_receipt(args.receipt, args.image, args.arch, args.app)
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


def main():
    if sys.argv[1:2] == ["check-release-receipt"]:
        return release_receipt_main(sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Signed app built with the checkout's official SDK")
    parser.add_argument("--image", type=Path, help="Assess and run the copy installed from this notarized release DMG")
    signing = parser.add_mutually_exclusive_group()
    signing.add_argument("--identity", help="Local Developer ID Application identity")
    signing.add_argument("--update-kit", type=Path, help="Pre-signed update rehearsal for this app and native architecture")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory outside the checkout")
    args = parser.parse_args()
    identity = None if args.update_kit else args.identity or os.environ.get("BARK_SIGN_IDENTITY")
    if not (args.update_kit or identity):
        parser.error("Pass --update-kit, --identity, or set BARK_SIGN_IDENTITY.")
    output = args.output.resolve()
    if (output.is_relative_to(REPO) or output.is_relative_to(args.app.resolve())
            or (args.update_kit and output.is_relative_to(args.update_kit.resolve()))):
        parser.error("Choose an evidence directory outside the checkout, app and rehearsal kit.")
    try:
        output.mkdir(parents=True, exist_ok=False)
        qualify(args.app.resolve(strict=True), args.image.resolve(strict=True) if args.image else None,
                identity, output, update_kit=args.update_kit.resolve(strict=True) if args.update_kit else None)
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
