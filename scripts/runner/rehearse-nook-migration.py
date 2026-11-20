#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Install both signed Nook-to-Bark update hops in a hosted runner's scratch directory."""

import argparse
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from threading import Thread
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from bark_release import SPARKLE, SPARKLE_PUBLIC_KEY, TEAM, bundle_cdhash, developer_id_requirement

RELEASES = "https://github.com/kuzaxak/Nook/releases"
ENCLOSURES = RELEASES + "/download/bark-v2.0.0/"
FEEDS = RELEASES + "/latest/download/"
NOOK_154_SHA256 = "bba44fe5ec819c21e07478334e89adb35386980fc7ab418b764a98d5f9fbac39"


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def sha256(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def app_record(app, identifier, version, build, architectures, *, bundle_name=None):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
        "CFBundleVersion": build, "SUPublicEDKey": SPARKLE_PUBLIC_KEY,
    }
    if bundle_name:
        expected["SUBundleName"] = bundle_name
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"{app}: expected {key}={value!r}, found {info.get(key)!r}")
    requirement = f'{developer_id_requirement(TEAM)} and identifier "{identifier}"'
    run("/usr/bin/codesign", "--verify", "--strict", "--deep", "-R", requirement, app)
    run("/usr/bin/lipo", "-verify_arch", *architectures, app / "Contents/MacOS" / info["CFBundleExecutable"])
    return {
        "bundle_id": identifier, "version": version, "build": build,
        "bundle_cdhash": bundle_cdhash(app), "feed_url": info.get("SUFeedURL"),
    }


@contextmanager
def mounted(image, working):
    mount = working / "mount"
    mount.mkdir()
    run("xcrun", "stapler", "validate", image)
    run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, image)
    try:
        yield mount
    finally:
        run("hdiutil", "detach", mount)
        mount.rmdir()


def feed_data(feed, image, version, build):
    data = feed.read_bytes()
    [item] = ET.fromstring(data).findall("./channel/item")
    [enclosure] = item.findall("enclosure")
    canonical_url = ENCLOSURES + image.name
    if enclosure.get("url") != canonical_url or enclosure.get("length") != str(image.stat().st_size):
        raise ValueError(f"{feed}: published enclosure URL or length does not match {image.name}")
    version_key = f"{{{SPARKLE}}}version"
    if (item.findtext(version_key) or enclosure.get(version_key)) != build:
        raise ValueError(f"{feed}: unexpected Sparkle build")
    short_version = f"{{{SPARKLE}}}shortVersionString"
    if (item.findtext(short_version) or enclosure.get(short_version)) != version:
        raise ValueError(f"{feed}: unexpected Sparkle marketing version")
    signature = enclosure.attrib[f"{{{SPARKLE}}}edSignature"]
    run("xcrun", "swift", ROOT / "scripts/VerifyBarkUpdate.swift", image, SPARKLE_PUBLIC_KEY, signature)
    return data, canonical_url


@contextmanager
def loopback_feed(feed, image, canonical_url):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/appcast.xml":
                self.send_response(200)
                self.send_header("Content-Type", "application/rss+xml")
                self.send_header("Content-Length", str(len(feed_copy)))
                self.end_headers()
                self.wfile.write(feed_copy)
            elif self.path == "/update.dmg":
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(image.stat().st_size))
                self.end_headers()
                with image.open("rb") as source:
                    shutil.copyfileobj(source, self.wfile)
            else:
                self.send_error(404)

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        url = f"http://127.0.0.1:{server.server_port}"
        literal_url = f'url="{canonical_url}"'.encode()
        if feed.count(literal_url) != 1:
            raise ValueError("Expected one enclosure URL to redirect to loopback.")
        feed_copy = feed.replace(literal_url, f'url="{url}/update.dmg"'.encode())
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield url + "/appcast.xml"
        finally:
            server.shutdown()
            thread.join()


def rehearse(arch, release, legacy_image, cli, working, receipts):
    if subprocess.check_output(["uname", "-m"], text=True).strip() != arch:
        raise ValueError(f"Expected a native {arch} runner.")
    if sha256(legacy_image) != NOOK_154_SHA256:
        raise ValueError("The baseline is not the published universal Nook 1.5.4 DMG.")
    universal = ("arm64", "x86_64")
    legacy = ("ee.qdo.nook", "1.5.4", "202611050920", universal)
    transition = ("ee.qdo.nook", "1.5.5", "202611200001", universal)
    bark = ("ee.qdo.bark", "2.0.0", "202611200002", (arch,))

    target = working / "Renamed Nook.app"
    with mounted(legacy_image, working) as mount:
        run("/usr/bin/ditto", mount / "Nook.app", target)
    first = app_record(target, *legacy)
    if first["feed_url"] != FEEDS + "appcast.xml":
        raise ValueError("The existing Nook installation uses an unexpected update feed.")

    records = [{**first, "image": legacy_image.name, "image_sha256": NOOK_154_SHA256}]
    for identity, image, feed, signed_name, signed_feed, bundle_name in (
        (transition, release / "Nook-1.5.5-universal.dmg", release / "appcast.xml",
         "Nook.app", FEEDS + "appcast.xml", "Bark"),
        (bark, release / f"Bark-2.0.0-202611200002-macos-{arch}.dmg", release / f"bark-macos-{arch}.xml",
         "Bark.app", FEEDS + f"bark-macos-{arch}.xml", None),
    ):
        data, canonical = feed_data(feed, image, identity[1], identity[2])
        with mounted(image, working) as mount:
            original = mount / signed_name
            expected = app_record(original, *identity, bundle_name=bundle_name)
            if identity == bark:
                run("/usr/bin/ditto", original, working / signed_name)
        if expected["feed_url"] != signed_feed:
            raise ValueError(f"{image}: signed app uses an unexpected update feed.")
        with loopback_feed(data, image, canonical) as url:
            run(cli, "--check-immediately", "--feed-url", url, "--allow-major-upgrades", target, timeout=240)
        installed = app_record(target, *identity, bundle_name=bundle_name)
        if installed != expected:
            raise ValueError(f"Sparkle did not install the expected signed payload from {image}.")
        records.append({**installed, "image": image.name, "image_sha256": sha256(image),
                        "enclosure_url": canonical})

    (receipts / f"migration-{arch}.json").write_text(json.dumps({
        "architecture": arch,
        "installed_path": target.name,
        "sparkle_cli_version": "2.8.1",
        "scope": "Sparkle CLI installed both signed payloads in place; application delegate and relaunch were not exercised.",
        "installs": records,
    }, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arch", choices=("arm64", "x86_64"))
    for arg in ("release", "legacy_image", "sparkle_cli", "work", "receipts"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    rehearse(args.arch, args.release.resolve(), args.legacy_image.resolve(),
            args.sparkle_cli.resolve(), args.work.resolve(), args.receipts.resolve())


if __name__ == "__main__":
    main()
