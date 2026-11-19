#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Archive an already linked Bark browser test runtime for a native receiver."""

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Runtime/Chromium"))
from run_browser_tests import APP_FRAMEWORK, TEST_FRAMEWORK, file_identity, require_host_only_image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tests/ChromiumSDKLauncher"))
from check import INTEGRATED_PLIST, RAW_LAUNCHER, RAW_PLIST, inspect_launcher

from bark_release import publish_new
from chromium_sdk_layout import ARCHITECTURES, GN_CPU, native_architecture
from chromium_test_runtime import FIXTURE, MANIFEST_NAME, create_manifest, digest_regular

RUNTIME_DEPS = "bark_browser_tests.runtime_deps"
IMAGES = (Path("bark_browser_tests"), TEST_FRAMEWORK, APP_FRAMEWORK)


def transfer_paths(src, build, manifest):
    entries = {src / "chrome/VERSION", manifest, build / INTEGRATED_PLIST}
    for line in manifest.read_text().splitlines():
        if not line:
            continue
        if Path(line).is_absolute():
            raise ValueError(f"Absolute path in GN runtime dependencies: {line}")
        entries.add(Path(os.path.abspath(build / line)))
    expected = {build / IMAGES[0], build / "Bark Framework.framework", build / "Bark.app"}
    if not expected <= entries:
        raise ValueError("GN runtime dependencies omit the test executable or a required bundle")
    for path in entries:
        if path == src or not path.is_relative_to(src):
            raise ValueError(f"Runtime dependency leaves Chromium src: {path}")
    directories = {path for path in entries if path.is_dir() and not path.is_symlink()}
    roots = sorted(path for path in entries if not directories.intersection(path.parents))
    for path in roots:
        check_entry(src, path, entries, directories)
        if path in directories:
            for child in path.rglob("*"):
                check_entry(src, child, entries, directories)
    return [path.relative_to(src.parent) for path in roots]


def check_entry(src, path, entries, directories):
    mode = path.lstat().st_mode
    if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
        raise ValueError(f"Unsupported runtime dependency type: {path}")
    target = path.resolve(strict=True)
    if not target.is_relative_to(src):
        raise ValueError(f"Runtime dependency resolves outside Chromium src: {path}")
    if stat.S_ISLNK(mode):
        link = path.readlink()
        lexical = Path(os.path.abspath(path.parent / link))
        if link.is_absolute() or not lexical.is_relative_to(src):
            raise ValueError(f"Nonportable runtime symlink: {path}")
        for member in (lexical, target):
            if member not in entries and not directories.intersection(member.parents):
                raise ValueError(f"Runtime symlink points to an omitted dependency: {path}")
    elif path != target:
        raise ValueError(f"Runtime dependency uses a symlinked parent: {path}")


def package(build, arch, output, *, fixture_source=None, fixture_tree=None):
    build = build.resolve(strict=True)
    src = build.parent.parent
    native_output = f"Barc-{GN_CPU[arch]}"
    if (src.name != "src" or build.parent.name != "out" or
            build.name not in (native_output, f"{native_output}-official")):
        raise ValueError(f"Expected Chromium src/out/{native_output}[-official], found {build}")
    version = src / "chrome/VERSION"
    manifest = build / RUNTIME_DEPS
    if any(p.is_symlink() or not p.is_file() for p in (version, manifest, build / IMAGES[0])):
        raise ValueError("Expected regular Chromium version, runtime manifest and test executable")

    output = output.expanduser().absolute()
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"Test runtime archive already exists: {output}")
    if output.resolve().is_relative_to(src):
        raise ValueError("Choose an archive destination outside Chromium src")
    verified = dict(require_host_only_image(build / path, expected_arch=arch) for path in IMAGES)
    for path in (manifest, version, build / RAW_PLIST, build / RAW_LAUNCHER,
                 build / INTEGRATED_PLIST):
        verified[path] = file_identity(path)
    paths = transfer_paths(src, build, manifest)
    inspect_launcher(build, arch)
    fixture = src / FIXTURE if fixture_source is not None else None
    if fixture is not None:
        verified[fixture] = file_identity(fixture)
    provenance = create_manifest(build / IMAGES[0], fixture, expected_tree=fixture_tree)
    if fixture_source is not None and provenance["installed_fixture_sha256"] != digest_regular(fixture_source):
        raise ValueError("Installed browser-test fixture differs from the expected source")
    manifest_member = (build / MANIFEST_NAME).relative_to(src.parent)
    if any(manifest_member == path or manifest_member.is_relative_to(path) for path in paths):
        raise ValueError("Runtime dependencies already include the reserved test manifest")
    with TemporaryDirectory(prefix=".bark-test-runtime-", dir=output.parent) as directory:
        work = Path(directory)
        inputs = work / "inputs.nul"
        inputs.write_bytes(b"".join(os.fsencode(path) + b"\0" for path in paths))
        metadata = work / MANIFEST_NAME
        metadata.write_text(json.dumps(provenance, indent=2) + "\n")
        metadata_tar = work / "manifest.tar"
        with tarfile.open(metadata_tar, "w") as tar:
            tar.add(metadata, arcname=str(manifest_member))
        archive = work / "BarkTestRuntime.tar.gz"
        subprocess.run(
            ["/usr/bin/tar", "-c", "-z", "-f", archive, "-C", src.parent, "--null", "-T", inputs, f"@{metadata_tar}"],
            check=True,
        )
        if any(file_identity(path) != identity for path, identity in verified.items()):
            raise ValueError("The linked test runtime changed while it was archived")
        publish_new(archive, output)
    print(f"Archived {arch} Bark browser test runtime: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path, help="Chromium src/out/Barc-<cpu>[-official]")
    parser.add_argument("--arch", choices=ARCHITECTURES, help="target architecture (defaults to native hardware)")
    parser.add_argument("--output", required=True, type=Path, help="new .tar.gz archive")
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--fixture-source", type=Path, help="legacy export-time barc_bridge_browsertest.mm check")
    sources.add_argument("--fixture-tree", type=Path, help="require the linked browser-test sources to match this directory")
    args = parser.parse_args()
    try:
        package(args.build, args.arch or native_architecture(), args.output, fixture_source=args.fixture_source,
                fixture_tree=args.fixture_tree)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
