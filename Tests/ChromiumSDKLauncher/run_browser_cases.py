#!/usr/bin/env python3
"""Run named Chromium regressions with the Bark screen guard and require each result."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
RUNNER = REPO / "Runtime/Chromium/run_browser_tests.py"
EXACT_TEST = re.compile(r"[A-Za-z0-9_/]+\.[A-Za-z0-9_/]+")


def verify_results(summary, names):
    data = json.loads(summary.read_text())
    if not isinstance(data, dict):
        raise ValueError("Expected a Chromium test summary object")
    tags = data.get("global_tags")
    iterations = data.get("per_iteration_data")
    if (not isinstance(tags, list) or "EARLY_SUMMARY" in tags or
            not isinstance(iterations, list) or len(iterations) != 1 or
            not isinstance(iterations[0], dict)):
        raise ValueError("Expected one completed Chromium test iteration")
    results = iterations[0]
    for name in names:
        if name not in results:
            raise ValueError(f"Chromium did not report a result for {name}")
        rows = results[name]
        if (not isinstance(rows, list) or len(rows) != 1 or
                not isinstance(rows[0], dict) or rows[0].get("status") != "SUCCESS"):
            raise ValueError(f"Expected exactly one successful attempt for {name}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--fixture-source", type=Path, help="require the archived fixture hash to match this source")
    parser.add_argument("--sdk-metadata", type=Path, help="require the framework from the checkout’s pinned SDK")
    parser.add_argument("tests", nargs="+", metavar="Suite.Case")
    args = parser.parse_args(argv)
    if len(set(args.tests)) != len(args.tests) or any(not EXACT_TEST.fullmatch(name) for name in args.tests):
        parser.error("provide distinct exact gtest names in Suite.Case form")

    try:
        checks = []
        if args.fixture_source is not None:
            checks.extend(["--fixture-source", args.fixture_source])
        if args.sdk_metadata is not None:
            checks.extend(["--sdk-metadata", args.sdk_metadata])
        result = subprocess.run([
            sys.executable, "-B", RUNNER, "--checkout", args.checkout,
            "--binary", args.binary, "--summary", args.summary,
            *checks, "--filter", ":".join(args.tests),
        ], check=False)
        if result.returncode:
            return result.returncode if result.returncode > 0 else 128 - result.returncode
        verify_results(args.summary, args.tests)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Verified {len(args.tests)} exact Chromium test results in {args.summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
