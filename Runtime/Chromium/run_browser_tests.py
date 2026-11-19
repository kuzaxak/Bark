#!/usr/bin/env python3
"""Run Bark's Chromium browser tests while the local Mac console is idle."""

import argparse
import contextlib
import math
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from bark_macos_console import (SCREEN_LOCK, SCREEN_UNAVAILABLE, QuartzConsole, ScreenUnavailable,
                                interrupted, require_idle_console, screen_lock)
from chromium_sdk_layout import GN_CPU, file_identity, native_architecture, read_pin, require_host_only_image
from chromium_test_runtime import APP_FRAMEWORK, TEST_FRAMEWORK, verify_manifest
from publish_chromium_sdk import sdk_manifest

def pinned_framework_digest(metadata, arch):
    pin, checksums = sdk_manifest(metadata)
    repo = Path(__file__).resolve().parents[2]
    if read_pin(repo / "Packages/BarkEngine", arch) != pin:
        raise ValueError(f"The supplied SDK manifest differs from the checkout's {arch} pin")
    version = Path(__file__).with_name("CHROMIUM_VERSION").read_text().strip()
    image = f"Bark Framework.framework/Versions/{version}/Bark Framework"
    if image not in checksums:
        raise ValueError(f"The pinned SDK manifest lacks the Chromium {version} framework")
    return checksums[image]


def require_host_only_runtime(binary, expected_fixture=None, sdk_metadata=None, expected_tree=None):
    # Chromium's test launcher resolves its framework beside the executable.
    # The product bundle can launch helpers through its own framework copy.
    arch = native_architecture()
    images = tuple(require_host_only_image(path, expected_arch=arch) for path in (
        binary, binary.parent / TEST_FRAMEWORK, binary.parent / APP_FRAMEWORK,
    ))
    framework_digest = verify_manifest(binary, expected_fixture, expected_tree)
    if sdk_metadata is not None and framework_digest != pinned_framework_digest(sdk_metadata, arch):
        raise ValueError("Browser-test framework differs from the checkout's pinned SDK")
    return images


def listed_tests(transcript):
    """Read the suite and test names printed by GoogleTest."""
    names = set()
    suite = None
    for line in transcript.splitlines():
        name = line.partition("#")[0].strip()
        if re.fullmatch(r"[A-Za-z0-9_/]+\.", name) and not line.startswith(" "):
            suite = name
        elif suite and line.startswith("  ") and re.fullmatch(r"[A-Za-z0-9_/]+", name):
            names.add(suite + name)
        else:
            suite = None
    if not names:
        raise ValueError("The linked browser test binary listed no tests")
    return names


def require_filter_matches(tests, test_filter):
    if not test_filter:
        return
    included, _, excluded = test_filter.partition("-")

    def expressions(patterns):
        return [re.compile(re.escape(pattern).replace(r"\*", ".*").replace(r"\?", "."))
                for pattern in patterns.split(":") if pattern]

    skip = expressions(excluded)
    enabled = [name for name in tests if not any(
        part.startswith("DISABLED_") for part in re.split(r"[./]", name)
    ) and not any(pattern.fullmatch(name) for pattern in skip)]
    positive = expressions(included or "*")
    if not positive:
        raise ValueError("Browser-test filter must select at least one linked test")
    for expression in positive:
        if not any(expression.fullmatch(name) for name in enabled):
            raise ValueError(f"Browser-test filter has no enabled linked match: {expression.pattern}")


def stop_tests(process):
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def run_tests(command, checkout, console, owns_screen, min_idle, timeout, verified_files=()):
    pointer = console.pointer()
    time.sleep(0.4)
    require_idle_console(console, owns_screen, pointer, min_idle)

    for path, identity in verified_files:
        if file_identity(path) != identity:
            raise ValueError(f"Test runtime changed before launch: {path}")

    deadline = time.monotonic() + timeout
    with subprocess.Popen(command, cwd=checkout, start_new_session=True) as process:
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    return process.wait(timeout=min(0.5, remaining))
                except subprocess.TimeoutExpired:
                    require_idle_console(console, owns_screen, pointer, 1.5)
        except (ScreenUnavailable, subprocess.TimeoutExpired, KeyboardInterrupt):
            stop_tests(process)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True, help="Chromium src directory")
    parser.add_argument("--binary", type=Path, help="bark_browser_tests path (defaults to the native developer build)")
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--fixture-source", type=Path, help="legacy archived overlay check for one source")
    sources.add_argument("--fixture-tree", type=Path, help="require the linked browser-test sources to match this directory")
    parser.add_argument("--sdk-metadata", type=Path, help="compare the framework to the pinned SDK directory’s SHA256SUMS")
    parser.add_argument("--filter", help="Chromium gtest filter. Defaults to the full suite.")
    parser.add_argument("--list-tests", action="store_true", help="list linked tests without running them")
    parser.add_argument("--summary", type=Path, help="New path for Chromium's JSON test summary")
    parser.add_argument("--wait", type=float, default=15, help="Seconds to wait for the screen mutex")
    parser.add_argument("--min-idle", type=float, default=20, help="Required seconds of HID idle time")
    parser.add_argument("--timeout", type=float, default=1800, help="Test launcher timeout in seconds")
    args = parser.parse_args()

    if sys.platform != "darwin":
        parser.error("the local screen guard requires macOS")
    if not (args.checkout / "chrome" / "VERSION").is_file():
        parser.error("--checkout must point to the Chromium src directory")
    target = args.binary or args.checkout / "out" / f"Barc-{GN_CPU[native_architecture()]}" / "bark_browser_tests"
    if target.name != "bark_browser_tests" or not target.is_file() or not os.access(target, os.X_OK):
        parser.error(f"Expected the executable bark_browser_tests at {target}")
    if (not all(math.isfinite(seconds) for seconds in
                (args.wait, args.min_idle, args.timeout))
            or args.wait < 0 or args.min_idle < 2 or args.timeout <= 0):
        parser.error("require --wait >= 0, --min-idle >= 2, and --timeout > 0")
    binary = target.resolve()
    command = [
        str(binary),
        "--test-launcher-jobs=1",
        "--test-launcher-batch-limit=1",
        "--test-launcher-retry-limit=0",
        "--use-mock-keychain",
    ]
    if args.filter:
        command.append(f"--gtest_filter={args.filter}")
    if args.summary:
        if args.summary.exists() or args.summary.is_symlink():
            parser.error("--summary must be a new file")
        command.append(f"--test-launcher-summary-output={args.summary.absolute()}")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        verified_files = require_host_only_runtime(binary, args.fixture_source, args.sdk_metadata, args.fixture_tree)
        if args.list_tests or (args.fixture_tree is not None and args.filter):
            if any(file_identity(path) != identity for path, identity in verified_files):
                raise ValueError("Test runtime changed before listing")
            listing = subprocess.check_output([binary, "--use-mock-keychain", "--gtest_list_tests"],
                                              cwd=args.checkout, text=True, timeout=min(args.timeout, 60))
            require_filter_matches(listed_tests(listing), args.filter)
            if args.list_tests:
                print(listing, end="")
                return 0
        with screen_lock(SCREEN_LOCK, args.wait) as owns_screen:
            result = run_tests(
                command, args.checkout, QuartzConsole(), owns_screen,
                args.min_idle, args.timeout, verified_files,
            )
            return result if result >= 0 else 128 - result
    except ScreenUnavailable as error:
        print(error, file=sys.stderr)
        return SCREEN_UNAVAILABLE
    except subprocess.TimeoutExpired:
        print(f"Browser tests timed out after {args.timeout:g} seconds", file=sys.stderr)
        return 124
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
