# Licensed under GPL-3.0. See LICENSE.
"""Verify the linked images in a packaged Bark browser-test runtime."""

import hashlib
import json
from pathlib import Path

MANIFEST_NAME = "bark-test-runtime.json"
FIXTURE = "bark/test/barc_bridge_browsertest.mm"
TEST_FRAMEWORK = Path("Bark Framework.framework/Versions/Current/Bark Framework")
APP_FRAMEWORK = Path("Bark.app/Contents/Frameworks") / TEST_FRAMEWORK


def digest_regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected regular test runtime file: {path}")
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
        return digest.hexdigest()


def matching_framework_digest(build):
    framework = digest_regular(build / TEST_FRAMEWORK)
    if digest_regular(build / APP_FRAMEWORK) != framework:
        raise ValueError("Browser-test and embedded app framework binaries differ")
    return framework


def create_manifest(binary, mounted_fixture=None):
    result = {"format": 2, "executable_sha256": digest_regular(binary),
              "framework_sha256": matching_framework_digest(binary.parent)}
    if mounted_fixture is not None:
        # Measure the installed overlay at export. This is not a compiler input receipt.
        result["installed_fixture_sha256"] = digest_regular(mounted_fixture)
    return result


def verify_manifest(binary, expected_fixture=None):
    manifest = binary.parent / MANIFEST_NAME
    if not manifest.exists() and not manifest.is_symlink():
        if expected_fixture is not None:
            raise ValueError("Expected a packaged browser-test fixture manifest")
        return matching_framework_digest(binary.parent)
    if manifest.is_symlink() or not manifest.is_file():
        raise ValueError(f"Expected a regular browser-test manifest: {manifest}")
    record = json.loads(manifest.read_text())
    if not isinstance(record, dict) or type(record.get("format")) is not int or record["format"] not in (1, 2):
        raise ValueError("Unsupported browser-test runtime manifest")
    if record.get("executable_sha256") != digest_regular(binary):
        raise ValueError("Browser-test executable differs from its archived SHA-256")
    if expected_fixture is not None and record.get("installed_fixture_sha256") != digest_regular(expected_fixture):
        raise ValueError("Archived installed browser-test fixture differs from the expected source")
    framework = matching_framework_digest(binary.parent)
    if record["format"] == 2 and record.get("framework_sha256") != framework:
        raise ValueError("Browser-test framework differs from its archived SHA-256")
    return framework
