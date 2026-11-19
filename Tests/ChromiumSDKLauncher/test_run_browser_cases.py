"""Exercise exact Chromium selection and completed summary checks offline."""

from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import run_browser_cases as cases


class BrowserCasesTests(unittest.TestCase):
    names = ("BarcSharedPawlBrowserTest.VaultSaveRefusesMountedPrivateProfile",
             "BarcSharedPawlBrowserTest.VaultRequestsRetireWhenSelectedHostPageChanges")

    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.summary = Path(directory.name) / "results.json"
        self.args = ["--checkout", "/fixture/src", "--binary", "/fixture/bark_browser_tests",
                     "--summary", str(self.summary)]

    def fixture(self, results, *tags):
        self.summary.write_text(json.dumps({
            "all_tests": list(self.names),
            "global_tags": tags,
            "per_iteration_data": [results],
        }))

    def invoke(self, expected, launcher_code=0):
        with patch.object(cases.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], launcher_code
        )) as launch, redirect_stdout(StringIO()), redirect_stderr(StringIO()) as stderr:
            self.assertEqual(cases.main([*self.args, *self.names]), expected)
            launch.assert_called_once()
            command = launch.call_args.args[0]
            self.assertIn(cases.RUNNER, command)
            self.assertEqual(command[command.index("--fixture-tree") + 1], cases.REPO / "Runtime/Chromium/bark/test")
            self.assertEqual(command[-2:], ["--filter", ":".join(self.names)])
        return stderr.getvalue()

    def test_guarded_summary_requires_all_named_cases(self):
        success = [{"status": "SUCCESS"}]
        self.fixture(dict.fromkeys(self.names, success))
        self.invoke(0)
        self.fixture({self.names[1]: success})
        self.assertIn(self.names[0], self.invoke(1))
        self.fixture({})
        self.assertIn(self.names[0], self.invoke(1))

    def test_retries_and_non_success_attempts_are_refused(self):
        for statuses in (("FAILURE", "SUCCESS"), ("SKIPPED",), ("NOTRUN",)):
            with self.subTest(statuses=statuses):
                self.fixture({self.names[0]: [{"status": status} for status in statuses],
                              self.names[1]: [{"status": "SUCCESS"}]})
                self.assertIn("exactly one", self.invoke(1))

    def test_guard_exit_propagates_and_early_summary_fails(self):
        self.assertEqual(self.invoke(3, launcher_code=3), "")
        self.fixture(dict.fromkeys(self.names, [{"status": "SUCCESS"}]), "EARLY_SUMMARY")
        self.assertIn("completed", self.invoke(1))

    def test_explicit_fixture_tree_and_sdk_are_passed_to_the_guarded_runner(self):
        fixture = self.summary.with_name("bark-test")
        sdk = self.summary.with_name("sdk-metadata")
        self.args.extend(("--fixture-tree", str(fixture), "--sdk-metadata", str(sdk)))
        self.fixture(dict.fromkeys(self.names, [{"status": "SUCCESS"}]))
        with patch.object(cases.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as launch:
            self.assertEqual(cases.main([*self.args, *self.names]), 0)
        command = launch.call_args.args[0]
        self.assertEqual(command[command.index("--fixture-tree") + 1], fixture)
        self.assertEqual(command[command.index("--sdk-metadata") + 1], sdk)

    def test_wildcard_is_rejected_before_launch(self):
        with patch.object(cases.subprocess, "run") as launch, redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit) as error:
                cases.main([*self.args, "BarcSharedPawlBrowserTest.*"])
            self.assertEqual(error.exception.code, 2)
            launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
