#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Serialize preparation and recover an interrupted local SDK publication."""

import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
from tempfile import mkdtemp
from uuid import UUID, uuid4

from chromium_sdk_layout import ARCHITECTURES, artifact_directory, headers_directory, pin_file, read_pin

HEADERS = ("barc_bridge_api.h", "barc_public_headers_sha256.h")


def directory_id(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"Expected a real SDK directory: {path}")
    return [info.st_dev, info.st_ino]


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verified_digest(engine):
    manifest = engine / "SHA256SUMS"
    if manifest.is_symlink():
        raise ValueError(f"Unexpected symlink at SDK manifest: {manifest}")
    content = manifest.read_bytes()
    checksums = {}
    for line in content.decode().splitlines():
        digest, delimiter, name = line.partition("  ./")
        if not delimiter or name in checksums:
            raise ValueError(f"Malformed SDK manifest: {manifest}")
        checksums[name] = digest
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
    return hashlib.sha256(content).hexdigest()


def tree_layout(engine):
    entries = {}
    for path in engine.rglob("*"):
        mode = path.lstat().st_mode
        relative = path.relative_to(engine)
        entries[relative] = path.readlink() if stat.S_ISLNK(mode) else (
            stat.S_IFMT(mode), mode & 0o111
        )
    return entries


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
        if any(child.name != "Engine" for child in engine.parent.iterdir()):
            raise ValueError(f"SDK architecture directory contains another entry: {engine.parent}")
        directory_id(engine)
    for path in (*[headers / name for name in HEADERS], pin):
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise ValueError(f"Expected a regular SDK metadata file: {path}")
    return engine, headers, pin


def is_publication_slot(name):
    prefix = ".publication-"
    if name.startswith(prefix):
        try:
            return prefix + UUID(name[len(prefix):]).hex == name
        except ValueError:
            pass
    return False


def finish(package, pending, *, recovering):
    record = json.loads((pending / "transaction.json").read_text())
    architecture, digest, identity, slot = record["arch"], record["digest"], record["identity"], record["slot"]
    if architecture not in ARCHITECTURES or not is_publication_slot(slot):
        raise ValueError("Invalid SDK publication record")
    engine, headers, pin = destination_paths(package, architecture, pending)
    live, candidate = engine.parent, engine.parent.with_name(slot)
    if directory_id(live) != identity:
        if directory_id(candidate) != identity:
            raise ValueError("Cannot find the prepared SDK in either publication directory")
        if recovering and verified_digest(candidate / "Engine") != digest:
            raise ValueError("Prepared SDK differs from its publication record")
        if live.exists():
            swap(candidate, live)
        else:
            candidate.rename(live)
    elif recovering and verified_digest(engine) != digest:
        raise ValueError("Promoted SDK differs from its publication record")
    for name in HEADERS:
        write_atomic(pending, headers / name, (engine / "Headers" / name).read_bytes())
    # The pin is the commit marker for existing fail-closed SDK readers.
    write_atomic(pending, pin, f"{digest}\n".encode())
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


def publish(package, architecture, replace, build, script):
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
        if directory_id(pending) is not None:
            recovered, digest = finish(package, pending, recovering=True)
            print(f"Recovered SDK publication: {recovered} ({digest})")
        for abandoned in state.parent.glob(".publication-*"):
            if is_publication_slot(abandoned.name):
                directory_id(abandoned)
                remove_work(abandoned)
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
            subprocess.run(["/bin/bash", script, "--prepare", work, prepared, "--arch", architecture, build, package],
                           check=True, pass_fds=(lock,))
            digest = verified_digest(prepared)
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
                        print(f"Verified existing SDK: {engine}\nArtifact SHA: {digest}")
                        return
                if not replace:
                    raise ValueError(f"Engine already published. Use --replace to publish different inputs: {engine}")
            record = {"arch": architecture, "digest": digest, "identity": directory_id(candidate),
                      "slot": candidate.name}
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
    package, architecture, replace, build, script = sys.argv[1:]
    try:
        publish(Path(package), architecture, replace == "true", build, script)
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
