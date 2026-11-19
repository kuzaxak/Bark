# Licensed under GPL-3.0. See LICENSE.
"""Portable inputs for the signed, loopback-only Sparkle rehearsal."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlsplit
from uuid import UUID

import bark_release
from publish_chromium_sdk import file_digest

KIT_FILES = {"100": "original.dmg", "101": "replacement.dmg"}
PAYLOAD = (*KIT_FILES.values(), "appcast.xml")
DIGEST = re.compile(r"[0-9a-f]{64}")
MANIFEST = "kit.json"
VERSIONS = {"100": "1.0.0", "101": "1.0.1"}


def profile_workspace(bundle_uuid):
    return Path("/private/tmp") / f"bark-update-kit-{bundle_uuid}"


def rehearsal_settings(bundle_uuid, root, profile, feed, key):
    return {
        "CFBundleIdentifier": f"ee.qdo.bark.test.{bundle_uuid}",
        "BarkUpdateRehearsal": {"DataRoot": str(root), "Profile": profile},
        "SUFeedURL": feed,
        "SUPublicEDKey": key,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUEnableAutomaticChecks": False,
    }


def write_kit(stage, arch, evidence, settings):
    manifest = {
        "format": 1, "architecture": arch, "sdk_pin": evidence["sdk_pin"],
        "source_bundle_cdhash": evidence["source_bundle_cdhash"],
        "settings": settings,
        "sha256": {name: file_digest(stage / name) for name in PAYLOAD},
    }
    (stage / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n")


def load_kit(kit, arch, pin, source_hash):
    expected = set(PAYLOAD) | {MANIFEST}
    if {path.name for path in kit.iterdir()} != expected or any(
            path.is_symlink() or not path.is_file() for path in kit.iterdir()):
        raise ValueError("The kit must contain only its regular manifest, feed and two disk images.")
    receipt = kit / MANIFEST
    if receipt.stat().st_size > 16_384 or (kit / "appcast.xml").stat().st_size > 16_384:
        raise ValueError("The kit manifest or feed is too large.")
    manifest = json.loads(receipt.read_text())
    if (manifest["format"], manifest["architecture"], manifest["sdk_pin"],
            manifest["source_bundle_cdhash"]) != (1, arch, pin, source_hash):
        raise ValueError("The kit does not match this architecture, SDK pin and signed source app.")

    settings = manifest["settings"]
    bundle_uuid = UUID(settings["CFBundleIdentifier"].removeprefix("ee.qdo.bark.test."))
    root = profile_workspace(bundle_uuid) / "Profile"
    profile = str(UUID(settings["BarkUpdateRehearsal"]["Profile"])).upper()
    if bundle_uuid.version != 4 or UUID(profile).version != 4:
        raise ValueError("The kit must use unique version-4 rehearsal and profile identifiers.")
    feed = urlsplit(settings["SUFeedURL"])
    port = feed.port
    if not port or feed.geturl() != f"http://127.0.0.1:{port}/{bark_release.feed_name(arch)}":
        raise ValueError("The kit feed must use the sealed loopback endpoint for this architecture.")
    required = rehearsal_settings(bundle_uuid, root, profile, feed.geturl(), settings["SUPublicEDKey"])
    if settings != required or os.path.lexists(root.parent):
        raise ValueError("The sealed rehearsal settings do not match a fresh disposable path.")
    if settings["SUEnableAutomaticChecks"] is not False or settings["SUVerifyUpdateBeforeExtraction"] is not True:
        raise ValueError("The kit must require manual checks and pre-extraction verification.")
    for build, version in VERSIONS.items():
        bark_release.check_distribution_settings(
            dict(settings, CFBundleShortVersionString=version, CFBundleVersion=build,
                 LSMinimumSystemVersion="15.5"),
            arch, f"http://127.0.0.1:{port}",
        )
    for filename in PAYLOAD:
        digest = manifest["sha256"][filename]
        if not DIGEST.fullmatch(digest) or digest != file_digest(kit / filename):
            raise ValueError(f"The kit payload has changed: {filename}")
    return settings, root, port


def image_route(arch):
    return f"/Bark-1.0.1-101-macos-{arch}.dmg"


@contextmanager
def mount_app(image, work, run):
    with tempfile.TemporaryDirectory(dir=work, prefix="mount-") as folder:
        mount = Path(folder)
        run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", mount, image, stdin=subprocess.DEVNULL)
        try:
            app = mount / "Bark.app"
            if app.is_symlink() or not app.is_dir():
                raise ValueError("The disk image does not contain a regular Bark.app.")
            yield app
        finally:
            run("/usr/bin/hdiutil", "detach", mount)
