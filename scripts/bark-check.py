#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Build, verify and run the signed Bark app or its native regression checks."""

import argparse
from contextlib import contextmanager
import ctypes
import errno
import fcntl
import filecmp
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
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
from urllib.request import urlopen
from uuid import uuid4

REPO = Path(__file__).resolve().parents[1]
STAGE = REPO / "scripts/stage-chromium-app.sh"
DEFAULT_ENGINE = REPO / "Packages/BarkEngine/BarkEngine.xcframework/macos-x86_64/Engine"
FRAMEWORK = "Bark Framework.framework"
MACH64 = b"\xcf\xfa\xed\xfe"
CODESIGN_LINKEDIT_ALIGNMENT = 16 * 1024


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def check_native_harness(command):
    # Xcode resolves the shell's real package graph and the headers in its SDK.
    # The harness supplies its own bridge table, so it runs without an Engine.
    if platform.machine() != "x86_64":
        raise ValueError("The native shell regression needs the Intel slice of the Bark SDK.")
    derived = REPO / "build/catalog-contributor-derived"
    packages = derived / "SourcePackages"
    products = derived / "Build/Products/Debug"
    try:
        run("xcodebuild", "-project", REPO / "Nook.xcodeproj", "-scheme", "NookNativeShell",
            "-configuration", "Debug", "-destination", "generic/platform=macOS",
            "-derivedDataPath", derived, "-clonedSourcePackagesDirPath", packages,
            "-onlyUsePackageVersionsFromResolvedFile", "ARCHS=x86_64", "CODE_SIGNING_ALLOWED=NO",
            "OTHER_SWIFT_FLAGS=$(inherited) -j4", "-jobs", "2", "build")
    finally:
        # The shared scheme also builds and registers an unsigned outer app.
        app = products / "Bark.app"
        if app.exists():
            registrar = ("/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/"
                         "LaunchServices.framework/Versions/Current/Support/lsregister")
            subprocess.run([registrar, "-u", str(app)], capture_output=True)
    maps = derived / "Build/Intermediates.noindex/GeneratedModuleMaps"
    # SwiftPM bundle lookup uses the executable directory for command-line tools.
    suite = {"catalog": "ChromiumCatalog", "page-host": "ChromiumPageHost",
             "profile-pages": "ChromiumProfilePages"}[command]
    binary = products / f"bark-{command}-check"
    run("xcrun", "swiftc", "-swift-version", "5", "-target", "x86_64-apple-macosx15.5",
        "-parse-as-library", "-D", "BARK_CATALOG_FRAMEWORK", "-F", products, "-I", products,
        "-I", products / "include", "-I", packages / "checkouts/swift-atomics/Sources/_AtomicsShims/include",
        "-Xcc", f"-fmodule-map-file={maps / 'MuteableWKWebView.modulemap'}",
        "-framework", "NookNativeShell", "-Xlinker", "-rpath", "-Xlinker", products,
        REPO / "Tests/Shared/BridgeTable.swift", REPO / "Tests" / suite / "Main.swift", "-o", binary)
    run(binary)


def cached_engine():
    pin = (DEFAULT_ENGINE.parent / "Headers/BarcChromium/engine-artifact.sha256").read_text().strip()
    if len(pin) != 64 or any(c not in "0123456789abcdef" for c in pin):
        raise ValueError("Invalid SDK artifact digest in the checked-in headers.")
    return Path.home() / "Library/Caches/BarkSDK" / pin / "Engine"


def install_engine(engine):
    destination = cached_engine()
    if not destination.is_dir():
        cache = destination.parent.parent
        cache.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(dir=cache) as stage:
            copy = Path(stage) / "Engine"
            run("/usr/bin/ditto", engine, copy)
            run("/bin/bash", STAGE, "--check-engine", copy)
            try:
                # Keep the read-only SDK intact and publish its writable parent.
                Path(stage).rename(destination.parent)
            except OSError as error:
                if error.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                    raise
    run("/bin/bash", STAGE, "--check-engine", destination)
    print(f"Installed pinned SDK at {destination}")


@contextmanager
def pinned_engine(source, working):
    if not source:
        installed = cached_engine()
        source = str(installed if installed.is_dir() else DEFAULT_ENGINE)
        if not Path(source).is_dir():
            raise ValueError("The pinned SDK is missing. Install it with bark-check.py engine --install "
                             "--engine PATH, or build it using Runtime/Chromium/README.md.")
    path = Path(source).expanduser()
    if not path.is_dir():
        if not hasattr(tarfile, "data_filter"):
            raise ValueError("Engine archives require Python with the tarfile data extraction filter.")
        archive = path
        if urlsplit(source).scheme == "https":
            archive = working / "engine.tar"
            with urlopen(source, timeout=60) as response, archive.open("wb") as output:
                if urlsplit(response.geturl()).scheme != "https":
                    raise ValueError("The engine artifact must be served over HTTPS.")
                shutil.copyfileobj(response, output)
        unpacked = working / "engine"
        with tarfile.open(archive, "r:*") as package:
            package.extractall(unpacked, filter="data")
        path = unpacked if (unpacked / "SHA256SUMS").is_file() else unpacked / "Engine"
    path = path.resolve(strict=True)
    run("/bin/bash", STAGE, "--check-engine", path)
    yield path


def framework_files(directory):
    """Index files and symlinks, excluding files generated by codesign."""
    return {entry.relative_to(directory): entry for entry in directory.rglob("*")
            if (entry.is_symlink() or entry.is_file())
            and entry.relative_to(directory).parts[-2:] != ("_CodeSignature", "CodeResources")}


def unsigned_mach_digest(path, payload_size, original_vmsize=None, signed_size=None):
    """Return the unsigned Mach-O digest and its original linkedit mapping size."""
    file_size = path.stat().st_size
    padded_size = (payload_size + 15) & ~15
    if not payload_size <= file_size <= padded_size:
        raise ValueError(f"Unexpected Mach-O size: {path}")
    with path.open("rb") as binary:
        header = binary.read(32)
        magic, cpu, _, _, count, size, _, _ = struct.unpack("<IIIIIIII", header)
        if magic != 0xfeedfacf or cpu != 0x1000007:
            raise ValueError(f"Expected a thin x86_64 Mach-O: {path}")
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


def verify_signed_shell(app):
    sys.path.insert(0, str(REPO / "Runtime/Chromium"))
    from run_browser_tests import TEST_FRAMEWORK, require_host_only_image
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    return require_host_only_image(app / "Contents/Frameworks" / TEST_FRAMEWORK)


def verify_candidate(app, engine, working):
    verify_signed_shell(app)
    run("/bin/bash", STAGE, "--check-signed", app, REPO / "ChromiumApp/Additions.plist", engine)
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
            # Strip the signature on a disposable copy. Apple codesign may align the
            # linkedit segment and the tail differently after removing the signature.
            unsigned = working / "unsigned"
            shutil.copyfile(signed, unsigned)
            run("/usr/bin/codesign", "--remove-signature", unsigned)
            payload_size = original.stat().st_size
            digest, vmsize = unsigned_mach_digest(original, payload_size)
            stripped_digest, _ = unsigned_mach_digest(unsigned, payload_size, vmsize, signed.stat().st_size)
            same = digest == stripped_digest
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


def stop(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
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


def launch_candidate(app, working, *, interactive):
    profile = str(uuid4()).upper()
    root = working / "Profile"
    root.mkdir()
    domain = "ee.qdo.nook.chromium-verification." + hashlib.sha256(str(root).encode()).hexdigest()
    app_binary = app / "Contents/MacOS/Bark"
    with HTTPServer(("127.0.0.1", 0), SmokePage) as server, (working / "bark.log").open("wb") as log:
        server.timeout = .25
        server.rendered = False
        origin = f"http://127.0.0.1:{server.server_port}"
        seed_profile(root, profile, origin)
        proc = subprocess.Popen([str(app_binary), f"--barc-app-data-dir={root}",
                                 f"--barc-app-profile={profile}"],
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        spontaneous_status = None
        try:
            deadline = time.monotonic() + 45
            while not server.rendered and time.monotonic() < deadline and proc.poll() is None:
                server.handle_request()
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


def install_local_build(app, output):
    # Work and destination share a volume. Swap complete bundles in one
    # operation so readers see a verified app even if a rebuild is interrupted.
    parent = os.open(output.parent, os.O_RDONLY)
    try:
        fcntl.flock(parent, fcntl.LOCK_EX)
        if output.is_symlink():
            raise ValueError(f"Choose a local output directory instead of a symlink: {output}")
        if not output.exists():
            app.rename(output)
            return
        info = output / "Contents/Info.plist"
        if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != "ee.qdo.bark":
            raise ValueError(f"Output already exists and is not a Bark bundle: {output}")
        processes = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True)
        if any(path.strip().startswith(str(output) + "/") for path in processes.splitlines()):
            raise ValueError(f"Quit the running copy before rebuilding {output}")
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        if rename(os.fsencode(app), os.fsencode(output), 0x00000002):  # RENAME_SWAP on macOS
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), output)
    finally:
        os.close(parent)


def build_candidate(engine, output, identity):
    if platform.machine() != "x86_64":
        raise ValueError("The pinned Bark engine currently supports native Intel builds.")
    if not identity:
        raise ValueError("Supply --identity or BARK_SIGN_IDENTITY for local Developer ID signing.")
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
            run("xcodebuild", "-project", REPO / "Nook.xcodeproj", "-scheme", "NookNativeShell",
                "-configuration", "Release", "-destination", "generic/platform=macOS",
                "-derivedDataPath", derived, "-onlyUsePackageVersionsFromResolvedFile",
                "ARCHS=x86_64", "CODE_SIGNING_ALLOWED=NO", "OTHER_SWIFT_FLAGS=$(inherited) -j4",
                "-jobs", "2", "build")
            run("/bin/bash", STAGE, unsigned, engine, products, stage / "Bark.app",
                REPO / "ChromiumApp/Additions.plist")
            signed = work / "signed"
            run(sys.executable, REPO / "scripts/sign-bark-local.py", "--identity", identity, stage, signed)
            app = signed / "stable/Bark.app"
            verify_candidate(app, engine, work)
            install_local_build(app, output)
        finally:
            # Xcode registers its intermediate app with Launch Services.
            if unsigned.exists():
                subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Versions/Current/"
                                "Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister",
                                "-u", str(unsigned)], capture_output=True)
    print(f"Built and verified {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("interaction", help="run the native command-window regression")
    commands.add_parser("catalog", help="run catalog and initial-window activation regressions on Intel")
    commands.add_parser("page-host", help="check page ownership, transfer and close on Intel")
    commands.add_parser("profile-pages", help="check profile utility window ownership on Intel")
    for command in ("engine", "build", "verify", "smoke", "launch"):
        sub = commands.add_parser(command)
        sub.add_argument("--engine", default=os.environ.get("BARK_ENGINE_SOURCE"),
                         help="pinned engine directory, tar archive, or HTTPS tar archive")
        if command == "engine":
            sub.add_argument("--install", action="store_true", help="cache the verified SDK for clean checkouts")
        elif command == "build":
            sub.add_argument("--output", type=Path, default=REPO / "build/Bark.app")
            sub.add_argument("--identity", default=os.environ.get("BARK_SIGN_IDENTITY"),
                             help="local Developer ID Application signing identity")
        elif command != "engine":
            sub.add_argument("app", type=Path, help="path to a signed Bark.app")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Bark contributor checks require macOS.")
    if args.command == "interaction":
        run(sys.executable, REPO / "Tests/ChromiumShortcuts/check.py")
        return
    if args.command in ("catalog", "page-host", "profile-pages"):
        check_native_harness(args.command)
        return
    with TemporaryDirectory(prefix="nook-bark-check-", dir="/private/tmp") as work:
        working = Path(work)
        with pinned_engine(args.engine, working) as engine:
            if args.command == "engine" and args.install:
                install_engine(engine)
            elif args.command == "build":
                build_candidate(engine, args.output, args.identity)
            elif args.command != "engine":
                app = args.app.resolve(strict=True)
                verify_candidate(app, engine, working)
                if args.command in ("smoke", "launch"):
                    if platform.machine() != "x86_64":
                        parser.error("Launching signed Bark requires the Intel runtime.")
                    launch_candidate(app, working, interactive=args.command == "launch")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError, struct.error) as error:
        sys.exit(str(error))
