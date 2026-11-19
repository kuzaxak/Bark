#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Build, verify and run the signed Bark app or its native regression checks."""

import argparse
from contextlib import contextmanager, ExitStack
import fcntl
import filecmp
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory
import time
from urllib.parse import urlsplit
from uuid import uuid4

# Keep contributor commands and signed walkers from writing into the checkout.
sys.dont_write_bytecode = True
# The signed walkers load this file with runpy rather than importing it.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from chromium_sdk_layout import (ARCHITECTURES, directory_id, download_https, local_engine, native_architecture,
                                 read_pin, remove_work, swap)
from bark_icloud_signing import BUNDLE_ID, PROFILE_NAME, authorized_entitlements, load_profile
from bark_outer_info import verify_build_info
from bark_release import (configure_release, expected_additions, make_distribution, make_personal_image,
                          production_settings, publish_new)
from bark_shell_boundary import verify_shell_boundary
from bark_shell_source import shell_source_digest, verify_shell_source, write_shell_source

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "Runtime/Chromium"))
from run_browser_tests import (SCREEN_LOCK, SCREEN_UNAVAILABLE, TEST_FRAMEWORK, QuartzConsole,
                               ScreenUnavailable, interrupted, require_host_only_image,
                               require_idle_console, screen_lock)

STAGE = REPO / "scripts/stage-chromium-app.sh"
PACKAGE = REPO / "Packages/BarkEngine"
MACH_CPU_TYPES = {"x86_64": 0x01000007, "arm64": 0x0100000c}
FRAMEWORK = "Bark Framework.framework"
MACH64 = b"\xcf\xfa\xed\xfe"
CODESIGN_LINKEDIT_ALIGNMENT = 16 * 1024


NATIVE_CHECKS = {
    "catalog": ("ChromiumCatalog", "run catalog and initial-window activation regressions"),
    "page-host": ("ChromiumPageHost", "check page ownership, transfer and close"),
    "profile-deletion": ("ChromiumProfileDeletion", "check asynchronous profile deletion and durable assignment"),
    "profile-pages": ("ChromiumProfilePages", "check profile utility window ownership"),
    "extension-actions": ("ChromiumExtensionActions", "check Chrome extension action snapshot ownership"),
    "live-fetch": ("ChromiumLiveFetch", "check Chromium live fetch and profile ownership"),
    "vault": ("ChromiumVaultSave", "check Pawl consent and picker ownership in the native shell"),
    "downloads": ("ChromiumDownloads", "check Chromium download ownership and file actions"),
    "blocker": ("ChromiumBlocker", "check first-page blocker readiness and per-profile policy publication"),
    "page-tweaks": ("ChromiumPageTweaks", "check that page tweaks publish before the first document"),
}


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def check_native_harness(command):
    # Xcode resolves the shell's real package graph and the headers in its SDK.
    # The harness supplies its own bridge table, so it runs without an Engine.
    architecture = native_architecture()
    if architecture not in ARCHITECTURES:
        raise ValueError(f"Unsupported macOS architecture: {architecture}")
    checkout = hashlib.sha256(os.fsencode(REPO)).hexdigest()[:16]
    # Keep the existing warm Intel cache and isolate the Silicon build products.
    cache_key = checkout if architecture == "x86_64" else f"{checkout}-{architecture}"
    derived = Path.home() / "Library/Caches/BarkSDK/native-checks" / cache_key
    derived.mkdir(parents=True, exist_ok=True)
    # Hold the cache across the executable's lifetime because the checks also
    # read frameworks and SwiftPM resource bundles from these build products.
    lock = os.open(derived, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        packages = derived / "SourcePackages"
        products = derived / "Build/Products/Debug"
        run("xcodebuild", "-project", REPO / "Bark.xcodeproj", "-scheme", "BarkNativeChecks",
            "-configuration", "Debug", "-destination", "generic/platform=macOS",
            "-derivedDataPath", derived, "-clonedSourcePackagesDirPath", packages,
            "-onlyUsePackageVersionsFromResolvedFile", f"ARCHS={architecture}", "CODE_SIGNING_ALLOWED=NO",
            "OTHER_SWIFT_FLAGS=$(inherited) -j2", "-jobs", "1", "build")
        # SwiftPM bundle lookup uses the executable directory for command-line tools.
        suite, _ = NATIVE_CHECKS[command]
        sys.path.insert(0, str(REPO / "Tests/Shared"))
        from bridge_fixture import write_bridge_fixture

        with TemporaryDirectory(prefix="bark-bridge-fixture-") as fixture:
            table = write_bridge_fixture(products / "include/BarcChromium/barc_bridge_api.h",
                                         Path(fixture) / "BridgeTable.swift")
            checks = ("Main", "Ownership") if command == "live-fetch" else ("Main",)
            for check in checks:
                # Put the executable beside the package bundles for SwiftPM's resource lookup.
                binary = products / f".bark-{command}-{check}-{uuid4()}"
                try:
                    run("xcrun", "swiftc", "-swift-version", "5", "-target", f"{architecture}-apple-macosx15.5",
                        "-parse-as-library", "-D", "BARK_CATALOG_FRAMEWORK", "-F", products, "-I", products,
                        "-I", products / "include",
                        "-framework", "NookNativeShell", "-Xlinker", "-rpath", "-Xlinker", products,
                        table, REPO / "Tests" / suite / f"{check}.swift", "-o", binary)
                    if command == "catalog":
                        # Background model tasks may hold the disposable database until exit.
                        with TemporaryDirectory(prefix="bark-catalog-") as scratch:
                            run("/usr/bin/env", f"TMPDIR={scratch}/", binary)
                    else:
                        run(binary)
                finally:
                    binary.unlink(missing_ok=True)
    finally:
        os.close(lock)


def cached_engine(architecture):
    return Path.home() / "Library/Caches/BarkSDK" / read_pin(PACKAGE, architecture) / "Engine"


def check_official_engine(engine, architecture):
    sys.path.insert(0, str(REPO / "Runtime/Chromium"))
    from official_provenance import verify_cached

    verify_cached(engine, architecture)
    print(f"Verified official Bark SDK provenance at {engine}", flush=True)


def verify_engine(engine, architecture, require_official):
    run("/bin/bash", STAGE, "--arch", architecture, "--check-engine", engine)
    if require_official:
        check_official_engine(engine, architecture)


def install_engine(engine, architecture, require_official=False):
    destination = cached_engine(architecture)
    directory = destination.parent
    directory.mkdir(parents=True, exist_ok=True)
    lock = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # A killed install can leave a partial copy or the old tree from a
        # successful swap in this pin's private staging directory.
        slot = directory / ".bark-installing"
        if engine.resolve().is_relative_to(directory.resolve() / slot.name):
            raise ValueError(f"Choose an SDK source outside the installer's temporary directory: {slot}")
        if directory_id(slot) is not None:
            remove_work(slot)
        if directory_id(destination) is not None:
            try:
                verify_engine(destination, architecture, require_official)
            except (subprocess.CalledProcessError, ValueError):
                if engine.resolve() == destination.resolve():
                    raise
                print(f"Repairing incomplete cached SDK at {destination}", flush=True)
            else:
                # Older archive installations could leave writable entries.
                if destination.stat().st_mode & 0o222 or any(
                        not path.is_symlink() and path.stat().st_mode & 0o222 for path in destination.rglob("*")):
                    run("/bin/chmod", "-R", "-P", "a-w", destination)
                print(f"Installed pinned SDK at {destination}")
                return
        slot.mkdir(mode=0o700)
        try:
            run("/usr/bin/ditto", engine, slot)
            run("/bin/chmod", "-R", "-P", "a-w", slot)
            verify_engine(slot, architecture, require_official)
            # macOS can exchange sealed sibling directories. Moving a sealed
            # directory across parents requires write access to the directory.
            destination.mkdir(exist_ok=True)
            swap(slot, destination)
        finally:
            remove_work(slot)
    finally:
        os.close(lock)
    print(f"Installed pinned SDK at {destination}")


@contextmanager
def pinned_engine(source, working, architecture, require_official=False):
    if not source:
        installed = cached_engine(architecture)
        local = local_engine(PACKAGE, architecture)
        if (installed / "SHA256SUMS").is_file():
            try:
                path = installed.resolve(strict=True)
                verify_engine(path, architecture, require_official)
            except (OSError, subprocess.CalledProcessError, ValueError):
                if not local.is_dir() or local.resolve() == installed.resolve():
                    raise
                print(f"Cached SDK verification failed at {installed}; checking {local}", flush=True)
            else:
                yield path
                return
        if not local.is_dir():
            raise ValueError("The pinned SDK is missing. Install it with bark-check.py engine --install "
                             "--engine PATH, or build it using Runtime/Chromium/README.md.")
        source = str(local)
    path = Path(source).expanduser()
    if not path.is_dir():
        if not hasattr(tarfile, "data_filter"):
            raise ValueError("Engine archives require Python with the tarfile data extraction filter.")
        archive = path
        if urlsplit(source).scheme == "https":
            archive = working / "engine.tar"
            download_https(source, archive)
        unpacked = working / "engine"
        with tarfile.open(archive, "r:*") as package:
            package.extractall(unpacked, filter="data")
        path = unpacked if (unpacked / "SHA256SUMS").is_file() else unpacked / "Engine"
    path = path.resolve(strict=True)
    verify_engine(path, architecture, require_official)
    yield path


def archive_engine(engine, output, architecture, require_official=False):
    output = output.expanduser().absolute()
    if output.is_symlink() or output.exists():
        raise FileExistsError(f"SDK archive already exists: {output}")
    if output.resolve().is_relative_to(engine.resolve()):
        raise ValueError("Choose an archive destination outside the SDK.")

    def portable_metadata(entry):
        entry.uid = entry.gid = entry.mtime = 0
        entry.uname = entry.gname = ""
        entry.mode = 0o555 if entry.isdir() or entry.issym() else 0o444 | (entry.mode & 0o111)
        return entry

    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix=".bark-sdk-", dir=output.parent) as stage:
        archive = Path(stage) / "sdk.tar.gz"
        with archive.open("xb") as raw, gzip.GzipFile(
                filename="", fileobj=raw, mode="wb", compresslevel=3, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|") as package:
                package.add(engine, arcname="Engine", filter=portable_metadata)
        # Read the exact bytes another checkout will receive before publishing.
        with TemporaryDirectory(prefix="bark-sdk-check-", dir="/private/tmp") as work:
            with pinned_engine(str(archive), Path(work), architecture, require_official):
                publish_new(archive, output)
    print(f"Wrote verified {architecture} SDK archive to {output}", flush=True)


def framework_files(directory):
    """Index files and symlinks, excluding files generated by codesign."""
    return {entry.relative_to(directory): entry for entry in directory.rglob("*")
            if (entry.is_symlink() or entry.is_file())
            and entry.relative_to(directory).parts[-2:] != ("_CodeSignature", "CodeResources")}


def mach_has_signature(path):
    with path.open("rb") as binary:
        magic, _, _, _, count, size, _, _ = struct.unpack("<IIIIIIII", binary.read(32))
        if magic != 0xfeedfacf:
            raise ValueError(f"Expected a thin Mach-O: {path}")
        commands = binary.read(size)
    offset = 0
    for _ in range(count):
        command, length = struct.unpack_from("<II", commands, offset)
        if length < 8 or offset + length > len(commands):
            raise ValueError(f"Invalid Mach-O load command: {path}")
        if command == 0x1d:
            return True
        offset += length
    return False


def remove_signature(source, destination):
    shutil.copyfile(source, destination)
    run("/usr/bin/codesign", "--remove-signature", destination)


def signed_mach_matches(original, signed, working, architecture):
    # arm64 ld can supply an ad-hoc signature on the published input.
    baseline = original
    if mach_has_signature(original):
        baseline = working / "unsigned-original"
        remove_signature(original, baseline)
    unsigned = working / "unsigned"
    remove_signature(signed, unsigned)
    payload_size = baseline.stat().st_size
    digest, vmsize = unsigned_mach_digest(baseline, payload_size, architecture)
    stripped_digest, _ = unsigned_mach_digest(unsigned, payload_size, architecture, vmsize, signed.stat().st_size)
    return digest == stripped_digest


def unsigned_mach_digest(path, payload_size, architecture, original_vmsize=None, signed_size=None):
    """Return the unsigned Mach-O digest and its original linkedit mapping size."""
    file_size = path.stat().st_size
    padded_size = (payload_size + 15) & ~15
    if not payload_size <= file_size <= padded_size:
        raise ValueError(f"Unexpected Mach-O size: {path}")
    with path.open("rb") as binary:
        header = binary.read(32)
        magic, cpu, _, _, count, size, _, _ = struct.unpack("<IIIIIIII", header)
        if magic != 0xfeedfacf or cpu != MACH_CPU_TYPES[architecture]:
            raise ValueError(f"Expected a thin {architecture} Mach-O: {path}")
        commands = bytearray(binary.read(size))
        offset = 0
        linkedit = False
        for _ in range(count):
            command, length = struct.unpack_from("<II", commands, offset)
            if length < 8 or offset + length > len(commands) or command == 0x1d:
                raise ValueError(f"Expected valid unsigned load commands: {path}")
            if command == 0x19 and commands[offset + 8:offset + 24].rstrip(b"\0") == b"__LINKEDIT":
                if linkedit or length < 72:
                    raise ValueError(f"Invalid Mach-O linkedit command: {path}")
                vmsize, file_offset, linkedit_size = struct.unpack_from("<QQQ", commands, offset + 32)
                if file_offset + linkedit_size != file_size or file_offset > payload_size:
                    raise ValueError(f"Invalid Mach-O linkedit extent: {path}")
                if original_vmsize is not None and vmsize != original_vmsize:
                    # Removing a signature can retain the mapping size that codesign
                    # rounded up from the signed __LINKEDIT extent.
                    if signed_size is None or signed_size <= file_size:
                        raise ValueError(f"Missing signed Mach-O extent: {path}")
                    signed_extent = signed_size - file_offset
                    aligned_extent = ((signed_extent + CODESIGN_LINKEDIT_ALIGNMENT - 1)
                                      // CODESIGN_LINKEDIT_ALIGNMENT * CODESIGN_LINKEDIT_ALIGNMENT)
                    if vmsize != aligned_extent:
                        raise ValueError(f"Unexpected Mach-O linkedit mapping size: {path}")
                    struct.pack_into("<Q", commands, offset + 32, original_vmsize)
                struct.pack_into("<Q", commands, offset + 48, payload_size - file_offset)
                linkedit = True
            offset += length
        if offset != len(commands) or not linkedit:
            raise ValueError(f"Missing Mach-O linkedit segment: {path}")
        digest = hashlib.sha256(header + commands)
        remaining = payload_size - binary.tell()
        while remaining > 0:
            block = binary.read(min(remaining, 1024 * 1024))
            if not block:
                raise ValueError(f"Truncated Mach-O: {path}")
            digest.update(block)
            remaining -= len(block)
        if any(binary.read()):
            raise ValueError(f"Unexpected nonzero Mach-O padding: {path}")
        return digest.digest(), vmsize


def verify_signed_shell(app, architecture=None):
    architecture = architecture or native_architecture()
    engine = app / "Contents/Frameworks" / TEST_FRAMEWORK
    run(sys.executable, "-B", REPO / "scripts/check-chromium-architectures.py",
        "--arch", architecture, "--app", app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    return require_host_only_image(engine, architecture)


def verify_candidate(app, engine, working, architecture, release_info=None, *,
                     shell_source=None, require_shell_source=False):
    verify_signed_shell(app, architecture)
    verify_shell_source(app, expected=shell_source, required=require_shell_source)
    run("/bin/bash", STAGE, "--arch", architecture, "--check-signed", app,
        expected_additions(release_info, working), engine)
    expected = framework_files(engine / FRAMEWORK)
    embedded = framework_files(app / "Contents/Frameworks" / FRAMEWORK)
    if expected.keys() != embedded.keys():
        difference = sorted(map(str, expected.keys() ^ embedded.keys()))
        raise ValueError(f"Candidate engine files differ from the pin: {', '.join(difference[:5])}")
    for relative, original in expected.items():
        signed = embedded[relative]
        if original.is_symlink() or signed.is_symlink():
            same = original.is_symlink() and signed.is_symlink() and original.readlink() == signed.readlink()
        elif filecmp.cmp(original, signed, shallow=False):
            same = True
        else:
            with original.open("rb") as binary:
                if binary.read(4) != MACH64:
                    raise ValueError(f"Candidate engine resource differs from the pin: {relative}")
            same = signed_mach_matches(original, signed, working, architecture)
        if not same:
            raise ValueError(f"Candidate engine differs from the pin: {relative}")
    print("Signed candidate contains the pinned engine's files.", flush=True)


class SmokePage(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            body = b"<!doctype html><title>Bark contributor smoke</title><script>fetch('/rendered')</script>"
        elif self.path == "/rendered":
            self.server.rendered = True
            body = b"ok"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def signal_candidate_group(proc, signum):
    try:
        os.killpg(proc.pid, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        if proc.poll() is None:
            raise
        # Darwin can report EPERM for a group with only exited members. Check
        # the whole group, since reaping the leader says nothing about helpers.
        rows = subprocess.check_output(["/bin/ps", "-axo", "pgid=,state="], text=True)
        group = str(proc.pid)
        if any(pgid == group and not state.startswith("Z")
               for pgid, state in (row.split() for row in rows.splitlines())):
            raise


def stop(proc):
    signal_candidate_group(proc, signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    signal_candidate_group(proc, signal.SIGKILL)
    proc.wait()


def seed_profile(root, space_id, url):
    # The app restores the initial tab from its model. Seed that tab directly
    # so a fresh profile neither depends on URL dispatch nor opens its default site.
    tab_id, window_id = (str(uuid4()).upper() for _ in range(2))
    now = time.time() - 978307200  # Swift Dates are relative to 2001-01-01.
    tabs = root / "App/Tabs"
    tabs.mkdir(parents=True)
    space = {"id": space_id, "name": "Smoke", "icon": "globe", "accentHex": "#265A8F",
             "order": "V", "modifiedAt": now}
    tab = {"id": tab_id, "kind": {"tab": {"url": url, "pageTitle": "Bark contributor smoke"}},
           "order": "V", "parent": {"tabs": {"spaceID": space_id}}, "modifiedAt": now}
    window = {"id": window_id, "frame": "{{50, 100}, {900, 660}}", "spaceID": space_id,
              "selectedItemBySpace": [space_id, tab_id]}
    (tabs / "structure.json").write_text(json.dumps({"formatVersion": 2, "spaces": [space], "items": []}))
    (tabs / "device.json").write_text(json.dumps({
        "formatVersion": 2, "items": [tab],
        "state": {"windows": [window], "closed": [], "openPages": [], "openFolders": [],
                  "firstLaunchCompleted": True},
    }))


@contextmanager
def smoke_console():
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        with screen_lock(SCREEN_LOCK, wait=15) as owns_screen:
            console = QuartzConsole()
            pointer = console.pointer()
            require_idle_console(console, owns_screen, pointer, min_idle=0)
            # Give the Return key that invoked the CLI time to leave the idle window.
            time.sleep(max(0, 10 - console.idle()))
            yield lambda min_idle: require_idle_console(console, owns_screen, pointer, min_idle)
    finally:
        signal.signal(signal.SIGTERM, previous)


def launch_candidate(app, engine, working, architecture, *, interactive, shell_source=None):
    profile = str(uuid4()).upper()
    root = working / "Profile"
    root.mkdir()
    domain = "ee.qdo.nook.chromium-verification." + hashlib.sha256(str(root).encode()).hexdigest()
    app_binary = app / "Contents/MacOS/Bark"
    # A speculative loopback connection must leave the guard free to poll.
    with ExitStack() as session, ThreadingHTTPServer(("127.0.0.1", 0), SmokePage) as server, \
            (working / "bark.log").open("wb") as log:
        server.timeout = .25
        server.rendered = False
        origin = f"http://127.0.0.1:{server.server_port}"
        seed_profile(root, profile, origin)
        # Join the installer's lock from verification through exec. Once the
        # child is running, install_local_build's process check protects it.
        with app_output_lock(app):
            verify_candidate(app, engine, working, architecture, shell_source=shell_source)
            if not interactive:
                check_console = session.enter_context(smoke_console())
                check_console(10)
            proc = subprocess.Popen([str(app_binary), f"--barc-app-data-dir={root}",
                                     f"--barc-app-profile={profile}"],
                                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        spontaneous_status = None
        try:
            deadline = time.monotonic() + 45
            while not server.rendered and time.monotonic() < deadline and proc.poll() is None:
                server.handle_request()
                if not interactive:
                    check_console(1.5)
            if not server.rendered or proc.poll() is not None:
                raise ValueError(f"Bark did not acknowledge the fixture (exit status {proc.poll()}).")
            if interactive:
                print("Bark is ready with an isolated profile. Quit Bark or press Ctrl+C here to end the session.",
                      flush=True)
                while proc.poll() is None:
                    server.handle_request()
                spontaneous_status = proc.returncode
        finally:
            stop(proc)
            subprocess.run(["/usr/bin/defaults", "delete", domain], capture_output=True)
            messages = (working / "bark.log").read_text(errors="replace")
            fatal = any(word in messages for word in ("FATAL", "Check failed"))
            if not server.rendered or fatal or spontaneous_status:
                print(messages[-12000:], file=sys.stderr)
            if fatal and not spontaneous_status:
                raise ValueError("Bark logged a fatal error.")
        if spontaneous_status:
            raise ValueError(f"Bark exited with status {spontaneous_status}.")
    if not interactive:
        print("Signed Bark rendered the loopback fixture with an isolated profile.")


@contextmanager
def app_output_lock(app, *, replacing=False):
    parent = os.open(app.parent, os.O_RDONLY)
    try:
        fcntl.flock(parent, fcntl.LOCK_EX if replacing else fcntl.LOCK_SH)
        yield
    finally:
        os.close(parent)


def install_local_build(app, output, bundle_id="ee.qdo.bark"):
    # Work and destination share a volume. Swap complete bundles in one
    # operation so readers see a verified app even if a rebuild is interrupted.
    with app_output_lock(output, replacing=True):
        if output.is_symlink():
            raise ValueError(f"Choose a local output directory instead of a symlink: {output}")
        if not output.exists():
            app.rename(output)
            return
        info = output / "Contents/Info.plist"
        if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != bundle_id:
            raise ValueError(f"Output already exists and is not a Bark bundle: {output}")
        processes = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True)
        if any(path.strip().startswith(str(output) + "/") for path in processes.splitlines()):
            raise ValueError(f"Quit the running copy before rebuilding {output}")
        swap(app, output)


def release_shell_build_args(derived, architecture):
    """Build the unsigned Release shell for signing and installed update rehearsals."""
    return ("xcodebuild", "-project", REPO / "Bark.xcodeproj", "-scheme", "Bark",
            "-configuration", "Release", "-destination", "generic/platform=macOS",
            "-derivedDataPath", derived, "-onlyUsePackageVersionsFromResolvedFile",
            f"ARCHS={architecture}", "CODE_SIGNING_ALLOWED=NO", "OTHER_SWIFT_FLAGS=$(inherited) -j4",
            "-jobs", "2", "build")


def unregister_unsigned_shell(app):
    # Xcode registers its background build component even for unsigned builds.
    if app.exists():
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Versions/Current/"
                        "Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister",
                        "-u", str(app)], capture_output=True)


def verify_xcode_component(app):
    verify_build_info(plistlib.loads((app / "Contents/Info.plist").read_bytes()))
    receipt = app / "Contents/Resources/BarkEngineSDK.sha256"
    if receipt.exists() or receipt.is_symlink():
        raise ValueError("The Xcode build component already contains a staged SDK receipt")


def check_release_shell(architecture):
    with TemporaryDirectory(prefix="bark-shell-", dir="/private/tmp") as directory:
        derived = Path(directory) / "DerivedData"
        products = derived / "Build/Products/Release"
        app = products / "Bark.app"
        try:
            run(*release_shell_build_args(derived, architecture))
            verify_xcode_component(app)
            for image in (app / "Contents/MacOS/Bark",
                          products / "NookNativeShell.framework/Versions/A/NookNativeShell"):
                run(sys.executable, "-B", REPO / "scripts/check-chromium-architectures.py",
                    "--arch", architecture, "--shell-image", image)
        finally:
            unregister_unsigned_shell(app)
    print(f"Built and verified the unsigned {architecture} Bark Release shell.")


def build_candidate(engine, output, identity, architecture, release_info=None, icloud_profile=None):
    if not identity:
        raise ValueError("Supply --identity or BARK_SIGN_IDENTITY for local Developer ID signing.")
    if icloud_profile is not None:
        authorized_entitlements(load_profile(icloud_profile), BUNDLE_ID)
    if output.name != "Bark.app":
        raise ValueError("The build output must be named Bark.app.")
    output = output.parent.expanduser().resolve() / output.name
    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix=".bark-build-", dir=output.parent) as directory:
        work = Path(directory)
        derived = work / "DerivedData"
        products = derived / "Build/Products/Release"
        stage = work / "stage"
        stage.mkdir()
        unsigned = products / "Bark.app"
        try:
            source = shell_source_digest(REPO)
            run(*release_shell_build_args(derived, architecture))
            verify_xcode_component(unsigned)
            run("/bin/bash", STAGE, "--arch", architecture, unsigned, engine, products, stage / "Bark.app",
                REPO / "ChromiumApp/Additions.plist")
            if shell_source_digest(REPO) != source:
                raise ValueError("Bark shell source inputs changed during the build. Run the build again.")
            write_shell_source(stage / "Bark.app", source)
            if release_info:
                configure_release(stage / "Bark.app", release_info)
            signed = work / "signed"
            signing = [sys.executable, "-B", REPO / "scripts/sign-bark-local.py", "--identity", identity]
            if icloud_profile is not None:
                signing.extend(("--icloud-profile", icloud_profile))
            run(*signing, stage, signed)
            app = signed / "stable/Bark.app"
            verify_candidate(app, engine, work, architecture, release_info, shell_source=source)
            if icloud_profile is not None and not filecmp.cmp(
                    stage / "Bark.app/Contents" / PROFILE_NAME,
                    app / "Contents" / PROFILE_NAME, shallow=False):
                raise ValueError("The signed app does not contain the requested iCloud profile.")
            signed_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if any(signed_info.get(key) != value for key, value in (release_info or {}).items()):
                raise ValueError("The signed bundle differs from the requested release settings.")
            install_local_build(app, output, signed_info["CFBundleIdentifier"])
        finally:
            unregister_unsigned_shell(unsigned)
    print(f"Built and verified {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("interaction", help="run the native command-window regression")
    for name, (_, help_text) in NATIVE_CHECKS.items():
        commands.add_parser(name, help=help_text)
    pair = commands.add_parser("pair-sdk", help="stage matching Intel and ARM64 official SDK metadata together")
    pair.add_argument("--x86-64", type=Path, required=True, help="published Intel Engine or its transfer metadata directory")
    pair.add_argument("--arm64", type=Path, required=True, help="published ARM64 Engine or its transfer metadata directory")
    pair.add_argument("--package", type=Path, required=True, help="receiver checkout's Packages/BarkEngine")
    fingerprint = commands.add_parser("shell-source", help="print the SHA-256 of local Bark shell inputs")
    fingerprint.add_argument("--source", type=Path, default=REPO, help="Bark checkout or source archive extracted to a directory")
    shell = commands.add_parser("shell", help="build and check the unsigned Bark Release shell")
    shell.add_argument("--arch", required=True, choices=ARCHITECTURES)
    for command in ("engine", "build", "verify", "smoke", "launch", "dmg", "package"):
        sub = commands.add_parser(command)
        sub.add_argument("--arch", choices=ARCHITECTURES, help="SDK architecture (default: native hardware)")
        sub.add_argument("--engine", default=os.environ.get("BARK_ENGINE_SOURCE"),
                         help="pinned engine directory, tar archive, or HTTPS tar archive")
        sub.add_argument("--require-official", action="store_true", help="require verified official engine provenance")
        if command == "engine":
            sub.add_argument("--install", action="store_true", help="cache the verified SDK for clean checkouts")
            sub.add_argument("--archive", type=Path, metavar="FILE", help="write a verified gzip tar archive to a new file")
        elif command == "build":
            sub.add_argument("--output", type=Path, default=REPO / "build/Bark.app")
            sub.add_argument("--identity", default=os.environ.get("BARK_SIGN_IDENTITY"),
                             help="local Developer ID Application signing identity")
            sub.add_argument("--icloud-profile", type=Path, help="opt in with a Developer ID profile for Bark")
            sub.add_argument("--release-version", help="Bark marketing version for an updatable release")
            sub.add_argument("--build-number", help="increasing Sparkle build number")
            sub.add_argument("--feed-base-url", help="HTTPS directory serving the architecture-specific Bark feed")
        else:
            sub.add_argument("app", type=Path, help="path to a signed Bark.app")
            if command in ("verify", "smoke", "launch"):
                sub.add_argument("--shell-source", metavar="SHA256", help="require this signed shell source SHA-256")
            if command == "dmg":
                sub.add_argument("--output", type=Path, required=True, help="new signed DMG for normal browsing")
                sub.add_argument("--identity", default=os.environ.get("BARK_SIGN_IDENTITY"))
            elif command == "package":
                sub.add_argument("--output", type=Path, required=True, help="new directory for DMG and appcast")
                sub.add_argument("--download-base-url", required=True, help="directory URL for the finished DMG")
                sub.add_argument("--ed-key-file", required=True, help="Sparkle private key file or - for stdin")
                sub.add_argument("--identity", default=os.environ.get("BARK_SIGN_IDENTITY"))
                sub.add_argument("--notary-profile", help="notarytool Keychain profile for submission and stapling")
    args = parser.parse_args()
    if args.command == "shell-source":
        print(shell_source_digest(args.source))
        return
    if platform.system() != "Darwin":
        parser.error("Bark contributor checks require macOS.")
    if args.command == "pair-sdk":
        from publish_chromium_sdk import stage_sdk_pair

        stage_sdk_pair(args.package, args.x86_64, args.arm64)
        return
    if args.command == "interaction":
        run(sys.executable, REPO / "Tests/ChromiumShortcuts/check.py")
        return
    if args.command in NATIVE_CHECKS:
        check_native_harness(args.command)
        return
    if args.command in ("shell", "build"):
        verify_shell_boundary(REPO)
    if args.command == "shell":
        check_release_shell(args.arch)
        return
    launching = args.command in ("smoke", "launch")
    native = native_architecture()
    architecture = args.arch or native
    release_info = (production_settings(args.release_version, args.build_number, args.feed_base_url, architecture)
                    if args.command == "build" else None)
    if launching and architecture != native:
        parser.error(f"Launching signed Bark requires the native {native} runtime.")
    with TemporaryDirectory(prefix="bark-check-", dir="/private/tmp") as work:
        working = Path(work)
        require_official = getattr(args, "require_official", False)
        with pinned_engine(args.engine, working, architecture, require_official) as engine:
            if args.command == "engine":
                if args.archive:
                    archive_engine(engine, args.archive, architecture, require_official)
                if args.install:
                    install_engine(engine, architecture, require_official)
            elif args.command == "build":
                build_candidate(engine, args.output, args.identity, architecture, release_info, args.icloud_profile)
            elif args.command == "dmg":
                app = args.app.resolve(strict=True)
                with app_output_lock(app):
                    make_personal_image(app, args.output, args.identity,
                                        lambda staged: verify_candidate(staged, engine, working, architecture))
            elif args.command == "package":
                make_distribution(args.app.resolve(strict=True), args.output, architecture, args.identity,
                                  args.download_base_url, None, args.ed_key_file, working, args.notary_profile,
                                  verify_staged=lambda staged: verify_candidate(staged, engine, working, architecture,
                                                                                 require_shell_source=True))
            else:
                app = args.app.resolve(strict=True)
                if launching:
                    launch_candidate(app, engine, working, architecture,
                                     interactive=args.command == "launch", shell_source=args.shell_source)
                else:
                    with app_output_lock(app):
                        verify_candidate(app, engine, working, architecture, shell_source=args.shell_source)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except ScreenUnavailable as error:
        print(error, file=sys.stderr)
        sys.exit(SCREEN_UNAVAILABLE)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError, struct.error) as error:
        sys.exit(str(error))
