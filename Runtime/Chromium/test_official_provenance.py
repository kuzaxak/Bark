"""Test the official SDK receipt binding without an official toolchain."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import DEFAULT, Mock, patch

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
        self.v8_profile = self.src / provenance.V8_BUILTINS_PROFILE
        self.v8_profile.parent.mkdir(parents=True)
        self.v8_profile.write_bytes(b"synthetic V8 builtins PGO")
        self.v8_revision = provenance.PINS["official_v8_builtins"]["revision"]
        v8_pin = {**provenance.PINS["official_v8_builtins"], "sha256": provenance.digest(self.v8_profile)}
        pins = patch.dict(provenance.PINS, {
            "official_pgo_sha256": {"mac": self.recorded_hash}, "official_v8_builtins": v8_pin,
        })
        pins.start()
        self.addCleanup(pins.stop)
        self.recorded_time = self.image.stat().st_mtime_ns
        self.browser_object = self.out / provenance.BROWSER_OBJECT
        self.browser_object.parent.mkdir(parents=True)
        self.browser_object.write_bytes(b"profiled browser object")
        self.linked = self.out / provenance.RAW_FRAMEWORK_IMAGE
        self.linked.parent.mkdir(parents=True)
        self.linked.write_bytes(self.image.read_bytes())
        self.link_entry = {
            "name": str(self.linked), "digest": {"hash": provenance.digest(self.linked)},
            "id": {"mod_time": self.linked.stat().st_mtime_ns}, "cmd_hash": "link command", "edge_hash": "link edge",
        }
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
            if self.link_entry:
                entries.append(self.link_entry)
            return json.dumps({"entries": entries})
        if tool == "git":
            self.assertEqual(command[1:], ["-C", self.src / "v8", "rev-parse", "HEAD"])
            return self.v8_revision + "\n"
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

    def test_old_receipt_lacks_the_link_bound_format(self):
        receipt = self.sealed_receipt()
        data = json.loads(receipt.read_text())
        data["format"] = 2
        receipt.write_text(json.dumps(data))
        (self.artifact / "SHA256SUMS").write_text(f"{provenance.digest(receipt)}  ./{provenance.RECEIPT}\n")
        with self.assertRaisesRegex(ValueError, "does not match the pinned recipe"):
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

    def test_bad_cached_profile_is_quarantined_for_one_verified_download(self):
        bad = b"partial download at the pinned name"
        self.profile.write_bytes(bad)
        calls = []

        def update():
            calls.append(self.profile.exists())
            if not self.profile.exists():
                self.profile.write_bytes(b"pinned PGO")

        self.assertEqual(provenance.acquire_pgo_profile(self.src, "mac", update), self.profile)
        self.assertEqual(calls, [True, False])
        rejected, = self.profile.parent.parent.glob(f".bark-rejected-pgo-*/{self.pin}")
        self.assertEqual(rejected.read_bytes(), bad)

        self.assertEqual(provenance.acquire_pgo_profile(self.src, "mac", update), self.profile)
        self.assertEqual(calls, [True, False, True])
        self.assertEqual(list(self.profile.parent.parent.glob(f".bark-rejected-pgo-*/{self.pin}")), [rejected])

    def test_failed_replacement_preserves_quarantine_and_next_attempt_can_download(self):
        self.profile.write_bytes(b"bad cached bytes")
        calls = []

        def interrupted():
            calls.append(self.profile.exists())
            if not self.profile.exists():
                raise InterruptedError("download failed")

        with self.assertRaisesRegex(InterruptedError, "download failed"):
            provenance.acquire_pgo_profile(self.src, "mac", interrupted)
        self.assertEqual(calls, [True, False])
        self.assertFalse(self.profile.exists())
        rejected, = self.profile.parent.parent.glob(f".bark-rejected-pgo-*/{self.pin}")
        self.assertEqual(rejected.read_bytes(), b"bad cached bytes")
        self.assertEqual(provenance.acquire_pgo_profile(
            self.src, "mac", lambda: self.profile.write_bytes(b"pinned PGO")), self.profile)

    def test_new_wrong_bytes_are_never_accepted_or_downloaded_repeatedly(self):
        self.profile.unlink()
        calls = []

        def invalid_download():
            calls.append(self.profile.exists())
            self.profile.write_bytes(b"wrong replacement")

        with self.assertRaisesRegex(ValueError, "SHA-256 differs"):
            provenance.acquire_pgo_profile(self.src, "mac", invalid_download)
        self.assertEqual(calls, [False])
        with self.assertRaisesRegex(ValueError, "SHA-256 differs"):
            provenance.acquire_pgo_profile(self.src, "mac", invalid_download)
        self.assertEqual(calls, [False, True, False])
        self.assertEqual(self.profile.read_bytes(), b"wrong replacement")

    def test_unexpected_cache_file_types_do_not_reach_updater(self):
        self.profile.unlink()
        self.profile.symlink_to(self.src / "missing")
        update = lambda: self.fail("an unexpected cache entry reached the updater")
        with self.assertRaisesRegex(ValueError, "regular PGO cache file"):
            provenance.acquire_pgo_profile(self.src, "mac", update)
        self.assertTrue(self.profile.is_symlink())
        self.profile.unlink()
        self.profile.mkdir()
        with self.assertRaisesRegex(ValueError, "regular PGO cache file"):
            provenance.acquire_pgo_profile(self.src, "mac", update)
        self.assertTrue(self.profile.is_dir())
        self.profile.rmdir()
        self.profile.with_name(self.pin + ".lock").symlink_to(self.src / "missing")
        with self.assertRaisesRegex(ValueError, "regular PGO cache file"):
            provenance.acquire_pgo_profile(self.src, "mac", update)

    def test_source_receipt_matches_a_relocated_recipe_and_rejects_runtime_drift(self):
        paths = (
            "Runtime/Chromium/bark/tools/override_cc.c",
            "Runtime/Chromium/bark/browser/runtime.cc",
            "Runtime/Chromium/chromium_src/override.cc",
            "Runtime/Chromium/patches/chrome/foo.cc.patch",
            "Runtime/Chromium/official_pgo.star",
            "Runtime/Chromium/checkout.gclient",
            "Packages/NookBlocker/Sources/scriptlets.json",
            "Nook/ThirdParty/AdblockRustFFI/Cargo.toml",
            "Nook/ThirdParty/AdblockRustFFI/Cargo.lock",
            "Nook/ThirdParty/AdblockRustFFI/nook_adblock.exports",
            "Nook/ThirdParty/AdblockRustFFI/src/lib.rs",
        )
        producer = self.root / "producer"
        receiver = self.root / "receiver"
        for name in paths:
            path = producer / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        resource = producer / "Runtime/Chromium/bark/scriptlets.json"
        resource.symlink_to("../../../Packages/NookBlocker/Sources/scriptlets.json")
        shutil.copytree(producer, receiver, symlinks=True)

        @contextmanager
        def use_source(root):
            runtime = root / "Runtime/Chromium"
            mounts = {name: runtime / name for name in ("bark", "chromium_src")}
            with patch.multiple(build_engine, REPO=root, MOUNTS=mounts, PATCHES=runtime / "patches"), (
                    patch.object(provenance, "HERE", runtime)):
                yield

        with use_source(producer):
            self.sealed_receipt()

        with use_source(receiver):
            for relative in ("README.md", "App/Chromium/Shell.swift",
                             "build/Barc-x64/temporary.o", "Runtime/Chromium/bark/test/fixture.mm"):
                path = receiver / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("unrelated fixture")
            provenance.verify_cached(self.artifact, self.arch)
            for name in paths:
                with self.subTest(name=name):
                    path = receiver / name
                    path.write_text("changed runtime fixture")
                    with self.assertRaisesRegex(ValueError, "does not match"):
                        provenance.verify_cached(self.artifact, self.arch)
                    path.write_text(name)

    def test_official_build_refuses_receipt_after_source_changes(self):
        (self.src / "build/config/siso").mkdir(parents=True)
        sdk_pin = provenance.PINS["official_macos_sdk"]
        sdk = self.root / f"MacOSX{sdk_pin['version']}.sdk"
        system = sdk / "System/Library/CoreServices/SystemVersion.plist"
        system.parent.mkdir(parents=True)
        system.write_bytes(plistlib.dumps({
            "ProductVersion": sdk_pin["version"], "ProductBuildVersion": sdk_pin["build"],
        }))
        (sdk / "SDKSettings.json").write_text(json.dumps({
            "Version": sdk_pin["version"], "CanonicalName": "macosx" + sdk_pin["version"],
        }))
        options = argparse.Namespace(arch="x64", official=True, dry_run=False, jobs=1, macos_sdk=sdk)
        with patch.multiple(build_engine, verify_gclient=DEFAULT,
                            repository=DEFAULT, replay=DEFAULT,
                            run=DEFAULT,
                            install_generated=DEFAULT), patch.object(
                                provenance, "engine_source_digest", return_value="before"), patch.object(
                                provenance, "record", return_value={"engine_source_sha256": "after"}) as record:
            with self.assertRaisesRegex(ValueError, "source recipe changed"):
                build_engine.build(self.root, self.root / "depot_tools", {}, options)
        self.assertEqual(record.call_args.args[3]["SDKROOT"], str(sdk))
        self.assertEqual((self.out / "MacOSX.sdk").readlink(), sdk)
        self.assertFalse((self.out / provenance.RECEIPT).exists())

    def test_wrong_receipt_profile_digest_fails_even_when_sealed(self):
        receipt = self.sealed_receipt()
        data = json.loads(receipt.read_text())
        data["pgo_sha256"] = "0" * 64
        receipt.write_text(json.dumps(data))
        (self.artifact / "SHA256SUMS").write_text(f"{provenance.digest(receipt)}  ./{provenance.RECEIPT}\n")
        with self.assertRaisesRegex(ValueError, "does not match"):
            provenance.verify_cached(self.artifact, self.arch)

    def test_archive_receipt_requires_the_pinned_v8_builtins(self):
        receipt = self.sealed_receipt()
        data = json.loads(receipt.read_text())
        self.assertEqual(data["v8_builtins"], provenance.PINS["official_v8_builtins"])
        data["v8_builtins"]["sha256"] = "0" * 64
        receipt.write_text(json.dumps(data))
        (self.artifact / "SHA256SUMS").write_text(f"{provenance.digest(receipt)}  ./{provenance.RECEIPT}\n")
        with self.assertRaisesRegex(ValueError, "does not match"):
            provenance.verify_cached(self.artifact, self.arch)

    def test_official_build_requires_matching_v8_revision_and_bytes(self):
        self.v8_profile.write_bytes(b"wrong V8 profile")
        with self.assertRaisesRegex(ValueError, r"(?i)v8"):
            provenance.record(self.out, self.src, self.arch, {})
        self.v8_profile.write_bytes(b"synthetic V8 builtins PGO")
        self.v8_revision = "0" * 40
        with self.assertRaisesRegex(ValueError, r"(?i)v8.*revision"):
            provenance.record(self.out, self.src, self.arch, {})

    def test_acquire_v8_downloads_exact_version_then_reuses_valid_cache(self):
        content = self.v8_profile.read_bytes()
        self.v8_profile.unlink()
        pin = provenance.PINS["official_v8_builtins"]
        download = Mock(side_effect=lambda url, destination: destination.write_bytes(content))
        provenance.acquire_v8_builtins(self.src, download)
        provenance.acquire_v8_builtins(self.src, download)
        self.assertEqual(self.v8_profile.read_bytes(), content)
        self.assertEqual(provenance.digest(self.v8_profile), pin["sha256"])
        self.assertEqual(download.call_count, 1)
        url, staged_path = download.call_args.args
        self.assertEqual(
            url, f"https://storage.googleapis.com/chromium-v8-builtins-pgo/by-version/{pin['version']}/x64.profile")
        self.assertNotEqual(staged_path, self.v8_profile)
        self.assertFalse(staged_path.exists())

    def test_acquire_v8_preserves_old_bytes_until_replacement_verifies(self):
        content = self.v8_profile.read_bytes()
        old = b"old V8 PGO"
        self.v8_profile.write_bytes(old)

        def interrupted(url, destination):
            destination.write_bytes(b"partially downloaded")
            raise OSError("connection interrupted")

        def invalid(url, destination):
            destination.write_bytes(b"bad download")

        for download, error in ((interrupted, OSError), (invalid, ValueError)):
            with self.subTest(download=download.__name__), self.assertRaises(error):
                provenance.acquire_v8_builtins(self.src, download)
            self.assertEqual(self.v8_profile.read_bytes(), old)
            self.assertEqual(list(self.v8_profile.parent.parent.glob(".bark-rejected-v8-*")), [])

        provenance.acquire_v8_builtins(self.src, lambda url, destination: destination.write_bytes(content))
        self.assertEqual(self.v8_profile.read_bytes(), content)
        rejected, = self.v8_profile.parent.parent.glob(".bark-rejected-v8-*/x64.profile")
        self.assertEqual(rejected.read_bytes(), old)

    def test_acquire_v8_refuses_cache_symlinks_before_download(self):
        elsewhere = self.root / "outside.profile"
        content = self.v8_profile.read_bytes()
        elsewhere.write_bytes(content)
        self.v8_profile.unlink()
        self.v8_profile.symlink_to(elsewhere)
        download = Mock()
        with self.assertRaises(ValueError):
            provenance.acquire_v8_builtins(self.src, download)
        self.assertTrue(self.v8_profile.is_symlink())
        self.v8_profile.unlink()

        directory = self.root / "outside-profiles"
        self.v8_profile.parent.rename(directory)
        (directory / self.v8_profile.name).write_bytes(content)
        self.v8_profile.parent.symlink_to(directory)
        with self.assertRaises(ValueError):
            provenance.acquire_v8_builtins(self.src, download)
        self.assertTrue(self.v8_profile.parent.is_symlink())
        self.assertEqual(self.v8_profile.read_bytes(), content)
        self.assertEqual(elsewhere.read_bytes(), content)
        download.assert_not_called()

    def test_browser_compile_must_exist_and_predate_raw_link(self):
        self.include_browser_compile = False
        with self.assertRaisesRegex(ValueError, "no matching Siso browser compile"):
            provenance.record(self.out, self.src, self.arch, {})
        self.include_browser_compile = True
        os.utime(self.linked, ns=(self.browser_time - 1, self.browser_time - 1))
        self.link_entry["id"]["mod_time"] = self.linked.stat().st_mtime_ns
        with self.assertRaisesRegex(ValueError, "no matching Siso browser compile"):
            provenance.record(self.out, self.src, self.arch, {})

    def test_raw_framework_requires_the_matching_siso_link(self):
        saved = self.link_entry
        for changed in (None, {**saved, "cmd_hash": ""},
                        {**saved, "id": {"mod_time": saved["id"]["mod_time"] - 1}}):
            with self.subTest(changed=changed):
                self.link_entry = changed
                with self.assertRaisesRegex(ValueError, "no matching Siso link record"):
                    provenance.record(self.out, self.src, self.arch, {})

        self.link_entry = saved
        self.linked.write_bytes(b"unrelated framework replacement")
        self.image.write_bytes(self.linked.read_bytes())
        os.utime(self.linked, ns=(saved["id"]["mod_time"], saved["id"]["mod_time"]))
        with self.assertRaisesRegex(ValueError, "no matching Siso link record"):
            provenance.record(self.out, self.src, self.arch, {})

    def test_packaged_framework_must_match_raw_link(self):
        self.linked.write_bytes(b"another linked image")
        self.link_entry["id"]["mod_time"] = self.linked.stat().st_mtime_ns
        self.link_entry["digest"]["hash"] = provenance.digest(self.linked)
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
