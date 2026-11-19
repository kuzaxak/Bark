# Licensed under GPL-3.0. See LICENSE.
"""Verify the linked images in a packaged Bark browser-test runtime."""

import json
import re
import subprocess
from pathlib import Path

from chromium_sdk_layout import FRAMEWORK_BINARY, file_digest


MANIFEST_NAME = "bark-test-runtime.json"
FIXTURE = "bark/test/barc_bridge_browsertest.mm"
TEST_FRAMEWORK = FRAMEWORK_BINARY
APP_FRAMEWORK = Path("Bark.app/Contents/Frameworks") / TEST_FRAMEWORK


def digest_regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected regular test runtime file: {path}")
    return file_digest(path)


def matching_framework_digest(build):
    framework = digest_regular(build / TEST_FRAMEWORK)
    if digest_regular(build / APP_FRAMEWORK) != framework:
        raise ValueError("Browser-test and embedded app framework binaries differ")
    return framework


INVENTORY_NAME = "browser_test_sources.json"
RECEIPT_INPUTS = ("BUILD.gn", INVENTORY_NAME, "write_source_receipt.py")


def valid_fixture_name(name):
    return isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+", name)


def fixture_digests(directory):
    inventory = directory / INVENTORY_NAME
    if inventory.is_symlink() or not inventory.is_file():
        raise ValueError("Expected the Bark browser-test source inventory")
    record = json.loads(inventory.read_text())
    if (not isinstance(record, dict) or record.keys() != {"sources", "support"}
            or not all(isinstance(value, list) for value in record.values()) or not record["sources"]):
        raise ValueError("Invalid Bark browser-test source inventory")
    names = [*RECEIPT_INPUTS, *record["sources"], *record["support"]]
    if not all(valid_fixture_name(name) for name in names) or len(names) != len(set(names)):
        raise ValueError("Invalid Bark browser-test source names")
    return {name: digest_regular(directory / name) for name in names}


def linked_test_sources(binary):
    """Read the test source receipt from the linked Mach-O without launching it."""
    command = ["/usr/bin/otool", "-s", "__TEXT", "__barktestsrc", binary]
    contents = subprocess.check_output(command, text=True).splitlines()
    arch = subprocess.check_output(["/usr/bin/lipo", "-archs", binary], text=True).strip()
    if (arch not in ("arm64", "x86_64") or len(contents) < 3
            or contents[1] != "Contents of (__TEXT,__barktestsrc) section"):
        raise ValueError("Missing linked Bark browser-test source receipt")
    try:
        words = (bytes.fromhex(word) for line in contents[2:] for word in line.split()[1:])
        data = b"".join(word[::-1] if arch == "arm64" else word for word in words)
        if not data.endswith(b"\0"):
            raise ValueError("Unterminated test source receipt")
        record = json.loads(data[:-1])
        if (not isinstance(record, dict) or not set(RECEIPT_INPUTS) <= record.keys()
                or not all(valid_fixture_name(name)
                           and isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)
                           for name, digest in record.items())):
            raise ValueError("Invalid linked test source inventory")
    except (UnicodeError, ValueError) as error:
        raise ValueError("Invalid linked Bark browser-test source receipt") from error
    return record


def verify_test_sources(binary, expected):
    linked = linked_test_sources(binary)
    changed = sorted(name for name in linked.keys() | expected.keys()
                     if linked.get(name) != expected.get(name))
    if changed:
        raise ValueError(f"Linked browser-test sources differ: {', '.join(changed)}")
    return linked


def create_manifest(binary, mounted_fixture=None, expected_tree=None):
    result = {"format": 2, "executable_sha256": digest_regular(binary),
              "framework_sha256": matching_framework_digest(binary.parent)}
    if expected_tree is not None:
        result["format"] = 3
        result["linked_test_sources"] = verify_test_sources(binary, fixture_digests(expected_tree))
    if mounted_fixture is not None:
        # Measure the installed overlay at export. This is not a compiler input receipt.
        result["installed_fixture_sha256"] = digest_regular(mounted_fixture)
    return result


def verify_manifest(binary, expected_fixture=None, expected_tree=None):
    manifest = binary.parent / MANIFEST_NAME
    if not manifest.exists() and not manifest.is_symlink():
        if expected_fixture is not None or expected_tree is not None:
            raise ValueError("Expected a packaged browser-test fixture manifest")
        return matching_framework_digest(binary.parent)
    if manifest.is_symlink() or not manifest.is_file():
        raise ValueError(f"Expected a regular browser-test manifest: {manifest}")
    record = json.loads(manifest.read_text())
    if not isinstance(record, dict) or type(record.get("format")) is not int or record["format"] not in (1, 2, 3):
        raise ValueError("Unsupported browser-test runtime manifest")
    if record.get("executable_sha256") != digest_regular(binary):
        raise ValueError("Browser-test executable differs from its archived SHA-256")
    if expected_fixture is not None and record.get("installed_fixture_sha256") != digest_regular(expected_fixture):
        raise ValueError("Archived installed browser-test fixture differs from the expected source")
    if expected_tree is not None and record["format"] != 3:
        raise ValueError("Exact qualification requires the linked browser-test source receipt")
    if record["format"] == 3:
        linked = (verify_test_sources(binary, fixture_digests(expected_tree))
                  if expected_tree is not None else linked_test_sources(binary))
        if record.get("linked_test_sources") != linked:
            raise ValueError("Archived browser-test source receipt differs from the linked executable")
    framework = matching_framework_digest(binary.parent)
    if record["format"] >= 2 and record.get("framework_sha256") != framework:
        raise ValueError("Browser-test framework differs from its archived SHA-256")
    return framework
