# Licensed under GPL-3.0. See LICENSE.
"""Verify the executable identity in a packaged Bark browser-test runtime."""

import hashlib
import json

MANIFEST_NAME = "bark-test-runtime.json"
FIXTURE = "bark/test/barc_bridge_browsertest.mm"


def digest_regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected regular test runtime file: {path}")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def create_manifest(binary, mounted_fixture=None):
    result = {"format": 1, "executable_sha256": digest_regular(binary)}
    if mounted_fixture is not None:
        # Measure the installed overlay at export. This is not a compiler input receipt.
        result["installed_fixture_sha256"] = digest_regular(mounted_fixture)
    return result


def verify_manifest(binary, expected_fixture=None):
    manifest = binary.parent / MANIFEST_NAME
    if not manifest.exists() and not manifest.is_symlink():
        if expected_fixture is not None:
            raise ValueError("Expected a packaged browser-test fixture manifest")
        return
    if manifest.is_symlink() or not manifest.is_file():
        raise ValueError(f"Expected a regular browser-test manifest: {manifest}")
    record = json.loads(manifest.read_text())
    if not isinstance(record, dict) or type(record.get("format")) is not int or record["format"] != 1:
        raise ValueError("Unsupported browser-test runtime manifest")
    if record.get("executable_sha256") != digest_regular(binary):
        raise ValueError("Browser-test executable differs from its archived SHA-256")
    if expected_fixture is not None and record.get("installed_fixture_sha256") != digest_regular(expected_fixture):
        raise ValueError("Archived installed browser-test fixture differs from the expected source")
