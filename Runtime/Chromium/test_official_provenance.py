"""Test the official SDK receipt binding without an official toolchain."""
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import build_engine
import official_provenance as provenance


class OfficialProvenanceTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.arch = "x86_64"
        self.src = self.root / "src"
        self.out = self.src / "out/Barc-x64-official"
        self.artifact = self.out / "Bark.app/Contents/Frameworks"
        framework = self.artifact / provenance.FRAMEWORK / "Versions/Current"
        self.info = framework / "Resources/Info.plist"
        self.info.parent.mkdir(parents=True)
        self.image = framework / "Bark Framework"
        self.image.write_bytes(b"linked framework")
        sdk = provenance.PINS["official_macos_sdk"]
        self.info.write_bytes(plistlib.dumps({
            "DTSDKName": "macosx" + sdk["version"],
            "DTSDKBuild": sdk["build"],
            "CFBundleShortVersionString": provenance.CHROMIUM_VERSION,
            "SCMRevision": provenance.PINS["chromium"] + "-refs/branch-heads/8078@{#1705}",
        }))
        (self.out / "args.gn").write_bytes(build_engine.engine_args("x64", True))
        self.pin = provenance.PINS["official_pgo_profiles"]["mac"]
        self.profile = self.src / "chrome/build/pgo_profiles" / self.pin
        self.profile.parent.mkdir(parents=True)
        (self.profile.parent.parent / "mac.pgo.txt").write_text(self.pin + "\n")
        self.profile.write_bytes(b"pinned PGO")
        self.profile_flag = f"-fprofile-use={self.profile}"
        self.recorded_hash = provenance.digest(self.profile)
        pins = patch.dict(provenance.PINS, {"official_pgo_sha256": {"mac": self.recorded_hash}})
        pins.start()
        self.addCleanup(pins.stop)
        self.recorded_time = self.image.stat().st_mtime_ns
        self.browser_object = self.out / provenance.BROWSER_OBJECT
        self.browser_object.parent.mkdir(parents=True)
        self.browser_object.write_bytes(b"profiled browser object")
        self.linked = self.out / provenance.RAW_FRAMEWORK_IMAGE
        self.linked.parent.mkdir(parents=True)
        self.linked.write_bytes(self.image.read_bytes())
        self.browser_time = self.browser_object.stat().st_mtime_ns
        self.include_browser_compile = True
        mock = patch.object(provenance.subprocess, "check_output", side_effect=self.tools)
        mock.start()
        self.addCleanup(mock.stop)

    def tools(self, command, **kwargs):
        tool = Path(command[0]).name
        if tool == "gn":
            return self.profile_flag
        if tool == "siso":
            entries = [{"name": str(self.profile), "digest": {"hash": self.recorded_hash},
                        "id": {"mod_time": self.recorded_time}}]
            if self.include_browser_compile:
                entries.append({"name": str(self.browser_object), "digest": {"hash": provenance.digest(self.browser_object)},
                                "id": {"mod_time": self.browser_time}, "cmd_hash": "command", "edge_hash": "edge"})
            return json.dumps({"entries": entries})
        if tool == "lipo":
            return self.arch + "\n"
        sdk = provenance.PINS["official_macos_sdk"]["version"]
        return f"cmd LC_BUILD_VERSION\n cmdsize 32\n platform 1\n minos 13.0\n sdk {sdk}\n"

    def sealed_receipt(self):
        data = provenance.record(self.out, self.src, self.arch, {})
        receipt = self.artifact / provenance.RECEIPT
        receipt.write_text(json.dumps(data))
        (self.artifact / "SHA256SUMS").write_text(f"{provenance.digest(receipt)}  ./{provenance.RECEIPT}\n")
        return receipt

    def test_pinned_receipt_and_framework_pass(self):
        self.sealed_receipt()
        provenance.verify_cached(self.artifact, self.arch)

    def test_receipt_for_different_framework_is_refused(self):
        self.sealed_receipt()
        self.image.write_bytes(b"another framework")
        with self.assertRaisesRegex(ValueError, "does not match"):
            provenance.verify_cached(self.artifact, self.arch)

    def test_receipt_must_be_sealed_by_manifest(self):
        self.sealed_receipt()
        (self.artifact / "SHA256SUMS").write_text("")
        with self.assertRaisesRegex(ValueError, "missing from"):
            provenance.verify_cached(self.artifact, self.arch)

    def test_developer_plist_is_refused(self):
        self.sealed_receipt()
        info = plistlib.loads(self.info.read_bytes())
        info.update(DTSDKName="macosx26.2", DTSDKBuild="25C58")
        self.info.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "framework reports macosx26.2"):
            provenance.verify_cached(self.artifact, self.arch)

    def test_publication_rechecks_build_outputs(self):
        receipt = self.out / provenance.RECEIPT
        receipt.write_text(self.sealed_receipt().read_text())
        provenance.verify_publication(self.out, self.arch, {})
        data = json.loads(receipt.read_text())
        data["pgo_sha256"] = "0" * 64
        receipt.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "direct build outputs"):
            provenance.verify_publication(self.out, self.arch, {})

    def test_other_chromium_revision_is_refused(self):
        self.sealed_receipt()
        info = plistlib.loads(self.info.read_bytes())
        info["SCMRevision"] = "0" * 40
        self.info.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "revision"):
            provenance.verify_cached(self.artifact, self.arch)

    def test_wrong_cached_profile_fails_despite_matching_siso_evidence(self):
        self.profile.write_bytes(b"unrelated PGO with the pinned name")
        self.recorded_hash = provenance.digest(self.profile)
        with self.assertRaisesRegex(ValueError, "PGO profile SHA-256 differs"):
            provenance.verify_pgo_profile(self.src, "mac")
        with self.assertRaisesRegex(ValueError, "PGO profile SHA-256 differs"):
            provenance.record(self.out, self.src, self.arch, {})

    def test_wrong_receipt_profile_digest_fails_even_when_sealed(self):
        receipt = self.sealed_receipt()
        data = json.loads(receipt.read_text())
        data["pgo_sha256"] = "0" * 64
        receipt.write_text(json.dumps(data))
        (self.artifact / "SHA256SUMS").write_text(f"{provenance.digest(receipt)}  ./{provenance.RECEIPT}\n")
        with self.assertRaisesRegex(ValueError, "does not match"):
            provenance.verify_cached(self.artifact, self.arch)

    def test_browser_compile_must_exist_and_predate_raw_link(self):
        self.include_browser_compile = False
        with self.assertRaisesRegex(ValueError, "no matching Siso browser compile"):
            provenance.record(self.out, self.src, self.arch, {})
        self.include_browser_compile = True
        os.utime(self.linked, ns=(self.browser_time - 1, self.browser_time - 1))
        with self.assertRaisesRegex(ValueError, "no matching Siso browser compile"):
            provenance.record(self.out, self.src, self.arch, {})

    def test_packaged_framework_must_match_raw_link(self):
        self.linked.write_bytes(b"another linked image")
        with self.assertRaisesRegex(ValueError, "differs from the raw linked image"):
            provenance.record(self.out, self.src, self.arch, {})

    def test_unrecorded_or_unconfigured_pgo_is_refused(self):
        self.recorded_hash = "0" * 64
        with self.assertRaisesRegex(ValueError, "no matching Siso"):
            provenance.record(self.out, self.src, self.arch, {})
        self.profile_flag = "-fprofile-use=another.profdata"
        with self.assertRaisesRegex(ValueError, "does not use"):
            provenance.record(self.out, self.src, self.arch, {})


if __name__ == "__main__":
    unittest.main()
