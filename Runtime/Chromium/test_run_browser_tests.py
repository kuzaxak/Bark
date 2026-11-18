"""Headless checks for the local Chromium browser-test runner."""

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from run_browser_tests import ScreenUnavailable, run_tests, screen_lock


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
