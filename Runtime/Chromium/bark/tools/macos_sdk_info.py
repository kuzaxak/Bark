# Licensed under GPL-3.0. See LICENSE.
"""Read the identity of an explicitly selected macOS SDK."""

import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess


def read_macos_sdk(path: Path) -> tuple[str, str]:
    with (path / "System/Library/CoreServices/SystemVersion.plist").open("rb") as file:
        system = plistlib.load(file)
    with (path / "SDKSettings.json").open(encoding="utf-8") as file:
        settings = json.load(file)
    version = system.get("ProductVersion")
    build = system.get("ProductBuildVersion")
    if (not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", version)
            or not isinstance(build, str) or not re.fullmatch(r"[0-9]+[A-Z][0-9]+[a-z]?", build)
            or settings.get("Version") != version or settings.get("CanonicalName") != "macosx" + version):
        raise ValueError(f"{path}: inconsistent macOS SDK identity")
    return version, build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("minimum_version")
    args = parser.parse_args()
    try:
        version, build = read_macos_sdk(args.sdk)
        if tuple(map(int, version.split("."))) < tuple(map(int, args.minimum_version.split("."))):
            raise ValueError(f"{args.sdk}: macOS SDK {version} is below {args.minimum_version}")
        developer = Path(subprocess.check_output(["xcode-select", "-print-path"], text=True).strip())
        bin_path = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
        if not (bin_path / "clang").is_file():
            raise ValueError(f"{developer}: selected Xcode toolchain is missing clang")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps({"version": version, "build": build, "bin_path": str(bin_path) + "/"}))


if __name__ == "__main__":
    main()
