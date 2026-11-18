"""Test contributor command dispatch without building or launching an app."""

from contextlib import nullcontext, redirect_stderr
from io import StringIO
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import Mock, patch

CLI = Path(__file__).resolve().parents[1] / "bark-check.py"


class ArchitectureTests(unittest.TestCase):
    def setUp(self):
        self.cli = runpy.run_path(str(CLI))["main"].__globals__
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.app = self.root / "Bark.app"
        self.app.mkdir()

    def invoke(self, args, hardware):
        targets = ("install_engine", "archive_engine", "build_candidate", "verify_candidate",
                   "make_distribution", "launch_candidate")
        calls = {target: Mock() for target in targets}
        calls["pinned_engine"] = Mock(return_value=nullcontext(self.root / "Engine"))
        with patch.dict(self.cli, {**calls, "native_architecture": lambda: hardware,
                                   "TemporaryDirectory": lambda **_: nullcontext(str(self.root))}), \
                patch.object(self.cli["platform"], "system", return_value="Darwin"), \
                patch("sys.argv", [str(CLI), *args]):
            self.cli["main"]()
        return calls

    def test_artifact_commands_and_smoke_default_to_native_architecture(self):
        cases = [
            (["engine", "--install", "--archive", str(self.root / "SDK.tar.gz")],
             [("install_engine", 1), ("archive_engine", 2)]),
            (["build"], [("build_candidate", 3)]),
            (["verify", str(self.app)], [("verify_candidate", 3)]),
            (["package", str(self.app), "--output", str(self.root / "release"),
              "--download-base-url", "https://downloads.example", "--ed-key-file", "-"], [("make_distribution", 2)]),
            (["smoke", str(self.app)], [("verify_candidate", 3)]),
        ]
        for hardware in ("arm64", "x86_64"):
            for args, targets in cases:
                with self.subTest(hardware=hardware, command=args[0]):
                    calls = self.invoke(args, hardware)
                    self.assertEqual(calls["pinned_engine"].call_args.args[2], hardware)
                    for target, position in targets:
                        self.assertEqual(calls[target].call_args.args[position], hardware)
                    if args[0] == "smoke":
                        calls["launch_candidate"].assert_called_once()

    def test_explicit_cross_architecture_verification_remains_available(self):
        calls = self.invoke(["verify", str(self.app), "--arch", "x86_64"], "arm64")
        self.assertEqual(calls["pinned_engine"].call_args.args[2], "x86_64")
        self.assertEqual(calls["verify_candidate"].call_args.args[3], "x86_64")
        calls["launch_candidate"].assert_not_called()

    def test_execution_rejects_cross_architecture(self):
        errors = StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit) as stopped:
            self.invoke(["smoke", str(self.app), "--arch", "x86_64"], "arm64")
        self.assertEqual(stopped.exception.code, 2)
        self.assertIn("requires the native arm64 runtime", errors.getvalue())

    def test_hardware_probe_detects_arm_when_python_reports_intel(self):
        with patch("sys.platform", "darwin"), patch.object(self.cli["platform"], "machine", return_value="x86_64"), \
                patch.object(self.cli["subprocess"], "run", return_value=Mock(stdout="1\n")) as probe:
            self.assertEqual(self.cli["native_architecture"](), "arm64")
        self.assertEqual(probe.call_args.args[0], ["/usr/sbin/sysctl", "-n", "hw.optional.arm64"])


if __name__ == "__main__":
    unittest.main()
