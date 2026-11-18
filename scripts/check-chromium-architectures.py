#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Check every Mach-O image in the Intel Bark engine framework."""

import argparse
from pathlib import Path
import subprocess
import sys

THIN_64 = b"\xcf\xfa\xed\xfe"
MACH_O = {
    THIN_64, b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def check_framework(framework):
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
        with path.open("rb") as handle:
            magic = handle.read(4)
        if magic not in MACH_O:
            continue
        result = subprocess.run(
            ["/usr/bin/lipo", "-archs", path], capture_output=True, text=True, check=False
        )
        archs = result.stdout.strip() if result.returncode == 0 else "unreadable"
        if magic != THIN_64 or archs != "x86_64":
            raise ValueError(f"Engine Mach-O must be exactly x86_64 and thin: {path} (found {archs})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("framework", type=Path)
    args = parser.parse_args()
    try:
        check_framework(args.framework)
    except (OSError, ValueError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
