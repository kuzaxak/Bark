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
from chromium_test_runtime import MANIFEST_NAME, create_manifest


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

    def test_archived_binary_and_fixture_are_verified_before_launch(self):
        binary = self.summary.with_name("bark_browser_tests")
        binary.write_bytes(b"linked fixture")
        fixture = self.summary.with_name("barc_bridge_browsertest.mm")
        fixture.write_text("the reviewed installed test fixture")
        manifest = binary.with_name(MANIFEST_NAME)
        self.args[self.args.index("--binary") + 1] = str(binary)
        self.args.extend(("--fixture-source", str(fixture)))
        self.fixture(dict.fromkeys(self.names, [{"status": "SUCCESS"}]))

        def refused(expected):
            with patch.object(cases.subprocess, "run") as launch, redirect_stderr(StringIO()) as stderr:
                self.assertEqual(cases.main([*self.args, *self.names]), 1)
                self.assertIn(expected, stderr.getvalue())
                launch.assert_not_called()

        refused("Expected a packaged")
        manifest.write_text(json.dumps(create_manifest(binary)))
        refused("differs from the expected source")
        manifest.write_text(json.dumps(create_manifest(binary, fixture)))
        self.invoke(0)
        fixture.write_text("an older fixture")
        refused("differs from the expected source")
        binary.write_bytes(b"another executable")
        refused("differs from its archived SHA-256")

    def test_wildcard_is_rejected_before_launch(self):
        with patch.object(cases.subprocess, "run") as launch, redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit) as error:
                cases.main([*self.args, "BarcSharedPawlBrowserTest.*"])
            self.assertEqual(error.exception.code, 2)
            launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
