"""Check Sparkle handoff and rehearsal inputs without launching an app."""
import contextlib
import hashlib
import json
from io import StringIO
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

import walk


class SparklePreparationTests(unittest.TestCase):
    def test_extraction_does_not_start_quit_deadline(self):
        status = {"installer_visible": True, "controls": {}, "dialog_text": ["Extracting update…"]}
        self.assertFalse(walk.preparation_handoff_seen(status, True))

    def test_normal_window_before_extraction_does_not_start_quit_deadline(self):
        status = {"installer_visible": False, "controls": {}, "dialog_text": []}
        self.assertFalse(walk.preparation_handoff_seen(status, False))
        self.assertTrue(walk.preparation_handoff_seen(status, True))

    def test_ready_or_installing_starts_quit_deadline(self):
        ready = {"installer_visible": True, "controls": {"Install and Relaunch": True}, "dialog_text": []}
        installing = {"installer_visible": True, "controls": {}, "dialog_text": ["Installing update…"]}
        self.assertTrue(walk.preparation_handoff_seen(ready, False))
        ready["controls"]["Install and Relaunch"] = False
        self.assertFalse(walk.preparation_handoff_seen(ready, False))
        self.assertTrue(walk.preparation_handoff_seen(installing, False))


class UpdateBuildInputTest(unittest.TestCase):
    def sdk_tools(self, engine):
        sums = b"verified SDK manifest fixture"
        (engine / "SHA256SUMS").write_bytes(sums)
        pin = hashlib.sha256(sums).hexdigest()
        self.pin = pin
        return {
            "native_architecture": lambda: "x86_64",
            "cached_engine": lambda arch: engine,
            "pinned_engine": lambda source, working, arch, require_official: contextlib.nullcontext(engine),
            "read_pin": lambda package, arch: pin,
            "PACKAGE": engine.parent,
        }

    def check_evidence(self, path, shell_source, exercise):
        self.assertEqual(json.loads(path.read_text()), {
            "architecture": "x86_64", "sdk_pin": self.pin, "official": None,
            "shell_source": shell_source, "original_bundle_cdhash": "original",
            "replacement_bundle_cdhash": "replacement",
        })
        self.assertEqual(exercise.call_args.kwargs["replacement_cdhash"], "replacement")

    def test_official_rehearsal_refuses_external_products(self):
        with self.assertRaises(SystemExit) as failure, contextlib.redirect_stderr(StringIO()) as error:
            walk.parse_args(["--require-official", "--derived-data", "/tmp/another-build",
                             "--output", "/tmp/evidence", "--identity", "Fixture"])
        self.assertEqual(failure.exception.code, 2)
        self.assertIn("Omit --derived-data", error.getvalue())

    def test_developer_rehearsal_passes_supplied_products_without_building(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            derived = root / "existing-derived-data"
            derived.mkdir()
            engine = root / "Engine"
            engine.mkdir()
            argv = ["walk.py", "--derived-data", str(derived), "--identity", "Fixture",
                    "--output", str(root / "evidence")]
            tools = self.sdk_tools(engine)
            with patch.object(walk.sys, "argv", argv), patch.object(walk.runpy, "run_path", return_value=tools), \
                    patch.object(walk, "build_checkout_shell") as build, patch.object(walk, "UpdateServer"), \
                    patch.object(walk, "versions", return_value=(None, None, None, None)) as versions, \
                    patch.object(walk.bark_release, "bundle_cdhash", side_effect=["replacement", "original"]), \
                    patch.object(walk, "exercise") as exercise, contextlib.redirect_stdout(StringIO()):
                walk.main()
            build.assert_not_called()
            self.check_evidence(root / "evidence/candidate.json", "external-derived-data", exercise)
            self.assertEqual(versions.call_args.args[1:5], (derived.resolve(), engine, "Fixture", "x86_64"))

    def test_developer_rehearsal_builds_and_removes_temporary_products(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root.resolve() / "evidence"
            engine = root / "Engine"
            engine.mkdir()
            argv = ["walk.py", "--identity", "Fixture", "--output", str(output)]
            tools = self.sdk_tools(engine)

            def build_shell(check, derived, arch, evidence):
                self.assertEqual(check, tools)
                self.assertEqual(arch, "x86_64")
                self.assertEqual(evidence, output.resolve())
                self.assertEqual(derived.name, "DerivedData")
                derived.mkdir()

            def use_versions(check, derived, sdk, identity, arch, work, server, evidence):
                self.assertEqual((derived, sdk, identity, arch), (work / "DerivedData", engine, "Fixture", "x86_64"))
                self.assertTrue(derived.is_dir())
                return None, None, None, None

            with patch.object(walk.sys, "argv", argv), patch.object(walk.runpy, "run_path", return_value=tools), \
                    patch.object(walk, "build_checkout_shell", side_effect=build_shell) as build, \
                    patch.object(walk, "UpdateServer"), patch.object(walk, "versions", side_effect=use_versions), \
                    patch.object(walk.bark_release, "bundle_cdhash", side_effect=["replacement", "original"]), \
                    patch.object(walk, "exercise") as exercise, contextlib.redirect_stdout(StringIO()):
                walk.main()
            build.assert_called_once()
            self.assertFalse(build.call_args.args[1].exists())
            self.check_evidence(output / "candidate.json", "checkout", exercise)

    def test_installed_bundle_must_have_the_verified_replacements_cdhash(self):
        with tempfile.TemporaryDirectory() as folder:
            installed, replacement = (Path(folder) / name for name in ("installed", "replacement"))
            for app in (installed, replacement):
                for relative in ("Contents/MacOS/Bark", "Contents/Info.plist",
                                 "Contents/Frameworks/NookNativeShell.framework/Versions/A/NookNativeShell",
                                 Path("Contents/Frameworks") / walk.TEST_FRAMEWORK):
                    path = app / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"identical fixture")
            with patch.object(walk, "outer_icon", return_value=None), patch.object(
                walk.bark_release, "bundle_cdhash", side_effect=["replacement-cdhash", "different-cdhash"]
            ):
                walk.verify_installed_replacement(installed, replacement, "replacement-cdhash")
                with self.assertRaisesRegex(RuntimeError, "different CDHash"):
                    walk.verify_installed_replacement(installed, replacement, "replacement-cdhash")

    def test_checkout_shell_uses_locked_release_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            derived = root / "DerivedData"
            check = runpy.run_path(str(walk.REPO / "scripts/bark-check.py"))
            unsigned = derived / "Build/Products/Release/Bark.app"
            unsigned.mkdir(parents=True)
            with patch.object(walk, "run") as run, patch.object(walk.subprocess, "run") as launch_services:
                walk.build_checkout_shell(check, derived, "arm64", root)
            launch_services.assert_called_once_with([walk.LSREGISTER, "-u", str(unsigned)], capture_output=True)
            self.assertEqual(run.call_args.args, check["release_shell_build_args"](derived, "arm64"))
            self.assertEqual(run.call_args.args[:7],
                             ("xcodebuild", "-project", walk.REPO / "Bark.xcodeproj",
                              "-scheme", "Bark", "-configuration", "Release"))
            self.assertEqual(run.call_args.args[run.call_args.args.index("-derivedDataPath") + 1], derived)
            self.assertIn("-onlyUsePackageVersionsFromResolvedFile", run.call_args.args)
            self.assertIn("ARCHS=arm64", run.call_args.args)


if __name__ == "__main__":
    unittest.main()
