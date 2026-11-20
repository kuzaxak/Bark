"""Regressions for tying native startup and Sparkle results to one signed candidate."""

import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

import qualify


class OfficialQualificationTests(unittest.TestCase):
    def run_candidate(self, root, *, mismatch=None, busy=False, install_image=True, update_kit=None):
        app = root / "Bark.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "ee.qdo.bark", "CFBundleVersion": "120", "CFBundleShortVersionString": "1.5",
            "BarkShellSourceSHA256": "0" * 64 if mismatch == "stale-shell" else "f" * 64,
        }))
        image = root / "candidate.dmg"
        image.write_bytes(b"fixture image")
        installed = root / "private install/Bark.app" if install_image else app
        framework = installed / "Contents/Frameworks/Bark Framework.framework"
        version = framework / "Versions/1"
        version.mkdir(parents=True, exist_ok=True)
        (version / "Bark Framework").write_bytes(b"engine")
        (framework / "Versions/Current").symlink_to("1", target_is_directory=True)
        (framework / "Bark Framework").symlink_to("Versions/Current/Bark Framework")
        (version / "second name").hardlink_to(version / "Bark Framework")
        if installed != app:
            (installed / "Contents/Info.plist").write_bytes((app / "Contents/Info.plist").read_bytes())
        (installed / "Contents/launcher").write_bytes(b"app")
        output = root / "evidence"
        output.mkdir()
        sdk = {"architecture": "arm64", "sdk_pin": "b" * 64, "official": True}
        candidate = {**sdk, "bundle_cdhash": "c" * 40}
        runs = []

        def exercise_image(image_path, signed_app, work, requirement, verify, *, exercise):
            self.assertEqual((image_path, signed_app), (image, app))
            exercise(installed)

        def walk(script, arguments, directory):
            self.assertIn(installed, arguments)
            if busy:
                raise qualify.ScreenUnavailable("occupied")
            directory.mkdir()
            runs.append(script)
            if script.parent.name == "ChromiumStartup":
                result = {"candidate": candidate, "was_discarded": False, "document_id": str(uuid4()),
                          "parked_window_web_areas": ["Peek fixture target"],
                          "hardware": {"model": "Mac16,6", "memory_bytes": 24 * 1024**3, "cpu": "Apple M4 Pro"},
                          "macos": "15.8.2", "launch_to_pointer_ms": 10,
                          "switch_back_to_key_ms": 2, "observed_hidden_ms": 2000}
                if mismatch == "startup" and len(runs) == 2:
                    result["candidate"] = {**candidate, "bundle_cdhash": "0" * 40}
                if mismatch == "profile":
                    result["document_id"] = "2fbbed78-8d95-472f-97a2-953c8c98237c"
                if mismatch == "mounted":
                    result["parked_window_web_areas"].append("Peek fixture source")
                if mismatch == "hardware" and len(runs) == 2:
                    result["hardware"]["model"] = "Mac99,99"
                (directory / "result.json").write_text(json.dumps(result))
            else:
                self.assertIn("--candidate-app", arguments)
                update = {**sdk, "source_bundle_cdhash": candidate["bundle_cdhash"],
                          "shell_source": "signed-candidate", "original_bundle_cdhash": "a" * 40,
                          "replacement_bundle_cdhash": "d" * 40}
                if update_kit is not None:
                    self.assertEqual(arguments, ["--candidate-app", installed, "--kit", update_kit])
                    if mismatch != "kit":
                        update["rehearsal_kit"] = "e" * 64
                if mismatch == "update":
                    update["source_bundle_cdhash"] = "0" * 40
                if mismatch == "sdk":
                    update["sdk_pin"] = "0" * 64
                (directory / "candidate.json").write_text(json.dumps(update))

        tools = {"native_architecture": lambda: "arm64"}
        with patch.object(qualify.runpy, "run_path", return_value=tools), \
                patch.object(qualify, "shell_source_digest", return_value="f" * 64), \
                patch.object(qualify, "verify_official_sdk", return_value=(None, sdk)), \
                patch.object(qualify, "bundle_cdhash", return_value=candidate["bundle_cdhash"]), \
                patch.object(qualify.subprocess, "run"), patch.object(qualify.time, "sleep"), \
                patch.object(qualify.bark_release, "verify_installed_image", side_effect=exercise_image), \
                patch.object(qualify, "walk", side_effect=walk):
            qualify.qualify(app, image if install_image else None, None if update_kit else "Test identity",
                            output, update_kit=update_kit)
        self.assertEqual(len(runs), 4)
        return json.loads((output / "qualification.json").read_text())

    def test_older_signed_shell_with_the_same_sdk_cannot_qualify(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaisesRegex(ValueError, "different Bark shell source"):
                self.run_candidate(root, mismatch="stale-shell", update_kit=root / "kit")
            self.assertFalse((root / "evidence/qualification.json").exists())
            self.assertFalse((root / "evidence/startup-1").exists())

    def test_all_four_walks_use_the_installed_candidate(self):
        with tempfile.TemporaryDirectory() as folder:
            result = self.run_candidate(Path(folder))
            self.assertEqual(len(result["startup"]), 3)
            self.assertTrue(result["candidate"]["official"])
            self.assertEqual(len({sample["document_id"] for sample in result["startup"]}), 3)
            self.assertEqual(result["startup"][0]["parked_window_web_areas"], ["Peek fixture target"])
            self.assertIs(result["startup"][0]["was_discarded"], False)
            self.assertEqual(result["installed_update"]["replacement_bundle_cdhash"], "d" * 40)
            self.assertEqual(result["installation"], "notarized-dmg")
            self.assertEqual(len(result["image_sha256"]), 64)
            info_size = (Path(folder) / "Bark.app/Contents/Info.plist").stat().st_size
            self.assertEqual(result["size_bytes"], {"installed_app": 9 + info_size, "chromium_framework": 6,
                                                     "download_dmg": len(b"fixture image")})

    def test_receiving_mac_qualifies_the_installed_image_using_its_pre_signed_update(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = self.run_candidate(root, update_kit=root / "kit")
            self.assertEqual(result["installed_update"]["rehearsal_kit"], "e" * 64)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaisesRegex(ValueError, "pre-signed rehearsal kit"):
                self.run_candidate(root, update_kit=root / "kit", mismatch="kit")
            self.assertFalse((root / "evidence/qualification.json").exists())

    def test_app_only_qualifies_without_admitting_a_release_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = self.run_candidate(root, install_image=False)
            self.assertEqual(result["installation"], "signed-app")
            self.assertNotIn("image_sha256", result)
            self.assertNotIn("download_dmg", result["size_bytes"])
            with self.assertRaisesRegex(ValueError, "requires a notarized DMG"):
                qualify.check_release_receipt(root / "evidence/qualification.json",
                                              root / "candidate.dmg", "arm64", root / "Bark.app")

    @staticmethod
    def verify_fixture_copy(image, app, work, requirement, verify):
        verify(image.parent / "private install/Bark.app")

    def test_release_receipt_checks_exact_architecture_image_and_app(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = self.run_candidate(root)
            receipt, image, app = (root / "evidence/qualification.json",
                                   root / "candidate.dmg", root / "Bark.app")
            with patch.object(qualify, "bundle_cdhash", return_value=result["candidate"]["bundle_cdhash"]), \
                    patch.object(qualify.runpy, "run_path", return_value={}), \
                    patch.object(qualify, "verify_official_sdk",
                                 return_value=(None, {"sdk_pin": result["candidate"]["sdk_pin"]})), \
                    patch.object(qualify, "shell_source_digest", return_value="f" * 64) as source_digest, \
                    patch.object(qualify, "verify_release_signature") as verify_signature, \
                    patch.object(qualify.subprocess, "run") as run_tool, \
                    patch.object(qualify.bark_release, "verify_installed_image",
                                 side_effect=self.verify_fixture_copy):
                qualify.check_release_receipt(receipt, image, "arm64", app)
                verify_signature.assert_called_once_with(app)
                run_tool.assert_called_once_with(
                    ["/usr/bin/codesign", "--verify", "--strict", "-R",
                     qualify.bark_release.distribution_requirement(app, "ee.qdo.bark"), image], check=True)
                run_tool.side_effect = subprocess.CalledProcessError(1, "codesign DMG")
                with self.assertRaises(subprocess.CalledProcessError):
                    qualify.check_release_receipt(receipt, image, "arm64", app)
                run_tool.side_effect = None
                source_digest.return_value = "0" * 64
                with self.assertRaisesRegex(ValueError, "different Bark shell source"):
                    qualify.check_release_receipt(receipt, image, "arm64", app)
                source_digest.return_value = "f" * 64
                with self.assertRaisesRegex(ValueError, "release architecture"):
                    qualify.check_release_receipt(receipt, image, "x86_64", app)
                for field, bad_value, reason in (
                    ("startup", [], "Three successful"),
                    ("startup", [{}, {}, {}], "measurement is missing"),
                    ("startup", [dict(sample, document_id="") for sample in result["startup"]],
                     "fresh document"),
                    ("startup", [dict(sample, parked_window_web_areas=[]) for sample in result["startup"]],
                     "unmounted"),
                    ("hardware", {}, "hardware"),
                    ("macos", "", "macOS"),
                    ("installed_update", {"original_bundle_cdhash": "a" * 40,
                                          "replacement_bundle_cdhash": "a" * 40}, "distinct signed"),
                    ("candidate", {**result["candidate"], "sdk_pin": "f" * 64}, "SDK pin"),
                    ("build", "119", "Bark build"),
                    ("size_bytes", {}, "package sizes"),
                    ("size_bytes", dict(result["size_bytes"], download_dmg=1), "package sizes"),
                    ("size_bytes", dict(result["size_bytes"], installed_app=1), "package sizes"),
                    ("size_bytes", dict(result["size_bytes"], chromium_framework=1), "package sizes"),
                ):
                    with self.subTest(field=field, reason=reason):
                        receipt.write_text(json.dumps({**result, field: bad_value}))
                        with self.assertRaisesRegex(ValueError, reason):
                            qualify.check_release_receipt(receipt, image, "arm64", app)
                receipt.write_text(json.dumps(result))
                image.write_bytes(b"another fixture image")
                with self.assertRaisesRegex(ValueError, "release DMG does not match"):
                    qualify.check_release_receipt(receipt, image, "arm64", app)
            with patch.object(qualify, "bundle_cdhash", return_value="0" * 40):
                with self.assertRaisesRegex(ValueError, "release app does not match"):
                    qualify.check_release_receipt(receipt, image, "arm64", app)

    def test_plausible_receipt_cannot_vouch_for_developer_payload(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = self.run_candidate(root)
            receipt = root / "evidence/qualification.json"
            image, app = root / "candidate.dmg", root / "Bark.app"
            with patch.object(qualify, "bundle_cdhash", return_value=result["candidate"]["bundle_cdhash"]), \
                    patch.object(qualify, "shell_source_digest", return_value="f" * 64), \
                    patch.object(qualify, "verify_release_signature"), \
                    patch.object(qualify.subprocess, "run"), \
                    patch.object(qualify.bark_release, "verify_installed_image",
                                 side_effect=self.verify_fixture_copy), \
                    patch.object(qualify.runpy, "run_path", return_value={}) as load, \
                    patch.object(qualify, "verify_official_sdk",
                                 side_effect=ValueError("The SDK receipt does not match the pinned recipe")) as verify:
                with self.assertRaisesRegex(ValueError, "SDK receipt does not match"):
                    qualify.check_release_receipt(receipt, image, "arm64", app)
                verify.assert_called_once_with(load.return_value, "arm64", root / "private install/Bark.app")

    def test_receipt_cannot_pair_unrelated_image_with_verified_app(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = self.run_candidate(root)
            receipt = root / "evidence/qualification.json"
            image, app = root / "candidate.dmg", root / "Bark.app"
            image.write_bytes(b"another image with a matching digest in the supplied receipt")
            result["image_sha256"] = qualify.file_digest(image)
            receipt.write_text(json.dumps(result))
            with patch.object(qualify, "bundle_cdhash", return_value=result["candidate"]["bundle_cdhash"]), \
                    patch.object(qualify, "shell_source_digest", return_value="f" * 64), \
                    patch.object(qualify, "verify_release_signature"), \
                    patch.object(qualify.subprocess, "run"), \
                    patch.object(qualify.runpy, "run_path", return_value={}), \
                    patch.object(qualify, "verify_official_sdk",
                                 return_value=(None, {"sdk_pin": result["candidate"]["sdk_pin"]})) as verify, \
                    patch.object(qualify.bark_release, "verify_installed_image",
                                 side_effect=ValueError("The app copied from the disk image differs")):
                with self.assertRaisesRegex(ValueError, "app copied from the disk image differs"):
                    qualify.check_release_receipt(receipt, image, "arm64", app)
                verify.assert_not_called()

    def test_transfer_cli_uses_received_image_without_staging_app(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = self.run_candidate(root)
            app = root / "Bark.app"
            installed = root / "private install/Bark.app"
            receipt, image = root / "evidence/qualification.json", root / "candidate.dmg"
            (app / "Contents/Info.plist").unlink()
            (app / "Contents").rmdir()
            app.rmdir()

            args = ["--receipt", str(receipt), "--image", str(image), "--arch", "arm64"]
            with patch.object(qualify, "bundle_cdhash", return_value=result["candidate"]["bundle_cdhash"]) as cdhash, \
                    patch.object(qualify, "shell_source_digest", return_value="f" * 64), \
                    patch.object(qualify.subprocess, "run"), \
                    patch.object(qualify.runpy, "run_path", return_value={}) as load, \
                    patch.object(qualify, "verify_official_sdk",
                                 return_value=(None, {"sdk_pin": result["candidate"]["sdk_pin"]})) as sdk, \
                    patch.object(qualify.bark_release, "verify_installed_image",
                                 side_effect=self.verify_fixture_copy) as install:
                self.assertEqual(qualify.release_receipt_main(args), 0)
                self.assertIsNone(install.call_args.args[1])
                cdhash.assert_called_once_with(installed)
                sdk.assert_called_once_with(load.return_value, "arm64", installed)
                cdhash.return_value = "0" * 40
                self.assertEqual(qualify.release_receipt_main(args), 1)
                self.assertEqual(sdk.call_count, 1)

    def test_mismatched_evidence_never_writes_a_qualification_receipt(self):
        for reason in ("startup", "profile", "update", "sdk", "mounted", "hardware"):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                with self.assertRaises(ValueError):
                    self.run_candidate(root, mismatch=reason)
                self.assertFalse((root / "evidence/qualification.json").exists())

    def test_only_the_walks_reserve_status_three_for_the_desktop(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "trial"
            for code in (3, 1):
                with self.subTest(code=code), patch.object(qualify.subprocess, "run",
                        return_value=subprocess.CompletedProcess(["walk"], code)):
                    with self.assertRaises(qualify.ScreenUnavailable if code == 3 else subprocess.CalledProcessError):
                        qualify.walk(Path("walk.py"), [], output / str(code))

    def test_guard_interruption_propagates_without_a_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(qualify.ScreenUnavailable):
                self.run_candidate(root, busy=True)
            self.assertFalse((root / "evidence/qualification.json").exists())


if __name__ == "__main__":
    unittest.main()
