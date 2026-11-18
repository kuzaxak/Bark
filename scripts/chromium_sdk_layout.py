#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Locations shared by SDK publication, staging, and contributor checks."""

import argparse
from pathlib import Path
import sys

ARCHITECTURES = ("x86_64", "arm64")
SLICE = "macos-arm64_x86_64"
XCFRAMEWORK = "BarkEngine.xcframework"


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
    parser.add_argument("kind", choices=("headers", "artifact", "local-engine", "pin-file", "digest"))
    parser.add_argument("package", type=Path)
    parser.add_argument("architecture", choices=ARCHITECTURES)
    parser.add_argument("headers", type=Path, nargs="?")
    args = parser.parse_args()
    try:
        if args.kind == "headers":
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
