#!/usr/bin/env python3
"""Run Bark's Chromium browser tests while the local Mac console is idle."""

import argparse
import contextlib
import ctypes
import math
import os
import re
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from chromium_sdk_layout import GN_CPU, native_architecture, read_pin
from chromium_test_runtime import APP_FRAMEWORK, TEST_FRAMEWORK, verify_manifest
from publish_chromium_sdk import sdk_manifest

SCREEN_LOCK = Path("/private/tmp/nook-screen-lock")
SCREEN_UNAVAILABLE = 3
HOST_ONLY_MARKER = b"BARK_MAC_HOST_ONLY_FACTORY_V1\0"


def file_identity(path):
    info = path.stat()
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def require_host_only_image(path, expected_arch=None):
    """Inspect linked code without invoking the browser test executable."""
    try:
        identity = file_identity(path)
        arches = subprocess.check_output(
            ["/usr/bin/lipo", "-archs", str(path)], stderr=subprocess.PIPE, text=True
        ).split()
        if len(arches) != 1 or arches[0] not in ("arm64", "x86_64"):
            raise ValueError(f"Expected a thin macOS Bark image: {path} ({' '.join(arches)})")
        arch = arches[0]
        if expected_arch is not None and arch != expected_arch:
            raise ValueError(f"Expected {expected_arch} for native test execution: {path} ({arch})")
        sections = subprocess.check_output(
            ["/usr/bin/otool", "-s", "__TEXT", "__barkhostonly", str(path)],
            stderr=subprocess.PIPE, text=True,
        ).splitlines()
        heading = "Contents of (__TEXT,__barkhostonly) section"
        groups = [line.split()[1:] for line in sections[2:]]
        # otool prints bytes on Intel and little-endian words on ARM. A final
        # partial word can appear as individual bytes on ARM.
        words = (bytes.fromhex(word) for group in groups for word in group)
        data = b"".join(word[::-1] if arch == "arm64" else word for word in words)
        if len(sections) < 2 or sections[1] != heading or data != HOST_ONLY_MARKER:
            raise ValueError(f"Missing the compiled Bark host-only factory capability: {path}")
        if file_identity(path) != identity:
            raise ValueError(f"Test runtime changed during inspection: {path}")
        return path, identity
    except subprocess.CalledProcessError as error:
        raise ValueError(f"Cannot inspect the Bark test runtime: {path}") from error


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


class ScreenUnavailable(Exception):
    pass


def directory_identity(info):
    return info.st_dev, info.st_ino


@contextlib.contextmanager
def screen_lock(path, wait):
    deadline = time.monotonic() + wait
    while True:
        try:
            path.mkdir(mode=0o700)
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise ScreenUnavailable(f"Screen mutex is already held at {path}")
            time.sleep(min(0.5, max(0, deadline - time.monotonic())))

    directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    identity = directory_identity(os.fstat(directory))

    def owned():
        try:
            current = path.lstat()
        except FileNotFoundError:
            return False
        return stat.S_ISDIR(current.st_mode) and directory_identity(current) == identity

    owner = None
    try:
        owner = os.open(
            "pid", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600, dir_fd=directory,
        )
        with os.fdopen(owner, "w") as record:
            record.write(f"{os.getpid()}\n")
        yield owned
    finally:
        try:
            if owner is not None:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink("pid", dir_fd=directory)
            if owned():
                with contextlib.suppress(FileNotFoundError):
                    path.rmdir()
        finally:
            os.close(directory)


class QuartzConsole:
    class Point(ctypes.Structure):
        _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

    def __init__(self):
        core = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        quartz = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        self.core = ctypes.CDLL(core)
        self.quartz = ctypes.CDLL(quartz)

        ptr = ctypes.c_void_p
        self.core.CFRelease.argtypes = [ptr]
        self.core.CFRelease.restype = None
        self.core.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
        self.core.CFStringCreateWithCString.restype = ptr
        self.core.CFDictionaryGetValue.argtypes = [ptr, ptr]
        self.core.CFDictionaryGetValue.restype = ptr
        self.core.CFBooleanGetValue.argtypes = [ptr]
        self.core.CFBooleanGetValue.restype = ctypes.c_bool
        self.quartz.CGSessionCopyCurrentDictionary.argtypes = []
        self.quartz.CGSessionCopyCurrentDictionary.restype = ptr
        self.quartz.CGEventSourceSecondsSinceLastEventType.argtypes = [
            ctypes.c_int32, ctypes.c_uint32,
        ]
        self.quartz.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
        self.quartz.CGEventCreate.argtypes = [ptr]
        self.quartz.CGEventCreate.restype = ptr
        self.quartz.CGEventGetLocation.argtypes = [ptr]
        self.quartz.CGEventGetLocation.restype = self.Point

    def session_flag(self, session, name):
        utf8 = 0x08000100
        key = self.core.CFStringCreateWithCString(None, name, utf8)
        try:
            value = self.core.CFDictionaryGetValue(session, key)
            return bool(value and self.core.CFBooleanGetValue(value))
        finally:
            self.core.CFRelease(key)

    def available(self):
        session = self.quartz.CGSessionCopyCurrentDictionary()
        if not session:
            return False
        try:
            return (
                self.session_flag(session, b"kCGSSessionOnConsoleKey")
                and self.session_flag(session, b"kCGSessionLoginDoneKey")
                and not self.session_flag(session, b"CGSSessionScreenIsLocked")
            )
        finally:
            self.core.CFRelease(session)

    def pointer(self):
        event = self.quartz.CGEventCreate(None)
        if not event:
            raise ScreenUnavailable("Quartz pointer is unavailable")
        try:
            point = self.quartz.CGEventGetLocation(event)
            return point.x, point.y
        finally:
            self.core.CFRelease(event)

    def idle(self):
        hid_system_state = 1
        any_event = 0xffffffff
        return self.quartz.CGEventSourceSecondsSinceLastEventType(
            hid_system_state, any_event
        )


def require_idle_console(console, owns_screen, pointer, min_idle):
    if not owns_screen():
        raise ScreenUnavailable("Screen mutex ownership changed")
    if not console.available():
        raise ScreenUnavailable("The Mac console is locked or unavailable")
    if console.pointer() != pointer or console.idle() < min_idle:
        raise ScreenUnavailable("The user is active on the Mac console")


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


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


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
