"""Offline checks for the signed walk's native-architecture preflight."""

from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import Mock, patch

from signed_walk import REPO, verify_native_candidate


class NativeArchitectureTests(unittest.TestCase):
    def test_native_image_is_required_even_under_translated_python(self):
        contributor = runpy.run_path(str(REPO / "scripts/bark-check.py"))
        contributor["verify_signed_shell"] = Mock()
        verify = contributor["verify_signed_shell"]
        app = Path("/fixture/Bark.app")
        for arm_feature, status, expected in [("1\n", 0, "arm64"), ("", 1, "x86_64")]:
            with self.subTest(architecture=expected), patch("platform.machine", return_value="x86_64"), patch(
                "subprocess.run", return_value=subprocess.CompletedProcess([], status, stdout=arm_feature)
            ) as sysctl:
                self.assertEqual(verify_native_candidate(contributor, app), expected)
                verify.assert_called_with(app, expected)
                sysctl.assert_called_once_with(
                    ["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True,
                )

    def test_timing_report_survives_missing_cpu_brand(self):
        startup = runpy.run_path(str(REPO / "Tests/ChromiumStartup/walk.py"))
        with patch("subprocess.check_output", return_value="Mac14,2\n17179869184\n"), patch(
            "subprocess.run", return_value=subprocess.CompletedProcess([], 1, stdout="")
        ):
            self.assertEqual(startup["hardware"](), {"model": "Mac14,2", "memory_bytes": 17179869184, "cpu": None})


if __name__ == "__main__":
    unittest.main()
