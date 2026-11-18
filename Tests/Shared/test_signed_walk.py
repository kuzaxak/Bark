"""Offline checks for the signed walk's native-architecture preflight."""

from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import Mock, patch

from signed_walk import REPO, Screen, ScreenUnavailable, verify_native_candidate


class InputOwnershipTests(unittest.TestCase):
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

    def test_timing_report_survives_missing_cpu_brand(self):
        startup = runpy.run_path(str(REPO / "Tests/ChromiumStartup/walk.py"))
        with patch("subprocess.check_output", return_value="Mac14,2\n17179869184\n"), patch(
            "subprocess.run", return_value=subprocess.CompletedProcess([], 1, stdout="")
        ):
            self.assertEqual(startup["hardware"](), {"model": "Mac14,2", "memory_bytes": 17179869184, "cpu": None})


if __name__ == "__main__":
    unittest.main()
