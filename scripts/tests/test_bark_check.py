"""Test contributor command dispatch without building or launching an app."""

from contextlib import nullcontext, redirect_stderr
import fcntl
from io import StringIO
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time
import tempfile
import unittest
from unittest.mock import Mock, call, patch

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
            (["smoke", str(self.app)], [("launch_candidate", 3)]),
            (["launch", str(self.app)], [("launch_candidate", 3)]),
        ]
        for hardware in ("arm64", "x86_64"):
            for args, targets in cases:
                with self.subTest(hardware=hardware, command=args[0]):
                    calls = self.invoke(args, hardware)
                    self.assertEqual(calls["pinned_engine"].call_args.args[2], hardware)
                    for target, position in targets:
                        self.assertEqual(calls[target].call_args.args[position], hardware)
                    if args[0] in ("smoke", "launch"):
                        self.assertFalse(calls["pinned_engine"].call_args.args[3])
                        self.assertEqual(calls["launch_candidate"].call_args.kwargs,
                                         {"interactive": args[0] == "launch"})

    def test_explicit_cross_architecture_verification_remains_available(self):
        calls = self.invoke(["verify", "--arch", "x86_64", "--require-official", str(self.app)], "arm64")
        self.assertEqual(calls["pinned_engine"].call_args.args[2:], ("x86_64", True))
        self.assertEqual(calls["verify_candidate"].call_args.args[3], "x86_64")
        calls["launch_candidate"].assert_not_called()

    def test_official_execution_qualifies_the_sdk_before_smoke_or_launch(self):
        for command in ("smoke", "launch"):
            with self.subTest(command=command):
                calls = self.invoke([command, "--require-official", str(self.app)], "arm64")
                self.assertEqual(calls["pinned_engine"].call_args.args[2:], ("arm64", True))
                self.assertEqual(calls["launch_candidate"].call_args.args[1], self.root / "Engine")
                self.assertEqual(calls["launch_candidate"].call_args.kwargs,
                                 {"interactive": command == "launch"})

    def test_execution_rejects_cross_architecture(self):
        errors = StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit) as stopped:
            self.invoke(["smoke", str(self.app), "--arch", "x86_64"], "arm64")
        self.assertEqual(stopped.exception.code, 2)
        self.assertIn("requires the native arm64 runtime", errors.getvalue())

    def test_hardware_probe_detects_arm_when_python_reports_intel(self):
        with patch("sys.platform", "darwin"), patch.object(self.cli["platform"], "machine", return_value="x86_64"), \
                patch.object(self.cli["subprocess"], "run", return_value=Mock(stdout="0\n1\n")) as probe:
            self.assertEqual(self.cli["native_architecture"](), "arm64")
        self.assertEqual(probe.call_args.args[0], ["/usr/sbin/sysctl", "-in", "hw.optional.arm64", "sysctl.proc_translated"])


class CandidateLaunchTests(unittest.TestCase):
    def test_install_cannot_replace_bundle_between_verification_and_exec(self):
        cli = runpy.run_path(str(CLI))["main"].__globals__
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Bark.app"
            app.mkdir()
            fd = os.open(root, os.O_RDONLY)
            self.addCleanup(os.close, fd)
            engine = root / "Engine"
            server = Mock(server_port=12345)
            server.handle_request.side_effect = lambda: setattr(server, "rendered", True)
            proc = Mock()
            proc.poll.return_value = None

            def verify(*args):
                self.assertEqual(args, (app, engine, root, "x86_64"))
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

            def launch(command, **_):
                verified.assert_called_once()
                self.assertEqual(Path(command[0]), app / "Contents/MacOS/Bark")
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return proc

            def stop(process):
                self.assertIs(process, proc)
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)

            verified = Mock(side_effect=verify)
            with patch.dict(cli, {"verify_candidate": verified, "HTTPServer": lambda *_: nullcontext(server),
                                  "seed_profile": Mock(), "stop": stop}), \
                    patch("subprocess.Popen", side_effect=launch) as spawn, patch("subprocess.run"):
                cli["launch_candidate"](app, engine, root, "x86_64", interactive=False)
            spawn.assert_called_once()


class CandidateCleanupTests(unittest.TestCase):
    def setUp(self):
        self.stop = runpy.run_path(str(CLI))["stop"]

    def test_exited_leader_and_zombie_helper_do_not_shadow_original_failure(self):
        proc = Mock(pid=2345)
        proc.poll.return_value = -signal.SIGTERM
        with patch("os.killpg", side_effect=[None, PermissionError()]) as kill, \
                patch("subprocess.check_output", return_value=" 99 S\n 2345 Z+\n") as scan:
            with self.assertRaisesRegex(ValueError, "original walk failure"):
                try:
                    raise ValueError("original walk failure")
                finally:
                    self.stop(proc)
        self.assertEqual(kill.call_args_list,
                         [call(proc.pid, signal.SIGTERM), call(proc.pid, signal.SIGKILL)])
        scan.assert_called_once_with(["/bin/ps", "-axo", "pgid=,state="], text=True)
        proc.wait.assert_called()

    def test_exited_leader_does_not_hide_failure_to_stop_live_helper(self):
        proc = Mock(pid=2345)
        proc.poll.return_value = -signal.SIGTERM
        with patch("os.killpg", side_effect=[None, PermissionError()]), \
                patch("subprocess.check_output", return_value=" 2345 Z\n 2345 S\n"):
            with self.assertRaises(PermissionError):
                self.stop(proc)

    def test_permission_failure_with_live_leader_is_not_ignored(self):
        proc = Mock(pid=2345)
        proc.poll.return_value = None
        with patch("os.killpg", side_effect=PermissionError()), patch("subprocess.check_output") as scan:
            with self.assertRaises(PermissionError):
                self.stop(proc)
        scan.assert_not_called()

    def test_stop_terminates_a_group_with_a_term_resistant_helper(self):
        program = """import os, signal, time
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(os.getpid(), flush=True)
time.sleep(60)
"""
        proc = subprocess.Popen([sys.executable, "-c", program], start_new_session=True,
                                stdout=subprocess.PIPE, text=True)
        self.addCleanup(proc.stdout.close)
        self.addCleanup(self.stop, proc)
        helper = int(proc.stdout.readline())
        self.stop(proc)
        self.assertEqual(proc.returncode, -signal.SIGTERM)

        until = time.monotonic() + 5
        while time.monotonic() < until:
            status = subprocess.run(["/bin/ps", "-p", str(helper), "-o", "state="],
                                    capture_output=True, text=True)
            if not status.stdout.strip() or status.stdout.strip().startswith("Z"):
                return
            time.sleep(0.05)
        self.fail("A live helper remained after the candidate process group was stopped")


if __name__ == "__main__":
    unittest.main()
