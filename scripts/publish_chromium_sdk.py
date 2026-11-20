#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Serialize preparation and recover an interrupted local SDK publication."""

import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
from pathlib import Path
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory, mkdtemp
from uuid import UUID, uuid4

from chromium_sdk_layout import (ARCHITECTURES, artifact_directory, directory_id, file_digest, headers_directory,
                                 pin_file, read_pin, remove_work, swap)

CHROMIUM = Path(__file__).resolve().parents[1] / "Runtime/Chromium"
sys.path.insert(0, str(CHROMIUM))
HEADERS = ("barc_bridge_api.h", "barc_public_headers_sha256.h")
FRAMEWORK = "Bark Framework.framework"


def version_header_name(architecture):
    return f"barc_engine_version_{architecture}.h"


def version_header(version):
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", version):
        raise ValueError("Expected a four-component ASCII Chromium version")
    return f'#define BARC_CHROMIUM_VERSION "{version}"\n'.encode("ascii")


def engine_version_header(engine):
    def read_version(path):
        require_regular_metadata(path)
        info = plistlib.loads(path.read_bytes())
        if not isinstance(info, dict):
            raise ValueError(f"Expected SDK version metadata in {path}")
        return info.get("CFBundleShortVersionString")

    version = read_version(engine / "engine-Info.plist")
    content = version_header(version)
    versions = engine / FRAMEWORK / "Versions"
    for path in (versions.parent, versions, versions / version, versions / version / "Resources"):
        if directory_id(path) is None:
            raise ValueError(f"Missing versioned SDK framework directory: {path}")
    binary = versions / version / "Bark Framework"
    require_regular_metadata(binary)
    if ((versions / "Current").readlink() != Path(version) or not binary.is_file()
            or read_version(versions / version / "Resources/Info.plist") != version):
        raise ValueError("The versioned SDK framework differs from engine-Info.plist")
    return content


def require_regular_metadata(path):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"Expected a regular SDK metadata file: {path}")


def sdk_manifest(engine):
    manifest = engine / "SHA256SUMS"
    if manifest.is_symlink():
        raise ValueError(f"Unexpected symlink at SDK manifest: {manifest}")
    content = manifest.read_bytes()
    checksums = {}
    for line in content.decode().splitlines():
        digest, delimiter, name = line.partition("  ./")
        if not delimiter or not re.fullmatch(r"[0-9a-f]{64}", digest) or name in checksums:
            raise ValueError(f"Malformed SDK manifest: {manifest}")
        checksums[name] = digest
    return hashlib.sha256(content).hexdigest(), checksums


def verified_digest(engine):
    digest, checksums = sdk_manifest(engine)
    manifest = engine / "SHA256SUMS"
    actual = {}
    for path in engine.rglob("*"):
        if path.is_symlink():
            continue
        if path.stat().st_mode & 0o222:
            raise ValueError(f"Writable SDK entry: {path}")
        if path.is_file() and path != manifest:
            actual[path.relative_to(engine).as_posix()] = file_digest(path)
    if not actual or checksums != actual or engine.stat().st_mode & 0o222:
        raise ValueError(f"Unsealed SDK or checksums differ: {engine}")
    return digest


def tree_layout(engine):
    entries = {}
    for path in engine.rglob("*"):
        mode = path.lstat().st_mode
        relative = path.relative_to(engine)
        entries[relative] = path.readlink() if stat.S_ISLNK(mode) else (
            stat.S_IFMT(mode), mode & 0o111
        )
    return entries


def write_atomic(work, target, content):
    if not target.is_symlink() and target.is_file() and target.read_bytes() == content:
        return
    temporary = work / "metadata.tmp"
    temporary.write_bytes(content)
    temporary.replace(target)


def destination_paths(package, architecture, work):
    engine = artifact_directory(package, architecture)
    headers = headers_directory(package)
    pin = headers / f"engine-artifact-{architecture}.sha256"
    for parent in (engine.parent.parent, headers):
        if not parent.resolve().is_relative_to(package):
            raise ValueError(f"SDK destination must be inside its package: {parent}")
        parent.mkdir(parents=True, exist_ok=True)
        if parent.stat().st_dev != work.stat().st_dev:
            raise ValueError(f"SDK publication requires destinations on the package volume: {parent}")
    if directory_id(engine.parent) is not None:
        for child in engine.parent.iterdir():
            if child.name == "Engine" or (child.name == ".DS_Store" and stat.S_ISREG(child.lstat().st_mode)):
                continue
            raise ValueError(f"SDK architecture directory contains another entry: {child}")
        directory_id(engine)
    directory_id(headers)
    for name in HEADERS:
        require_regular_metadata(headers / name)
    for arch in ARCHITECTURES:
        require_regular_metadata(headers / f"engine-artifact-{arch}.sha256")
        require_regular_metadata(headers / version_header_name(arch))
    return engine, headers, pin


def is_publication_slot(name):
    prefix = ".publication-"
    if name.startswith(prefix):
        try:
            return prefix + UUID(name[len(prefix):]).hex == name
        except ValueError:
            pass
    return False


def verify_official_sdk(engine, architecture):
    from official_provenance import verify_cached

    verify_cached(engine, architecture)


def pair_metadata(engine, architecture):
    """Read the transfer metadata subset of an already published official SDK."""
    from official_provenance import CHROMIUM_VERSION, RECEIPT, recipe_inputs

    pin, manifest = sdk_manifest(engine)
    def read_entry(name):
        path = engine / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing regular {architecture} SDK metadata: {path}")
        data = path.read_bytes()
        if manifest.get(name) != hashlib.sha256(data).hexdigest():
            raise ValueError(f"{architecture} metadata differs from its SDK manifest: {name}")
        return data

    receipt = json.loads(read_entry(RECEIPT))
    headers = {name: read_entry("Headers/" + name) for name in HEADERS}
    versioned = f"{FRAMEWORK}/Versions/{CHROMIUM_VERSION}"
    expected = recipe_inputs(architecture)
    for field, name in (("framework_sha256", "Bark Framework"), ("framework_info_sha256", "Resources/Info.plist")):
        value = manifest.get(f"{versioned}/{name}")
        if value is None:
            raise ValueError(f"Missing {architecture} SDK framework digest: {name}")
        expected[field] = value
    if receipt != expected:
        raise ValueError(f"The {architecture} receipt differs from the selected source recipe or SDK manifest")
    if headers[HEADERS[0]] != (CHROMIUM / "bark/bridge" / HEADERS[0]).read_bytes():
        raise ValueError(f"The {architecture} SDK public API differs from the selected source")
    return headers, pin, version_header(CHROMIUM_VERSION)


def stage_sdk_pair(package, intel, arm):
    """Install the two pins and their shared headers as one receiver-side change."""
    contents = {}
    for arch, source in (("x86_64", intel), ("arm64", arm)):
        shared, pin, version = pair_metadata(source, arch)
        if any(name in contents and contents[name] != data for name, data in shared.items()):
            raise ValueError("The Intel and ARM64 SDKs have different public headers")
        contents.update(shared)
        contents[f"engine-artifact-{arch}.sha256"] = (pin + "\n").encode()
        contents[version_header_name(arch)] = version

    package = package.resolve(strict=True)
    headers = headers_directory(package)
    if not headers.resolve().is_relative_to(package) or directory_id(headers) is None:
        raise ValueError(f"Expected an existing receiver's universal headers directory: {headers}")
    lock = os.open(package, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = package / "RuntimeArtifacts/.publication"
        if not state.resolve().is_relative_to(package):
            raise ValueError(f"SDK publication state must be inside its package: {state}")
        if (state / "pending").exists():
            raise ValueError("Finish the interrupted SDK publication before staging a pair")
        for name in contents:
            require_regular_metadata(headers / name)
        state.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(prefix="work-pair-", dir=state) as tmp:
            work = Path(tmp)
            replacement = work / headers.name
            shutil.copytree(headers, replacement, symlinks=True)
            for name, data in contents.items():
                write_atomic(work, replacement / name, data)
            generator = CHROMIUM / "bark/app/barc_public_headers_sha256.py"
            generated = work / "expected-digest.h"
            subprocess.run([sys.executable, "-B", generator, generated, replacement / HEADERS[0]], check=True)
            if generated.read_bytes() != contents[HEADERS[1]]:
                raise ValueError("The shared SDK digest header does not describe the public API")
            swap(replacement, headers)
    finally:
        os.close(lock)
    print(f"Staged Intel and ARM64 SDK metadata in {headers}")


def finish(package, pending, *, recovering):
    record = json.loads((pending / "transaction.json").read_text())
    architecture, digest, identity, slot = record["arch"], record["digest"], record["identity"], record["slot"]
    official = record.get("official", False)
    if architecture not in ARCHITECTURES or not is_publication_slot(slot) or not isinstance(official, bool):
        raise ValueError("Invalid SDK publication record")
    engine, headers, pin = destination_paths(package, architecture, pending)
    live, candidate = engine.parent, engine.parent.with_name(slot)
    promoted = directory_id(live) == identity
    if not promoted and directory_id(candidate) != identity:
        raise ValueError("Cannot find the prepared SDK in either publication directory")
    prepared = engine if promoted else candidate / "Engine"
    if recovering:
        if verified_digest(prepared) != digest:
            raise ValueError("SDK differs from its publication record")
        if official:
            verify_official_sdk(prepared, architecture)
    contents = {name: (prepared / "Headers" / name).read_bytes() for name in HEADERS}
    contents[version_header_name(architecture)] = engine_version_header(prepared)
    contents[pin.name] = f"{digest}\n".encode()

    if not promoted:
        if live.exists():
            # Keep the same inode for Finder windows that are still writing it.
            finder = candidate / ".DS_Store"
            finder.unlink(missing_ok=True)
            try:
                os.link(live / finder.name, finder, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                if not stat.S_ISREG(finder.lstat().st_mode):
                    raise ValueError(f"Expected regular Finder metadata: {live / finder.name}")
            swap(candidate, live)
        else:
            candidate.rename(live)
    # Commit the version and pin together. The journal bridges the separate
    # runtime and metadata swaps, so a reader will fail its pin check between them.
    with TemporaryDirectory(prefix="metadata-", dir=pending) as tmp:
        work = Path(tmp)
        replacement = work / headers.name
        shutil.copytree(headers, replacement, symlinks=True)
        for name, data in contents.items():
            write_atomic(work, replacement / name, data)
        swap(replacement, headers)
    # Retire the journal atomically before removing the previously published tree.
    retired = pending.with_name(f"work-{uuid4().hex}")
    pending.rename(retired)
    if directory_id(candidate) is not None:
        remove_work(candidate)
    remove_work(retired)
    return engine, digest


def check_other_architecture(package, architecture, engine):
    other, = set(ARCHITECTURES) - {architecture}
    other_pin = pin_file(package, other)
    if not other_pin.is_file():
        return
    read_pin(package, other)
    for name in HEADERS:
        if (other_pin.parent / name).read_bytes() != (engine / "Headers" / name).read_bytes():
            raise ValueError(f"Public headers differ from the pinned {other} SDK: {name}")


def recover_previous(package, state, *, preserve=None):
    pending = state / "pending"
    if directory_id(pending) is not None:
        recovered, digest = finish(package, pending, recovering=True)
        print(f"Recovered SDK publication: {recovered} ({digest})")
    for abandoned in state.parent.glob(".publication-*"):
        if abandoned != preserve and is_publication_slot(abandoned.name):
            directory_id(abandoned)
            remove_work(abandoned)


def publish(package, architecture, replace, build, script, *, require_official=False):
    package.mkdir(parents=True, exist_ok=True)
    package = package.resolve()
    lock = os.open(package, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = package / "RuntimeArtifacts/.publication"
        if not state.resolve().is_relative_to(package):
            raise ValueError(f"SDK publication state must be inside its package: {state}")
        state.mkdir(parents=True, exist_ok=True)
        for abandoned in state.glob("work-*"):
            directory_id(abandoned)
            remove_work(abandoned)
        pending = state / "pending"
        if not require_official:
            recover_previous(package, state)
        work = Path(mkdtemp(prefix="work-", dir=state))
        candidate = None
        try:
            engine, headers, pin = destination_paths(package, architecture, work)
            # Darwin requires the moved directory itself to be writable. Swap
            # its architecture container with the sealed Engine already inside.
            candidate = engine.parent.with_name(f".publication-{uuid4().hex}")
            candidate.mkdir()
            prepared = candidate / "Engine"
            # If this process is killed during preparation, Bash retains the
            # same flock until its last copying or checksum process exits.
            flags = ["--require-official"] if require_official else []
            subprocess.run(["/bin/bash", script, "--prepare", work, prepared, "--arch", architecture,
                            *flags, build, package], check=True, pass_fds=(lock,))
            digest = verified_digest(prepared)
            version = engine_version_header(prepared)
            if require_official:
                verify_official_sdk(prepared, architecture)
                # An invalid official request must leave any pending pin untouched.
                recover_previous(package, state, preserve=candidate)
            check_other_architecture(package, architecture, prepared)
            if engine.exists():
                same_metadata = (pin.is_file() and pin.read_text().strip() == digest and
                                 all((headers / name).is_file() and
                                     (headers / name).read_bytes() == (prepared / "Headers" / name).read_bytes()
                                     for name in HEADERS))
                if same_metadata:
                    try:
                        identical = (verified_digest(engine) == digest and
                                     tree_layout(engine) == tree_layout(prepared))
                    except (OSError, ValueError):
                        identical = False
                    if identical:
                        # Older publications already have the correct pin and
                        # bytes. Backfill only this architecture's version.
                        write_atomic(work, headers / version_header_name(architecture), version)
                        print(f"Verified existing SDK: {engine}\nArtifact SHA: {digest}")
                        return
                if not replace:
                    raise ValueError(f"Engine already published. Use --replace to publish different inputs: {engine}")
            record = {"arch": architecture, "digest": digest, "identity": directory_id(candidate),
                      "slot": candidate.name, "official": require_official}
            (work / "transaction.json").write_text(json.dumps(record))
            work.rename(pending)
            engine, digest = finish(package, pending, recovering=False)
            print(f"Published engine: {engine}\nArtifact SHA: {digest}")
        finally:
            if work.is_dir():
                remove_work(work)
                if candidate is not None and directory_id(candidate) is not None:
                    remove_work(candidate)
    finally:
        os.close(lock)


if __name__ == "__main__":
    package, architecture, replace, build, script, require_official = sys.argv[1:]
    try:
        publish(Path(package), architecture, replace == "true", build, script,
                require_official=require_official == "true")
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
