"""Headless checks for the local Chromium browser-test runner."""

import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from run_browser_tests import (
    APP_FRAMEWORK, HOST_ONLY_MARKER, TEST_FRAMEWORK, ScreenUnavailable,
    file_identity, main,
    require_host_only_image, require_host_only_runtime, run_tests, screen_lock,
)


class ScreenLockTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "screen-lock"

    def test_owner_can_acquire_and_release(self):
        with screen_lock(self.path, 0) as owned:
            self.assertTrue(owned())
            self.assertEqual(str(os.getpid()), (self.path / "pid").read_text().strip())
        self.assertFalse(self.path.exists())

    def test_existing_lock_survives_timeout(self):
        self.path.mkdir()
        marker = self.path / "pid"
        marker.write_text("0\n")
        with self.assertRaisesRegex(ScreenUnavailable, "already held"):
            with screen_lock(self.path, 0):
                self.fail("Reclaimed an existing screen lock")
        self.assertEqual("0\n", marker.read_text())

    def test_missing_owner_marker_does_not_leave_a_lock(self):
        with screen_lock(self.path, 0):
            (self.path / "pid").unlink()
        self.assertFalse(self.path.exists())

    def test_replaced_lock_is_not_released_by_previous_owner(self):
        displaced = self.path.with_name("displaced")
        with screen_lock(self.path, 0) as owned:
            self.path.rename(displaced)
            self.path.mkdir()
            marker = self.path / "pid"
            marker.write_text("replacement\n")
            self.assertFalse(owned())
        self.assertEqual("replacement\n", marker.read_text())
        self.assertFalse((displaced / "pid").exists())


class HostOnlyRuntimeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.checkout = Path(directory.name)
        self.binary = self.checkout / "bark_browser_tests"
        self.binary.write_bytes(b"test fixture")
        self.binary.chmod(0o700)

    def test_marker_must_be_in_the_factory_section(self):
        marker = HOST_ONLY_MARKER.hex(" ")
        with patch("run_browser_tests.subprocess.check_output", side_effect=[
            "x86_64\n", f"demo:\nContents of (__TEXT,__cstring) section\n0010 {marker}\n",
        ]):
            with self.assertRaisesRegex(ValueError, "Missing the compiled"):
                require_host_only_image(self.binary)

    def test_default_suite_checks_native_hardware_even_under_translated_python(self):
        (self.checkout / "chrome").mkdir()
        (self.checkout / "chrome/VERSION").touch()
        for arm_flag, arch, cpu in (("1\n", "arm64", "arm64"), ("", "x86_64", "x64")):
            binary = self.checkout / "out" / f"Barc-{cpu}" / "bark_browser_tests"
            binary.parent.mkdir(parents=True)
            binary.touch(mode=0o700)
            with self.subTest(arch=arch), patch.object(sys, "argv", ["runner", "--checkout", str(self.checkout)]), \
                    patch.object(sys, "platform", "darwin"), patch("platform.machine", return_value="x86_64"), \
                    patch("chromium_sdk_layout.subprocess.run", return_value=Mock(stdout=arm_flag)), \
                    patch("run_browser_tests.require_host_only_image", side_effect=ValueError("fixture")) as inspect, \
                    patch("run_browser_tests.screen_lock") as lock, patch("run_browser_tests.signal.signal"), \
                    patch("run_browser_tests.sys.stderr", new_callable=io.StringIO):
                self.assertEqual(main(), 1)
                inspect.assert_called_once_with(binary.resolve(), expected_arch=arch)
                lock.assert_not_called()

    def test_exact_factory_marker_is_accepted(self):
        marker = HOST_ONLY_MARKER.hex(" ")
        with patch("run_browser_tests.subprocess.check_output", side_effect=[
            "x86_64\n", f"demo:\nContents of (__TEXT,__barkhostonly) section\n0010 {marker}\n",
        ]):
            self.assertEqual((self.binary, file_identity(self.binary)),
                             require_host_only_image(self.binary))

    def test_fat_mixed_architecture_image_is_rejected(self):
        with patch("run_browser_tests.subprocess.check_output", return_value="x86_64 arm64\n"):
            with self.assertRaisesRegex(ValueError, "thin macOS Bark"):
                require_host_only_image(self.binary)

    @unittest.skipUnless(sys.platform == "darwin", "requires Apple's Mach-O tools")
    def test_inspects_cross_built_arm_marker_without_running_the_image(self):
        source = self.checkout / "marker.c"
        source.write_text('__attribute__((used, section("__TEXT,__barkhostonly")))\n'
                          'static const char marker[] = "BARK_MAC_HOST_ONLY_FACTORY_V1";\n'
                          'int main(void) { return 0; }\n')
        subprocess.run(["xcrun", "clang", "-arch", "arm64", source, "-o", self.binary], check=True)
        self.assertEqual((self.binary, file_identity(self.binary)),
                         require_host_only_image(self.binary, expected_arch="arm64"))
        with self.assertRaisesRegex(ValueError, "Expected x86_64"):
            require_host_only_image(self.binary, expected_arch="x86_64")

    def test_new_runner_with_old_companion_framework_is_rejected(self):
        with patch("run_browser_tests.require_host_only_image", side_effect=[
            (self.binary, file_identity(self.binary)), ValueError("old framework"),
        ]) as inspect:
            with self.assertRaisesRegex(ValueError, "old framework"):
                require_host_only_runtime(self.binary)
        self.assertEqual(self.binary.parent / TEST_FRAMEWORK, inspect.call_args.args[0])

    def test_old_product_framework_is_rejected_after_new_test_framework(self):
        with patch("run_browser_tests.require_host_only_image", side_effect=[
            Mock(), Mock(), ValueError("old product framework"),
        ]) as inspect:
            with self.assertRaisesRegex(ValueError, "old product framework"):
                require_host_only_runtime(self.binary)
        self.assertEqual(self.binary.parent / APP_FRAMEWORK, inspect.call_args.args[0])

    def test_rejection_happens_before_screen_lock_or_test_execution(self):
        chrome = self.checkout / "chrome"
        chrome.mkdir()
        (chrome / "VERSION").touch()
        args = ["runner", "--checkout", str(self.checkout), "--binary", str(self.binary)]
        with patch.object(sys, "argv", args), patch.object(sys, "platform", "darwin"), \
                patch("run_browser_tests.require_host_only_runtime",
                      side_effect=ValueError("Missing the compiled capability")), \
                patch("run_browser_tests.screen_lock") as lock, \
                patch("run_browser_tests.run_tests") as launch, \
                patch("run_browser_tests.sys.stderr", new_callable=io.StringIO):
            self.assertEqual(1, main())
        lock.assert_not_called()
        launch.assert_not_called()


class BrowserTestProcessTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.cwd = directory.name
        self.console = Mock()
        self.console.available.return_value = True
        self.console.pointer.return_value = (0, 0)
        self.console.idle.return_value = 60

    def test_busy_console_never_starts_the_test_process(self):
        self.console.idle.return_value = 1
        with patch("run_browser_tests.subprocess.Popen") as launch:
            with self.assertRaisesRegex(ScreenUnavailable, "user is active"):
                run_tests(["/usr/bin/true"], self.cwd, self.console, lambda: True, 20, 3)
        launch.assert_not_called()

    def test_replaced_binary_never_starts_the_test_process(self):
        candidate = Path(self.cwd) / "candidate"
        candidate.write_bytes(b"verified")
        identity = file_identity(candidate)
        candidate.write_bytes(b"replacement")
        with patch("run_browser_tests.subprocess.Popen") as launch:
            with self.assertRaisesRegex(ValueError, "changed before launch"):
                run_tests([str(candidate)], self.cwd, self.console, lambda: True,
                          20, 3, [(candidate, identity)])
        launch.assert_not_called()

    def test_lock_replacement_stops_launched_process(self):
        launcher = subprocess.Popen
        processes = []

        def launch(*args, **kwargs):
            process = launcher(*args, **kwargs)
            processes.append(process)
            return process

        owned = Mock(side_effect=[True, False])
        with patch("run_browser_tests.subprocess.Popen", side_effect=launch):
            with self.assertRaisesRegex(ScreenUnavailable, "ownership changed"):
                run_tests(["/bin/sleep", "30"], self.cwd, self.console, owned, 20, 3)
        self.assertEqual(1, len(processes))
        self.assertEqual(-signal.SIGTERM, processes[0].returncode)


if __name__ == "__main__":
    unittest.main()
