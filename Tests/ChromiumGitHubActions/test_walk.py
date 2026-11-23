"""Check where the public Actions page walk agrees to run."""
import argparse
import contextlib
import io
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import walk


def parse_options(environment, *arguments):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-official", action="store_true")
    argv = ["walk.py", "--app", "/fixture/Bark.app", "--output", "/fixture/evidence", *arguments]
    with patch.dict(os.environ, environment, clear=True), patch.object(sys, "argv", argv), \
            contextlib.redirect_stderr(io.StringIO()):
        return walk.parse_options(parser)


class RunnerTests(unittest.TestCase):
    def test_hosted_runner_visits_the_page(self):
        args = parse_options({"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}, "--require-official")
        self.assertTrue(args.require_official)

    def test_self_hosted_release_runner_visits_the_page(self):
        args = parse_options({"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"}, "--require-official")
        self.assertTrue(args.require_official)

    def test_local_run_is_refused(self):
        with self.assertRaises(SystemExit):
            parse_options({"RUNNER_ENVIRONMENT": "self-hosted"}, "--require-official")

    def test_official_sdk_is_required(self):
        with self.assertRaises(SystemExit):
            parse_options({"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"})


if __name__ == "__main__":
    unittest.main()
