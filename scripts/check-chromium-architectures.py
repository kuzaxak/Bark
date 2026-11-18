#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Check every Mach-O image in the architecture-specific Bark engine framework."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import sys

from chromium_sdk_layout import ARCHITECTURES, native_architecture

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


def check_framework(framework, architecture, engine_info=None):
    """Require the versioned image and framework aliases used by consumers."""
    if not framework.is_dir():
        raise ValueError(f"Missing Bark framework: {framework}")
    framework = framework.resolve()
    current = framework / "Versions/Current"
    version = current.readlink() if current.is_symlink() else None
    if engine_info is not None:
        with engine_info.open("rb") as handle:
            pinned_version = plistlib.load(handle).get("CFBundleShortVersionString")
        if not isinstance(pinned_version, str) or not pinned_version:
            raise ValueError(f"Missing pinned engine version in {engine_info}")
        if version != Path(pinned_version):
            raise ValueError(f"Versions/Current must point to {pinned_version}: {framework}")
    if version is None or version.is_absolute() or len(version.parts) != 1 or version.name in ("..", "Current"):
        raise ValueError(f"Engine framework must have a relative version alias: {current}")
    versioned = framework / "Versions" / version
    executable = framework.stem
    image = versioned / executable
    if not image.is_file() or image.is_symlink() or versioned.is_symlink() or current.parent.is_symlink():
        raise ValueError(f"Missing versioned engine executable: {image}")
    check_image(image, architecture, image_magic(image))
    for entry in (executable, "Resources", "Libraries", "Helpers"):
        target = versioned / entry
        if entry not in (executable, "Resources") and not target.exists():
            continue
        alias = framework / entry
        if (not target.exists() or not alias.is_symlink() or
                alias.readlink() != Path("Versions/Current") / entry):
            raise ValueError(f"Missing or invalid engine framework alias: {alias}")
    for path in sorted(framework.rglob("*")):
        # The framework's version aliases refer to the real files walked here.
        if path.is_symlink():
            if path.readlink().is_absolute() or not path.resolve().is_relative_to(framework):
                raise ValueError(f"Engine framework alias must remain inside the framework: {path}")
            if not path.exists():
                raise ValueError(f"Engine framework alias has no target: {path}")
            continue
        if not path.is_file():
            continue
        magic = image_magic(path)
        if path != image and magic in MACH_O:
            check_image(path, architecture, magic)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--image", action="store_true", help="require a specific Mach-O executable or dylib")
    parser.add_argument("--engine-info", type=Path, help="require the engine metadata version")
    parser.add_argument("--arch", choices=ARCHITECTURES, help="defaults to native hardware")
    args = parser.parse_args()
    try:
        architecture = args.arch or native_architecture()
        if args.image:
            check_image(args.path, architecture, image_magic(args.path))
        else:
            check_framework(args.path, architecture, args.engine_info)
    except (OSError, ValueError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
