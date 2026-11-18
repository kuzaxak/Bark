#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Check every Mach-O image in the architecture-specific Bark engine framework."""

import argparse
from pathlib import Path
import subprocess
import sys

from chromium_sdk_layout import ARCHITECTURES

THIN_64 = b"\xcf\xfa\xed\xfe"
MACH_O = {
    THIN_64, b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def image_magic(path):
    with path.open("rb") as handle:
        return handle.read(4)


def check_image(path, architecture, magic):
    result = subprocess.run(
        ["/usr/bin/lipo", "-archs", path], capture_output=True, text=True, check=False
    )
    archs = result.stdout.strip() if result.returncode == 0 else "unreadable"
    if magic != THIN_64 or archs != architecture:
        raise ValueError(f"Engine Mach-O must be exactly {architecture} and thin: {path} (found {archs})")


def check_framework(framework, architecture):
    if not framework.is_dir():
        raise ValueError(f"Missing Bark framework: {framework}")
    framework = framework.resolve()
    for path in sorted(framework.rglob("*")):
        # The framework's version aliases refer to the real files walked here.
        if path.is_symlink():
            if path.readlink().is_absolute() or not path.resolve().is_relative_to(framework):
                raise ValueError(f"Engine framework alias must remain inside the framework: {path}")
            continue
        if not path.is_file():
            continue
        magic = image_magic(path)
        if magic in MACH_O:
            check_image(path, architecture, magic)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--image", action="store_true", help="require a specific Mach-O executable or dylib")
    parser.add_argument("--arch", choices=ARCHITECTURES, default="x86_64")
    args = parser.parse_args()
    try:
        if args.image:
            check_image(args.path, args.arch, image_magic(args.path))
        else:
            check_framework(args.path, args.arch)
    except (OSError, ValueError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
