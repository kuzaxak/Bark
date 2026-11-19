#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Bark SDK layout, file identity and Mach-O inspection shared by producers and consumers."""

import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys

GN_CPU = {"x86_64": "x64", "arm64": "arm64"}
ARCHITECTURES = tuple(GN_CPU)
SLICE = "macos-arm64_x86_64"
XCFRAMEWORK = "BarkEngine.xcframework"
FRAMEWORK_BINARY = Path("Bark Framework.framework/Versions/Current/Bark Framework")
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


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def directory_id(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"Expected a real SDK directory: {path}")
    return [info.st_dev, info.st_ino]


def swap(left, right):
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    if rename(os.fsencode(left), os.fsencode(right), 0x00000002):  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), right)


def remove_work(path):
    # Sealed SDKs need writable directories for unlink, including on recovery.
    for directory, _, _ in os.walk(path):
        os.chmod(directory, os.stat(directory).st_mode | stat.S_IWUSR)
    shutil.rmtree(path)


def download_https(url, destination):
    """Download a pinned build input using macOS's TLS trust configuration."""
    subprocess.run(["/usr/bin/curl", "--disable", "--fail", "--location", "--silent", "--show-error",
                    "--proto", "=https", "--proto-redir", "=https", "--globoff", "--connect-timeout", "60",
                    "--speed-limit", "1", "--speed-time", "60", "--retry", "2",
                    "--output", destination, "--", url], check=True)


def native_architecture():
    machine = platform.machine()
    if sys.platform == "darwin" and machine == "x86_64":
        # sysctl may itself run natively or under Rosetta. Intel Macs can lack both keys.
        probe = subprocess.run(["/usr/sbin/sysctl", "-in", "hw.optional.arm64", "sysctl.proc_translated"],
                               capture_output=True, text=True, check=True)
        if "1" in probe.stdout.split():
            return "arm64"
    if machine == "aarch64":  # Non-macOS recipe dry runs use this spelling.
        return "arm64"
    if machine not in ARCHITECTURES:
        raise ValueError(f"Unsupported architecture: {machine}")
    return machine


def headers_directory(package):
    return package / XCFRAMEWORK / SLICE / "Headers/BarcChromium"


def legacy_slice(package):
    return package / XCFRAMEWORK / "macos-x86_64"


def artifact_directory(package, architecture):
    return package / "RuntimeArtifacts" / architecture / "Engine"


def local_engine(package, architecture):
    directory = artifact_directory(package, architecture)
    if architecture == "x86_64" and not directory.is_dir():
        old = legacy_slice(package) / "Engine"
        if old.is_dir():
            return old
    return directory


def pin_file(package, architecture, headers=None):
    directory = headers if headers is not None else headers_directory(package)
    pin = directory / f"engine-artifact-{architecture}.sha256"
    if architecture == "x86_64" and not pin.is_file():
        old = (headers if headers is not None else legacy_slice(package) / "Headers/BarcChromium")
        old = old / "engine-artifact.sha256"
        if old.is_file():
            return old
    return pin


def read_pin(package, architecture, headers=None):
    pin = pin_file(package, architecture, headers)
    if not pin.is_file():
        raise ValueError(f"No pinned Bark engine for {architecture}: {pin}")
    digest = pin.read_text().strip()
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError(f"Invalid {architecture} SDK artifact digest: {pin}")
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="kind", required=True)
    native = commands.add_parser("native-arch", help="print the native hardware architecture")
    native.add_argument("--gn", action="store_true", help="print the GN target_cpu spelling")
    for kind in ("headers", "artifact", "local-engine", "pin-file", "digest"):
        command = commands.add_parser(kind)
        command.add_argument("package", type=Path)
        command.add_argument("architecture", choices=ARCHITECTURES)
        command.add_argument("headers", type=Path, nargs="?")
    args = parser.parse_args()
    try:
        if args.kind == "native-arch":
            hardware = native_architecture()
            result = GN_CPU[hardware] if args.gn else hardware
        elif args.kind == "headers":
            result = headers_directory(args.package)
        elif args.kind == "artifact":
            result = artifact_directory(args.package, args.architecture)
        elif args.kind == "local-engine":
            result = local_engine(args.package, args.architecture)
        elif args.kind == "pin-file":
            result = pin_file(args.package, args.architecture, args.headers)
        else:
            result = read_pin(args.package, args.architecture, args.headers)
        print(result)
    except (OSError, ValueError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
