"""Offline checks for the signed walk's native-architecture preflight."""

import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import signed_walk
from signed_walk import REPO, Screen, ScreenUnavailable, verify_native_candidate


class InputOwnershipTests(unittest.TestCase):
    def test_rebuilt_app_is_rejected_before_launch(self):
        lock = runpy.run_path(str(REPO / "scripts/bark-check.py"))["app_output_lock"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(signed_walk, "bundle_cdhash", return_value="new-build"), \
                    patch.object(subprocess, "Popen") as start, self.assertRaisesRegex(RuntimeError, "changed"):
                signed_walk.launch_verified(root / "Bark.app", "verified-build", root, "fixture", None, lock)
            start.assert_not_called()

    def test_pointer_interruption_and_missed_post_stop_before_further_input(self):
        screen = Screen.__new__(Screen)
        screen.owns_screen = lambda: True
        screen.console = Mock()
        screen.console.pointer.return_value = (1400, 450)
        screen.point = (428, 453)
        with self.assertRaisesRegex(ScreenUnavailable, "between test inputs"):
            screen.key("q")
        with self.assertRaisesRegex(RuntimeError, "Posted pointer event missed"):
            screen.guard(target=(420, 450))


class NativeArchitectureTests(unittest.TestCase):
    def test_native_image_is_required_even_under_translated_python(self):
        contributor = runpy.run_path(str(REPO / "scripts/bark-check.py"))
        contributor["verify_signed_shell"] = Mock()
        verify = contributor["verify_signed_shell"]
        app = Path("/fixture/Bark.app")
        for probe_values, expected in [("1\n0\n", "arm64"), ("0\n1\n", "arm64"), ("", "x86_64")]:
            reply = subprocess.CompletedProcess([], 0, stdout=probe_values)
            with self.subTest(architecture=expected), patch("sys.platform", "darwin"), \
                    patch("platform.machine", return_value="x86_64"), patch("subprocess.run", return_value=reply) as sysctl:
                self.assertEqual(verify_native_candidate(contributor, app), expected)
                verify.assert_called_with(app, expected)
                sysctl.assert_called_once_with(
                    ["/usr/sbin/sysctl", "-in", "hw.optional.arm64", "sysctl.proc_translated"],
                    capture_output=True, text=True, check=True,
                )

    def test_verified_sdk_evidence_also_records_signed_bundle_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Bark.app"
            binary = app / "Contents/MacOS/Bark"
            binary.parent.mkdir(parents=True)
            binary.touch()
            output = root / "evidence"
            argv = ["walk", "--app", str(app), "--output", str(output), "--verify-sdk"]
            sdk = root / "Engine"
            qualification = {"architecture": "arm64", "sdk_pin": "fixture-pin", "official": None}
            ax = Mock(AXIsProcessTrusted=lambda: True)
            quartz = Mock(CGPreflightPostEventAccess=lambda: True, CGPreflightScreenCaptureAccess=lambda: True)
            check = runpy.run_path(str(REPO / "scripts/bark-check.py"))
            contributor = {"native_architecture": lambda: "arm64", "app_output_lock": check["app_output_lock"]}

            def verified_cdhash(candidate):
                verify.assert_called_once_with(contributor, "arm64", app.resolve(), require_official=False)
                self.assertEqual(candidate, app.resolve())
                return "verified-cdhash"

            with patch.object(sys, "argv", argv), patch.object(sys, "platform", "darwin"), patch.dict(
                sys.modules, {"ApplicationServices": ax, "Quartz": quartz}
            ), patch.object(signed_walk, "processes", return_value=[]), patch.object(
                signed_walk.runpy, "run_path", return_value=contributor
            ), patch.object(signed_walk, "verify_pinned_sdk", return_value=(sdk, qualification)) as verify, patch.object(
                signed_walk, "bundle_cdhash", side_effect=verified_cdhash
            ), patch("bark_macos_console.QuartzConsole"), self.assertRaisesRegex(RuntimeError, "stop before launch"):
                signed_walk.run_walk("fixture", "fixture", Mock(side_effect=RuntimeError("stop before launch")),
                                     Mock(), official_qualification=True)
            self.assertEqual(json.loads((output / "candidate.json").read_text()), {
                "architecture": "arm64", "sdk_pin": "fixture-pin", "official": None,
                "bundle_cdhash": "verified-cdhash",
            })

    def test_timing_report_survives_missing_cpu_brand(self):
        startup = runpy.run_path(str(REPO / "Tests/ChromiumStartup/walk.py"))
        with patch("subprocess.check_output", return_value="Mac14,2\n17179869184\n"), patch(
            "subprocess.run", return_value=subprocess.CompletedProcess([], 1, stdout="")
        ):
            self.assertEqual(startup["hardware"](), {"model": "Mac14,2", "memory_bytes": 17179869184, "cpu": None})


if __name__ == "__main__":
    unittest.main()
