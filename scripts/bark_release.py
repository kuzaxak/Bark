# Licensed under GPL-3.0. See LICENSE.
"""Release metadata for the signed Bark application and its Sparkle feed."""

from pathlib import Path
import base64
import ctypes
import json
import os
import plistlib
import re
import subprocess
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit
from uuid import UUID
import xml.etree.ElementTree as ET


REPO = Path(__file__).resolve().parents[1]
HANDLER_KEYS = ("CFBundleURLTypes", "CFBundleDocumentTypes", "NSUserActivityTypes",
                "ASWebAuthenticationSessionWebBrowserSupportCapabilities",
                "UTExportedTypeDeclarations", "UTImportedTypeDeclarations")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
TEAM = "538SB59LX4"


def feed_name(architecture):
    return f"bark-macos-{architecture}.xml"


def check_versions(version, build):
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise ValueError("Supply a numeric Bark --release-version, for example 1.4.0.2.")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Supply a positive, monotonically increasing --build-number.")


def update_url(value):
    if not value or re.search(r"[\s\\\x00-\x1f\x7f]", value):
        raise ValueError("Invalid update feed or archive URL.")
    url = urlsplit(value)
    # Reading .port also rejects non-numeric and out-of-range ports.
    if (not url.hostname or url.username is not None or url.password is not None
            or url.port == 0 or url.query or url.fragment):
        raise ValueError("Invalid update feed or archive URL.")
    return url


def production_settings(version, build, feed_base, architecture):
    if version is None and build is None and feed_base is None:
        return None
    check_versions(version, build)
    if update_url(feed_base).scheme != "https":
        raise ValueError("Supply an HTTPS directory URL with --feed-base-url.")
    # Nook and Bark releases share the owner's update signing identity. Each
    # Bark architecture follows its own appcast, including across engine bumps.
    with (REPO / "Nook/Info.plist").open("rb") as file:
        public_key = plistlib.load(file)["SUPublicEDKey"]
    return {
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "SUPublicEDKey": public_key,
        "SUFeedURL": feed_base.rstrip("/") + "/" + feed_name(architecture),
        "SUVerifyUpdateBeforeExtraction": True,
        "SUEnableAutomaticChecks": True,
    }


def configure_release(app, settings):
    """Apply app-owned release metadata to the staged bundle before signing."""
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info["BarkChromiumVersion"] = info["CFBundleShortVersionString"]
    info.update(settings)
    if "BarkUpdateRehearsal" in settings:
        # A separately identified rehearsal app never advertises web or
        # document handlers in the developer's Launch Services database.
        for key in HANDLER_KEYS:
            info.pop(key, None)
    path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))


def expected_additions(settings, working):
    original = REPO / "ChromiumApp/Additions.plist"
    if not settings:
        return original
    additions = plistlib.loads(original.read_bytes())
    if "BarkUpdateRehearsal" in settings:
        for key in HANDLER_KEYS:
            additions["Info"].pop(key, None)
    additions["Info"].update(settings)
    path = working / "release-additions.plist"
    path.write_bytes(plistlib.dumps(additions))
    return path


def check_distribution_settings(info, architecture, download_base):
    bundle_id = info.get("CFBundleIdentifier", "")
    version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
    check_versions(version, build)
    feed = update_url(info.get("SUFeedURL", ""))
    download = update_url(download_base)
    if not feed.path.endswith("/" + feed_name(architecture)):
        raise ValueError(f"The app must follow {feed_name(architecture)}.")
    if not info.get("LSMinimumSystemVersion"):
        raise ValueError("The signed app is missing its minimum macOS version.")
    if info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise ValueError("The app must authenticate updates before extraction.")
    if bundle_id == "ee.qdo.bark":
        expected = production_settings(version, build, info["SUFeedURL"].rsplit("/", 1)[0], architecture)
        if any(info.get(key) != value for key, value in expected.items()) or download.scheme != "https":
            raise ValueError("The app needs the signed production update settings and HTTPS archive URL.")
    elif bundle_id.startswith("ee.qdo.bark.test."):
        UUID(bundle_id.removeprefix("ee.qdo.bark.test."))
        if ("BarkUpdateRehearsal" not in info or any(key in info for key in HANDLER_KEYS)
                or info.get("SUEnableAutomaticChecks") is not False
                or feed.scheme != "http" or feed.hostname != "127.0.0.1" or not feed.port
                or (feed.scheme, feed.netloc) != (download.scheme, download.netloc)):
            raise ValueError("Rehearsal archives require the signed disposable app and its loopback server.")
    else:
        raise ValueError(f"Unexpected app identity for a Bark update: {bundle_id}")
    if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
        raise ValueError("The signed app must contain an Ed25519 update public key.")
    return bundle_id, version, build


def notarize(artifact, upload, profile):
    response = subprocess.check_output(["xcrun", "notarytool", "submit", upload, "--keychain-profile", profile,
                                        "--wait", "--output-format", "json"], text=True)
    submission = json.loads(response)
    if submission.get("status") != "Accepted":
        raise ValueError(f"Notarization {submission.get('id')} returned {submission.get('status')}.")
    subprocess.run(["xcrun", "stapler", "staple", artifact], check=True)
    subprocess.run(["xcrun", "stapler", "validate", artifact], check=True)


def write_appcast(path, info, url, size, signature):
    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Bark"
    ET.SubElement(channel, "link").text = info["SUFeedURL"]
    ET.SubElement(channel, "description").text = "Bark for macOS"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Bark " + info["CFBundleShortVersionString"]
    for element, key in (("version", "CFBundleVersion"), ("shortVersionString", "CFBundleShortVersionString"),
                         ("minimumSystemVersion", "LSMinimumSystemVersion")):
        ET.SubElement(item, f"{{{SPARKLE}}}{element}").text = info[key]
    ET.SubElement(item, "enclosure", {"url": url, "length": str(size), "type": "application/octet-stream",
                                      f"{{{SPARKLE}}}edSignature": signature})
    ET.indent(rss)
    ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)


def make_distribution(app, output_directory, architecture, identity, download_base_url, sparkle_bin,
                      ed_key_file, working, notary_profile=None, verify_staged=None):
    """Publish a complete local DMG and appcast directory only after both signatures verify."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    bundle_id, version, build = check_distribution_settings(info, architecture, download_base_url)
    if not identity:
        raise ValueError("Supply a Developer ID identity for signing the disk image.")
    requirement = (f'=anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    output_directory = Path(output_directory).absolute()
    if os.path.lexists(output_directory):
        raise ValueError(f"Choose a new distribution output directory: {output_directory}")
    if sparkle_bin is None:
        packages = working / "SourcePackages"
        subprocess.run(["xcodebuild", "-resolvePackageDependencies", "-project", REPO / "Nook.xcodeproj",
                        "-scheme", "NookNativeShell", "-onlyUsePackageVersionsFromResolvedFile",
                        "-derivedDataPath", working / "DerivedData", "-clonedSourcePackagesDirPath", packages],
                       check=True)
        sparkle_bin = packages / "artifacts/sparkle/Sparkle/bin"
    output_directory.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix=".bark-release-", dir=output_directory.parent) as stage:
        stage = Path(stage)
        volume, published = stage / "volume", stage / "release"
        volume.mkdir()
        published.mkdir()
        installed = volume / "Bark.app"
        subprocess.run(["/usr/bin/ditto", app, installed], check=True)
        if plistlib.loads((installed / "Contents/Info.plist").read_bytes()) != info:
            raise ValueError("The source app changed while the release was being staged.")
        framework_info = installed / "Contents/Frameworks/Bark Framework.framework/Resources/Info.plist"
        if info.get("BarkChromiumVersion") != plistlib.loads(framework_info.read_bytes())["CFBundleShortVersionString"]:
            raise ValueError("The declared Chromium version differs from the embedded engine.")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R",
                        requirement + f' and identifier "{bundle_id}"', installed], check=True)
        if verify_staged:
            verify_staged(installed)
        if notary_profile:
            upload = stage / "app.zip"
            subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", installed, upload], check=True)
            notarize(installed, upload, notary_profile)
            upload.unlink()
        (volume / "Applications").symlink_to("/Applications")
        image = published / f"Bark-{version}-{build}-macos-{architecture}.dmg"
        size_kib = int(subprocess.check_output(["du", "-sk", volume]).split()[0])
        subprocess.run(["hdiutil", "create", "-volname", f"Bark {version}", "-srcfolder", volume, "-format", "UDZO",
                        "-size", f"{size_kib * 12 // 10 + 20480}k", image], check=True)
        subprocess.run(["codesign", "--force", "--timestamp", "--sign", identity, image], check=True)
        subprocess.run(["codesign", "--verify", "--strict", "-R", requirement, image], check=True)
        if notary_profile:
            notarize(image, image, notary_profile)
        signature = subprocess.check_output([Path(sparkle_bin) / "sign_update", "--ed-key-file", ed_key_file,
                                              "-p", image], text=True).strip()
        subprocess.run(["xcrun", "swift", REPO / "scripts/VerifyBarkUpdate.swift", image, info["SUPublicEDKey"],
                        signature], check=True)
        write_appcast(published / feed_name(architecture), info, download_base_url.rstrip("/") + "/" + image.name,
                      image.stat().st_size, signature)
        # Atomically publish both files, even if two jobs target the same path.
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        if rename(os.fsencode(published), os.fsencode(output_directory), 0x00000004):  # RENAME_EXCL
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), output_directory)
    print(f"Packaged {output_directory / image.name} and {feed_name(architecture)}", flush=True)
