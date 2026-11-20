#!/usr/bin/env python3
"""Build and stage Bark's official Intel and Apple Silicon engines on the release runner."""

import argparse
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
RECIPE = REPO / "Runtime/Chromium"
sys.path[:0] = [str(RECIPE), str(REPO / "scripts")]

from build_engine import engine_args, official_sdk, preparation_inputs, recipe_digest
from chromium_sdk_layout import artifact_directory, native_architecture, read_pin
from official_provenance import recipe_inputs
from publish_chromium_sdk import verified_digest, verify_official_sdk
from replay_gate import PINS


ARCHITECTURES = (("x86_64", "x64"), ("arm64", "arm64"))
BUILD = RECIPE / "build_engine.py"
PUBLISH = REPO / "scripts/publish-chromium-engine.sh"
CHECK = REPO / "scripts/bark-check.py"
DEFAULT_CACHE = Path("~/Library/Caches/BarkSDK/gha-official")
RECIPE_INPUTS = (
    Path(__file__).resolve(), BUILD, RECIPE / "budget.py", RECIPE / "replay_gate.py",
    RECIPE / "official_provenance.py",
    PUBLISH, REPO / "scripts/publish_chromium_sdk.py",
    REPO / "scripts/chromium_sdk_layout.py", REPO / "scripts/check-chromium-architectures.py",
)


def run(*args, cwd=REPO, env=None):
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def capture(*args, cwd=REPO):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd, text=True).strip()


def fingerprint(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def checkout_key(sdk):
    return fingerprint({
        "chromium": PINS["chromium"],
        "depot_tools": PINS["depot_tools"],
        "gclient": (RECIPE / "checkout.gclient").read_text(),
        "sdk_path": str(sdk),
        "gn_args": [sha256(engine_args(gn_arch, True)).hexdigest() for _, gn_arch in ARCHITECTURES],
    })


def sdk_key(overlay_digest=None):
    inputs = {
        "format": 1,
        "host": native_architecture(),
        "receipt_inputs": [recipe_inputs(arch) for arch, _ in ARCHITECTURES],
        "recipe_tools": {path.name: sha256(path.read_bytes()).hexdigest() for path in RECIPE_INPUTS},
        "xcode": capture("xcodebuild", "-version"),
        "clang": capture("xcrun", "clang", "--version"),
        "rust": capture("rustc", "-vV"),
    }
    if overlay_digest is not None:
        inputs["overlay"] = overlay_digest
        launcher_check = REPO / "Tests/ChromiumSDKLauncher/check.py"
        inputs["launcher_check"] = sha256(launcher_check.read_bytes()).hexdigest()
    return fingerprint(inputs)


def read_state(path):
    if path.is_symlink():
        raise ValueError(f"{path}: expected a regular state file")
    return json.loads(path.read_text()) if path.exists() else {}


def write_state(path, data):
    with tempfile.TemporaryDirectory(prefix=".bark-runner-", dir=path.parent) as scratch:
        staged = Path(scratch) / path.name
        staged.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        staged.replace(path)


def prepare_checkout(checkout, revision, overlay_digest, jobs):
    checkout.mkdir(parents=True, exist_ok=True)
    path = checkout / ".bark-runner-recipe.json"
    state = read_state(path)
    applied = state.get("applied")
    pending = state.get("pending")
    desired = {"revision": revision, "overlay": overlay_digest}
    if pending and pending["overlay"] != overlay_digest:
        raise ValueError(f"{checkout}: finish the interrupted preparation for {pending['revision']} "
                         "before advancing to a different recipe")
    if applied and applied["overlay"] == overlay_digest:
        print(f"Reusing the prepared Chromium checkout at {checkout}", flush=True)
        return

    write_state(path, {"applied": applied, "pending": desired})
    if applied:
        run(sys.executable, "-B", BUILD, "update", "--checkout", checkout,
            "--from-revision", applied["revision"], "--jobs", jobs)
    else:
        run(sys.executable, "-B", BUILD, "prepare", "--resume", "--checkout", checkout, "--jobs", jobs)
    write_state(path, {"applied": desired})


def verified_sdk(package, arch):
    engine = artifact_directory(package, arch)
    if not engine.is_dir():
        return None
    try:
        if engine.is_symlink():
            raise ValueError("expected a regular Engine directory")
        pin = read_pin(package, arch)
        if verified_digest(engine) != pin:
            raise ValueError("the Engine manifest differs from the staged pin")
        verify_official_sdk(engine, arch)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"{arch} cached SDK failed verification: {error}", flush=True)
        return None
    return pin


def stage_pair(package, output):
    target = output / "Package"
    if target.resolve() == package:
        return target
    if target.exists() or target.is_symlink():
        raise ValueError(f"{target}: use a new output directory for a different SDK pair")
    with tempfile.TemporaryDirectory(prefix=".bark-engines-", dir=output) as scratch:
        copied = Path(scratch) / "Package"
        shutil.copytree(package, copied, symlinks=True)
        copied.replace(target)
    return target


def summary(text):
    print(text, flush=True)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with Path(path).open("a") as log:
            log.write(text + "\n")


def build_pair(args):
    if sys.platform != "darwin" or native_architecture() != "x86_64":
        raise ValueError("Run the official two-architecture build on the Intel macOS runner")
    mounts, patches = preparation_inputs()
    linked_inputs = sorted({source.resolve().relative_to(REPO) for source in mounts.values() if source.is_symlink()})
    if capture("git", "status", "--porcelain", "--untracked-files=normal", "--",
               "Runtime/Chromium", "Nook/ThirdParty/AdblockRustFFI", *linked_inputs):
        raise ValueError("Commit the Chromium and Rust recipe inputs before building")
    sdk = official_sdk(args.macos_sdk)
    root = args.cache_root.expanduser().resolve()
    checkout = (args.checkout.expanduser().resolve() if args.checkout else
                root / "checkouts" / checkout_key(sdk) / "checkout")
    output = args.output.expanduser().resolve()
    if any(path.is_relative_to(REPO) for path in (root, checkout, output)):
        raise ValueError("Keep Chromium cache, checkout and SDK staging outside the runner's Bark working tree")
    if output.is_relative_to(checkout) or checkout.is_relative_to(output):
        raise ValueError("Keep SDK staging separate from the Chromium checkout")
    revision = capture("git", "rev-parse", "--verify", "HEAD")
    overlay = recipe_digest(mounts, patches)
    key = sdk_key(overlay)
    package = root / "sdks" / key / "Package"

    root.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    with (root / ".bark-official-runner.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError(f"Another Bark release runner process is using {root}") from error

        target = output / "Package"
        if target.exists() and read_state(target / ".bark-runner-sdk-key.json").get("cache_key") == key:
            package = target
        elif target.exists() or target.is_symlink():
            raise ValueError(f"{output}: use a new SDK output directory for this recipe")
        pins = {arch: verified_sdk(package, arch) for arch, _ in ARCHITECTURES}
        for arch, pin in pins.items():
            if pin:
                summary(f"- {arch}: verified official SDK cache hit `{pin}`. Skipped GN and Ninja.")
        if not all(pins.values()):
            prepare_checkout(checkout, revision, overlay, args.jobs)
            depot_tools = checkout.parent / "depot_tools"
            env = {**os.environ, "DEPOT_TOOLS_UPDATE": "0",
                   "PATH": os.pathsep.join((str(depot_tools), os.environ["PATH"])),
                   "SSL_CERT_FILE": os.environ.get("SSL_CERT_FILE", "/etc/ssl/cert.pem")}
            for arch, gn_arch in ARCHITECTURES:
                if pins[arch]:
                    continue
                summary(f"- {arch}: running the official incremental Chromium build.")
                run(sys.executable, "-B", BUILD, "build", "--checkout", checkout,
                    "--arch", gn_arch, "--official", "--macos-sdk", sdk, "--jobs", args.jobs)
                build = checkout / "src/out" / f"Barc-{gn_arch}-official"
                run("/bin/bash", PUBLISH, "--arch", arch, "--require-official", "--replace",
                    build, package, cwd=checkout / "src", env=env)
                pins[arch] = verified_sdk(package, arch)
                if not pins[arch]:
                    raise ValueError(f"{arch} official SDK failed staging verification")
                summary(f"- {arch}: built and verified official SDK `{pins[arch]}`.")
        write_state(package / ".bark-runner-sdk-key.json", {"cache_key": key})
        staged = stage_pair(package, output)
        for arch, _ in ARCHITECTURES:
            if staged != package and verified_sdk(staged, arch) != pins[arch]:
                raise ValueError(f"{arch} SDK changed during staging")
        summary(f"- Verified both official SDKs for cache key `{key}`.")
        engines = {arch: artifact_directory(staged, arch) for arch, _ in ARCHITECTURES}
        run(sys.executable, "-B", CHECK, "pair-sdk", "--x86-64", engines["x86_64"],
            "--arm64", engines["arm64"], "--package", REPO / "Packages/BarkEngine")
        write_state(output / "engine-paths.json", {
            "cache_key": key,
            "engines": {arch: {"path": str(engine), "sha256": pins[arch]} for arch, engine in engines.items()},
        })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--macos-sdk", type=Path, required=True, help="stable path to the pinned Apple SDK")
    parser.add_argument("--output", type=Path, help="release job's SDK staging directory")
    parser.add_argument("--print-sdk-cache-key", action="store_true", help="print the exact SDK cache key without building")
    parser.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE, help="persistent runner-local cache")
    parser.add_argument("--checkout", type=Path, help="adopt an existing isolated pinned gclient checkout")
    parser.add_argument("--jobs", type=int, choices=range(1, 9), default=6)
    args = parser.parse_args()
    if not args.print_sdk_cache_key and args.output is None:
        parser.error("--output is required when building")
    try:
        if not shutil.which("rustc") or not shutil.which("cargo"):
            rust_bin = Path.home() / ".cargo/bin"
            os.environ["PATH"] = os.pathsep.join((str(rust_bin), os.environ["PATH"]))
        if args.print_sdk_cache_key:
            official_sdk(args.macos_sdk)
            print(sdk_key())
        else:
            build_pair(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"build_official_engines: {error}")


if __name__ == "__main__":
    main()
