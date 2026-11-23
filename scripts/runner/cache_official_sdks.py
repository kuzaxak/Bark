#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Stage and verify the official SDK products cached by GitHub Actions."""

import argparse
import os
from pathlib import Path
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory

REPO = Path(__file__).resolve().parents[2]
RECIPE = REPO / "Runtime/Chromium"
RECEIVER = REPO / "Packages/BarkEngine"
sys.path[:0] = [str(RECIPE), str(REPO / "scripts")]
from chromium_sdk_layout import (ARCHITECTURES, artifact_directory, directory_id,
                                 headers_directory, official_seal_name)
from publish_chromium_sdk import (HEADERS, engine_version_header, stage_sdk_pair,
                                  verified_digest, verify_official_sdk, version_header_name)

METADATA = (*HEADERS, *(name for arch in ARCHITECTURES for name in (
    f"engine-artifact-{arch}.sha256", version_header_name(arch), official_seal_name(arch))))
# Budget below the repository's default 10 GB shared allowance. Skip oversized
# pairs so they remain usable on the runner without evicting the entire cache.
CACHE_LIMIT = 6 * 1024 ** 3


def engines(package):
    return {arch: artifact_directory(package, arch) for arch in ARCHITECTURES}


def verify_tree(engine):
    for directory in (engine.parents[2], engine.parents[1], engine.parent, engine):
        if directory_id(directory) is None:
            raise ValueError(f"Missing SDK directory: {directory}")
    size = 0
    for path in engine.rglob("*"):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            if path.readlink().is_absolute() or not path.resolve(strict=True).is_relative_to(engine):
                raise ValueError(f"Unsafe SDK symlink: {path}")
        elif stat.S_ISREG(info.st_mode):
            size += info.st_size
        elif not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"Unsupported SDK entry: {path}")
    return size


def stage_pair(package, receiver):
    paths = engines(package)
    stage_sdk_pair(receiver, paths["x86_64"], paths["arm64"])


def read_metadata(package):
    directory = headers_directory(package)
    for entry in (directory, *directory.parents[:4]):
        if directory_id(entry) is None:
            raise ValueError(f"Missing paired SDK metadata: {entry}")
    files = {}
    for name in METADATA:
        path = directory / name
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError(f"Paired SDK metadata must be a regular file: {path}")
        files[name] = path.read_bytes()
    return files


def verify_pair(package, metadata_package):
    size = 0
    for arch, engine in engines(package).items():
        size += verify_tree(engine)
        verified_digest(engine)
        engine_version_header(engine)
        verify_official_sdk(engine, arch)
    with TemporaryDirectory(prefix="bark-cache-pair-") as work:
        receiver = Path(work)
        headers_directory(receiver).mkdir(parents=True)
        stage_pair(package, receiver)
        expected = read_metadata(receiver)
    if read_metadata(metadata_package) != expected:
        raise ValueError("Cached paired metadata differs from the official SDKs.")
    return size


def outputs(package, *, cacheable=False):
    values = {"package": package, **{f"{arch}-engine": engine for arch, engine in engines(package).items()},
              "metadata": headers_directory(RECEIVER),
              "cacheable": str(cacheable).lower()}
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        for key, value in values.items():
            print(f"{key}={value}", file=output)


def install_from_cache(root):
    if directory_id(root) is None:
        raise ValueError(f"Missing official SDK cache directory: {root}")
    package = root / "Package"
    size = verify_pair(package, package)
    stage_pair(package, RECEIVER)
    for arch, engine in engines(package).items():
        subprocess.run(["/bin/bash", REPO / "scripts/stage-chromium-app.sh", "--arch", arch,
                        "--check-engine", engine], check=True)
    print(f"Restored and verified both official SDKs ({size} bytes). Skipping the engine build.")
    outputs(package)


def accept_build(package, cache_root):
    size = verify_pair(package, RECEIVER)
    if size > CACHE_LIMIT or cache_root is None or cache_root.exists() or cache_root.is_symlink():
        print(f"SDK pair verified ({size} bytes). Using the runner-local output.")
        outputs(package)
        return
    cached_package = cache_root / "Package"
    metadata = headers_directory(cached_package)
    metadata.mkdir(parents=True)
    for name, content in read_metadata(RECEIVER).items():
        (metadata / name).write_bytes(content)
    for arch, destination in engines(cached_package).items():
        destination.parent.parent.mkdir(parents=True, exist_ok=True)
        # Darwin refuses to move a directory its owner cannot write, so move the sealed Engine's container.
        artifact_directory(package, arch).parent.rename(destination.parent)
    print(f"Verified {size} bytes of official SDKs for the default-branch cache.")
    outputs(cached_package, cacheable=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    restore = subcommands.add_parser("restore")
    restore.add_argument("root", type=Path)
    accept = subcommands.add_parser("accept")
    accept.add_argument("package", type=Path)
    accept.add_argument("--cache-root", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "restore":
            install_from_cache(args.root.absolute())
        else:
            accept_build(args.package.absolute(), args.cache_root.absolute() if args.cache_root else None)
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
