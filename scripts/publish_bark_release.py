#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Verify and publish one Bark release while preserving the legacy Nook feed."""

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
import xml.etree.ElementTree as ET

from bark_release import (REPO, SPARKLE, SPARKLE_PUBLIC_KEY, TEAM, check_versions,
                          developer_id_requirement, feed_name, verify_installed_image)
from chromium_sdk_layout import file_digest


REPOSITORY = "kuzaxak/Bark"
NOOK_FEED = "https://github.com/kuzaxak/Nook/releases/latest/download/appcast.xml"
GITHUB = f"https://github.com/{REPOSITORY}"
FEED_BASE = f"{GITHUB}/releases/latest/download"
TRANSITION_TAG = "bark-v2.0.0"
TRANSITION_NAME = "Nook-1.5.5-universal.dmg"
TRANSITION_BUILD = "202611200001"
LEGACY_TAG = "v1.5.4"
ARCHITECTURES = ("x86_64", "arm64")


@dataclass(frozen=True)
class Asset:
    path: Path
    size: int
    digest: str

    @classmethod
    def read(cls, path):
        if not path.is_file():
            raise ValueError(f"Missing release asset {path}.")
        return cls(path, path.stat().st_size, "sha256:" + file_digest(path))

    def check_remote(self, remote, tag, *, published=True):
        if (remote["state"] != "uploaded" or remote["size"] != self.size
                or remote.get("digest") != self.digest
                or published and remote["browser_download_url"] != download_url(tag, self.path.name)):
            raise ValueError(f"GitHub's {tag}/{self.path.name} differs from the verified asset.")


def download_url(tag, name):
    return f"{GITHUB}/releases/download/{tag}/{name}"


def appcast_item(data):
    channel = ET.fromstring(data).find("channel")
    if channel is None or len(channel.findall("item")) != 1:
        raise ValueError("Expected an appcast with exactly one update.")
    item = channel.find("item")
    if len(item.findall("enclosure")) != 1:
        raise ValueError("Expected exactly one full update enclosure.")
    return channel, item, item.find("enclosure")


def check_appcast(feed, image, tag, version, build, *, ordinary):
    channel, item, enclosure = appcast_item(feed.path.read_bytes())
    expected_feed = f"{FEED_BASE}/{feed.path.name}"
    if ordinary and channel.findtext("link") != expected_feed:
        raise ValueError(f"{feed.path.name} points to the wrong update feed.")
    expected = {"version": build, "shortVersionString": version}
    if any(item.findtext(f"{{{SPARKLE}}}{key}") != value for key, value in expected.items()):
        raise ValueError(f"{feed.path.name} describes the wrong Bark build.")
    if (enclosure.get("url") != download_url(tag, image.path.name)
            or enclosure.get("length") != str(image.size)):
        raise ValueError(f"{feed.path.name} describes the wrong disk image.")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature")
    if not signature:
        raise ValueError(f"{feed.path.name} has no Ed25519 enclosure signature.")
    subprocess.run(["xcrun", "swift", REPO / "scripts/VerifyBarkUpdate.swift",
                    image.path, SPARKLE_PUBLIC_KEY, signature], check=True)


def check_image(image, feed, arch, version, build):
    subprocess.run([sys.executable, "-B", REPO / "Tests/ChromiumStartup/qualify.py",
                    "check-release-image", "--image", image.path, "--arch", arch,
                    "--version", version, "--build", build,
                    "--feed-url", f"{FEED_BASE}/{feed.path.name}"], check=True)
    subprocess.run(["xcrun", "stapler", "validate", image.path], check=True)


def check_transition(image):
    requirement = developer_id_requirement(TEAM)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", requirement, image.path], check=True)
    subprocess.run(["xcrun", "stapler", "validate", image.path], check=True)

    def verify_copy(app):
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        expected = {
            "CFBundleShortVersionString": "1.5.5",
            "CFBundleVersion": TRANSITION_BUILD,
            "SUBundleName": "Bark",
            "SUPublicEDKey": SPARKLE_PUBLIC_KEY,
            "SUFeedURL": NOOK_FEED,
        }
        if any(info.get(key) != value for key, value in expected.items()):
            raise ValueError("The signed universal app does not match the legacy transition metadata.")
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        if set(subprocess.check_output(["xcrun", "lipo", "-archs", executable], text=True).split()) != set(ARCHITECTURES):
            raise ValueError("The legacy transition app must run on both architectures.")
        subprocess.run(["xcrun", "stapler", "validate", app], check=True)

    with TemporaryDirectory(prefix="bark-transition-", dir="/private/tmp") as work:
        verify_installed_image(image.path, None, Path(work), requirement + ' and identifier "ee.qdo.nook"',
                               verify_copy, app_name="Nook.app")


def prepare_assets(directory, transition_path, tag, version, build):
    transition = Asset.read(transition_path)
    if transition.path.name != TRANSITION_NAME:
        raise ValueError(f"The transition image must be named {TRANSITION_NAME}.")
    legacy_feed = Asset.read(directory / "appcast.xml")
    check_appcast(legacy_feed, transition, TRANSITION_TAG, "1.5.5", TRANSITION_BUILD, ordinary=False)
    check_transition(transition)
    assets = [legacy_feed]
    for arch in ARCHITECTURES:
        feed = Asset.read(directory / feed_name(arch))
        image = Asset.read(directory / f"Bark-{version}-{build}-macos-{arch}.dmg")
        check_appcast(feed, image, tag, version, build, ordinary=True)
        check_image(image, feed, arch, version, build)
        assets.extend((feed, image))
    if tag == TRANSITION_TAG:
        assets.append(transition)
    for asset in (*assets, transition):
        if Asset.read(asset.path) != asset:
            raise ValueError(f"{asset.path.name} changed during local verification.")
    return {asset.path.name: asset for asset in assets}, transition


class GitHub:
    @staticmethod
    def api(path, *args):
        return json.loads(subprocess.check_output(
            ["gh", "api", "--hostname", "github.com", f"repos/{REPOSITORY}{path}", *args],
            text=True))

    def latest(self):
        return self.api("/releases/latest")

    def find(self, tag):
        pages = self.api("/releases?per_page=100", "--paginate", "--slurp")
        matching = [release for page in pages for release in page if release["tag_name"] == tag]
        if len(matching) > 1:
            raise ValueError(f"More than one release claims {tag}.")
        return matching[0] if matching else None

    def assets(self, release):
        pages = self.api(f"/releases/{release['id']}/assets?per_page=100", "--paginate", "--slurp")
        entries = [asset for page in pages for asset in page]
        assets = {asset["name"]: asset for asset in entries}
        if len(entries) != len(assets):
            raise ValueError("GitHub returned duplicate release asset names.")
        return assets

    def require_release_commit(self, commit, *, tagged):
        default = self.api("")["default_branch"]
        remote_head = self.api(f"/git/ref/heads/{default}")["object"]["sha"]
        if remote_head == commit:
            return
        if not tagged:
            raise ValueError(f"The remote default branch {default} does not point at {commit}.")
        comparison = self.api(f"/compare/{commit}...{remote_head}?per_page=1")
        if comparison["status"] not in ("ahead", "identical"):
            raise ValueError(f"The tagged commit {commit} is not reachable from remote {default}.")

    @staticmethod
    def tag_commit(tag):
        ref = f"refs/tags/{tag}"
        output = subprocess.check_output(["git", "ls-remote", GITHUB + ".git", ref, ref + "^{}"], text=True)
        refs = {name: sha for sha, name in (line.split() for line in output.splitlines())}
        return refs.get(ref + "^{}", refs.get(ref))

    def create_draft(self, tag, commit, version, notes):
        return self.api("/releases", "--method", "POST",
                        "-f", f"tag_name={tag}", "-f", f"target_commitish={commit}",
                        "-f", f"name=Bark {version}", "-f", f"body={notes}",
                        "-F", "draft=true", "-f", "make_latest=false")

    @staticmethod
    def upload(tag, assets):
        subprocess.run(["gh", "release", "upload", tag, *(asset.path.resolve() for asset in assets),
                        "--repo", f"github.com/{REPOSITORY}"], check=True)

    @staticmethod
    def download(tag, name):
        return subprocess.check_output(["gh", "release", "download", tag, "--pattern", name,
                                        "--output", "-", "--repo", f"github.com/{REPOSITORY}"])

    def promote_latest(self, release):
        return self.api(f"/releases/{release['id']}", "--method", "PATCH",
                        "-F", "draft=false", "-f", "make_latest=true")


def check_remote_assets(github, release, expected, *, complete):
    tag = release["tag_name"]
    actual = github.assets(release)
    if actual.keys() - expected.keys() or (complete and actual.keys() != expected.keys()):
        raise ValueError(f"{tag} has an unexpected or incomplete GitHub asset set.")
    for name, asset in actual.items():
        expected[name].check_remote(asset, tag, published=not release["draft"])
    return [expected[name] for name in expected.keys() - actual.keys()]


def require_latest(github, previous):
    latest = github.latest()
    if latest["tag_name"] != previous:
        raise ValueError(f"Expected {previous} to be Latest; found {latest['tag_name']}.")
    return latest


def verify_previous_bark_release(github, latest, assets, transition, build):
    original = github.find(TRANSITION_TAG)
    if not original or original["draft"] or original["prerelease"]:
        raise ValueError("The original published transition release is unavailable.")
    original_assets = github.assets(original)
    legacy_feed = assets["appcast.xml"]
    legacy_feed.check_remote(original_assets["appcast.xml"], TRANSITION_TAG)
    transition.check_remote(original_assets[TRANSITION_NAME], TRANSITION_TAG)
    latest_assets = github.assets(latest)
    previous = latest["tag_name"]
    legacy_feed.check_remote(latest_assets["appcast.xml"], previous)
    for arch in ARCHITECTURES:
        name = feed_name(arch)
        content = github.download(previous, name)
        metadata = latest_assets[name]
        if (metadata["size"] != len(content)
                or metadata.get("digest") != "sha256:" + hashlib.sha256(content).hexdigest()):
            raise ValueError(f"The previous published {name} does not match GitHub's asset metadata.")
        _, item, _ = appcast_item(content)
        old_build = item.findtext(f"{{{SPARKLE}}}version")
        if not old_build or not old_build.isdecimal() or int(old_build) >= int(build):
            raise ValueError(f"The new build must advance the {arch} Sparkle build number.")


def publish(github, tag, commit, version, build, previous, notes, assets, transition):
    release = github.find(tag)
    tag_commit = github.tag_commit(tag)
    if tag_commit is not None and tag_commit != commit:
        raise ValueError(f"The GitHub tag {tag} points to another commit.")
    if release and not release["draft"]:
        if release["prerelease"] or tag_commit != commit:
            raise ValueError(f"{tag} is already published as a different release.")
        check_remote_assets(github, release, assets, complete=True)
        require_latest(github, tag)
        return

    latest = require_latest(github, previous)
    github.require_release_commit(commit, tagged=tag_commit is not None)
    if tag != TRANSITION_TAG:
        verify_previous_bark_release(github, latest, assets, transition, build)
    if release is None:
        release = github.create_draft(tag, commit, version, notes)
    if (not release["draft"] or release["prerelease"] or release["tag_name"] != tag
            or release["target_commitish"] != commit or release["body"] != notes):
        raise ValueError(f"Existing draft {tag} does not match the requested release.")

    missing = check_remote_assets(github, release, assets, complete=False)
    if missing:
        github.upload(tag, sorted(missing, key=lambda asset: asset.path.name))
    check_remote_assets(github, release, assets, complete=True)
    require_latest(github, previous)
    final_tag_commit = github.tag_commit(tag)
    if final_tag_commit not in (None, commit) or (tag_commit is not None and final_tag_commit is None):
        raise ValueError(f"The GitHub tag {tag} changed before publication.")
    github.require_release_commit(commit, tagged=final_tag_commit is not None)
    updated = github.promote_latest(release)
    if updated["draft"] or updated["prerelease"] or updated["tag_name"] != tag:
        raise ValueError("GitHub did not return the published Bark release.")
    check_remote_assets(github, updated, assets, complete=True)
    require_latest(github, tag)
    if github.tag_commit(tag) != commit:
        raise ValueError(f"The published GitHub tag {tag} does not point to the verified commit.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path, help="Both native DMGs and three appcasts")
    parser.add_argument("--transition-image", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True, help="Release tag commit or exact GitHub default tip in this checkout")
    parser.add_argument("--previous-latest", required=True, help="The expected current Latest release tag")
    parser.add_argument("--notes", required=True, type=Path, help="Reviewed release notes file")
    parser.add_argument("--publish", action="store_true", help="Upload a draft and promote after verification")
    args = parser.parse_args(argv)
    try:
        check_versions(args.version, args.build)
        tag = f"bark-v{args.version}"
        version = tuple(map(int, args.version.split(".")))
        if len(version) != 3 or version < (2, 0, 0) or args.version != ".".join(map(str, version)):
            raise ValueError("Bark release versions must use X.Y.Z starting at 2.0.0.")
        if (tag == TRANSITION_TAG and (args.previous_latest != LEGACY_TAG or args.build != "202611200002")
                or tag != TRANSITION_TAG and (not re.fullmatch(r"bark-v\d+\.\d+\.\d+", args.previous_latest)
                                              or int(args.build) <= 202611200002
                                              or tuple(map(int, args.previous_latest[6:].split("."))) >= version)):
            raise ValueError("The Bark release must advance the expected Latest version and transition build.")
        head = subprocess.check_output(["git", "-C", REPO, "rev-parse", "HEAD"], text=True).strip()
        if args.commit != head:
            raise ValueError("The requested release commit differs from the checked-out HEAD.")
        if subprocess.check_output(["git", "-C", REPO, "status", "--porcelain"], text=True).strip():
            raise ValueError("Use a clean checkout of the release commit.")
        notes = args.notes.read_text().strip()
        if not notes:
            raise ValueError("Release notes are empty.")
        assets, transition = prepare_assets(args.directory, args.transition_image, tag, args.version, args.build)
        if args.publish:
            publish(GitHub(), tag, args.commit, args.version, args.build, args.previous_latest,
                    notes, assets, transition)
            print(f"Verified Latest: {GITHUB}/releases/tag/{tag}")
        else:
            print(f"Verified {len(assets)} local assets for {tag}.")
    except (ET.ParseError, OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
