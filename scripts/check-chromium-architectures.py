#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Check the CPU architecture of Bark and its embedded runtime dependencies."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys

from chromium_sdk_layout import ARCHITECTURES, native_architecture

THIN_64 = b"\xcf\xfa\xed\xfe"
MACH_O = {
    THIN_64, b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def image_header(path):
    with path.open("rb") as handle:
        return handle.read(16)


def check_image(path, architecture, header, *, allow_universal=False):
    result = subprocess.run(
        ["/usr/bin/lipo", "-archs", path], capture_output=True, text=True, check=False
    )
    archs = result.stdout.strip() if result.returncode == 0 else "unreadable"
    if allow_universal:
        if architecture not in archs.split():
            raise ValueError(f"App dependency must include {architecture}: {path} (found {archs})")
    elif header[:4] != THIN_64 or archs != architecture:
        raise ValueError(f"Engine Mach-O must be exactly {architecture} and thin: {path} (found {archs})")
    # MH_EXECUTE images are launched as processes. Their bytes can match
    # SHA256SUMS even when an archive has lost the owner's execute bit.
    if header[:4] == THIN_64 and int.from_bytes(header[12:16], "little") == 2 and not path.stat().st_mode & stat.S_IXUSR:
        raise ValueError(f"Mach-O executable is missing owner execute permission: {path}")


def check_shell_image(path, architecture):
    check_image(path, architecture, image_header(path))
    dependencies = subprocess.run(["/usr/bin/otool", "-L", path], capture_output=True, text=True)
    if dependencies.returncode:
        raise ValueError(f"Cannot read load commands from Bark shell image: {path}")
    for line in dependencies.stdout.splitlines()[1:]:
        library = line.strip().partition(" (")[0]
        if any(framework in Path(library).parts for framework in ("WebKit.framework", "WebKitLegacy.framework")):
            raise ValueError(f"Bark shell links a retired WebKit framework: {path} -> {library}")


def check_launcher_sdk(path, headers, architecture, engine_info=None):
    digest_header = headers / "barc_public_headers_sha256.h"
    digest = re.fullmatch(r'#define BARC_PUBLIC_HEADERS_SHA256 "([0-9a-f]{64})"\n', digest_header.read_text())
    if not digest:
        raise ValueError(f"Invalid SDK public header digest: {digest_header}")
    if engine_info is None:
        version_header = headers / f"barc_engine_version_{architecture}.h"
        version = re.fullmatch(r'#define BARC_CHROMIUM_VERSION "([0-9]+(?:\.[0-9]+){3})"\n', version_header.read_text())
        if not version:
            raise ValueError(f"Invalid SDK version header: {version_header}")
        engine_version = version[1]
    else:
        with engine_info.open("rb") as handle:
            engine_version = plistlib.load(handle).get("CFBundleShortVersionString")
    # These are the literals main uses for dlopen and for its runtime header comparison.
    result = subprocess.run(["/usr/bin/otool", "-X", "-v", "-s", "__TEXT", "__cstring", path],
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"Cannot inspect the Bark launcher's C strings: {path}")
    literals = result.stdout.splitlines()
    if f"../Frameworks/Bark Framework.framework/Versions/{engine_version}/Bark Framework" not in literals:
        raise ValueError(f"Bark launcher was built for another engine version: expected {engine_version} in {path}")
    if digest[1] not in literals:
        raise ValueError(f"Bark launcher was compiled against different SDK headers: expected {digest[1]} in {path}")


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
    check_image(image, architecture, image_header(image))
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
        header = image_header(path)
        if path != image and header[:4] in MACH_O:
            check_image(path, architecture, header)


def check_app(app, architecture, engine_info=None):
    contents = app / "Contents"
    frameworks = contents / "Frameworks"
    engine = frameworks / "Bark Framework.framework"
    shell_images = (contents / "MacOS/Bark", frameworks / "NookNativeShell.framework/Versions/A/NookNativeShell")
    for path in shell_images:
        check_shell_image(path, architecture)
    check_framework(engine, architecture, engine_info)

    # Sparkle and other app dependencies may ship universal binaries. Inspect
    # nested services and helpers as well as the framework loaded by the shell.
    for directory, children, files in os.walk(contents):
        parent = Path(directory)
        if parent == frameworks:
            children.remove(engine.name)
        for name in files:
            path = parent / name
            if path in shell_images or path.is_symlink() or not path.is_file():
                continue
            header = image_header(path)
            if header[:4] in MACH_O:
                check_image(path, architecture, header, allow_universal=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--app", action="store_true", help="check the complete staged or signed application bundle")
    mode.add_argument("--shell-image", action="store_true", help="check the Bark launcher or Swift shell and its engine boundary")
    mode.add_argument("--image", action="store_true", help="require a specific Mach-O executable or dylib")
    parser.add_argument("--engine-info", type=Path, help="require the engine metadata version")
    parser.add_argument("--launcher-headers", type=Path, help="check the app launcher's compiled SDK header digest and version")
    parser.add_argument("--arch", choices=ARCHITECTURES, help="defaults to native hardware")
    args = parser.parse_args()
    if args.launcher_headers and not (args.app or args.shell_image):
        parser.error("--launcher-headers requires --app or the launcher's --shell-image")
    try:
        architecture = args.arch or native_architecture()
        if args.app:
            check_app(args.path, architecture, args.engine_info)
        elif args.shell_image:
            check_shell_image(args.path, architecture)
        elif args.image:
            check_image(args.path, architecture, image_header(args.path))
        else:
            check_framework(args.path, architecture, args.engine_info)
        if args.launcher_headers:
            launcher = args.path / "Contents/MacOS/Bark" if args.app else args.path
            check_launcher_sdk(launcher, args.launcher_headers, architecture, args.engine_info)
    except (OSError, ValueError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
