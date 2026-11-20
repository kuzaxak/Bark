"""Record and verify official Bark SDK build provenance against the pinned recipe."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "scripts"))
from chromium_sdk_layout import file_digest as digest, official_framework_inputs

PINS = json.loads((HERE / "PINS.json").read_text())
CHROMIUM_VERSION = (HERE / "CHROMIUM_VERSION").read_text().strip()
RECEIPT = "official-build.json"
FRAMEWORK = "Bark Framework.framework"
RAW_FRAMEWORK_IMAGE = Path("obj/chrome/chrome_framework_shared_library/Bark Framework")
BROWSER_OBJECT = Path("obj/chrome/browser/core/browser_process_impl.o")
V8_BUILTINS_PROFILE = Path("v8/tools/builtins-pgo/profiles/x64.profile")
ARCHES = {"x86_64": ("x64", "mac"), "arm64": ("arm64", "mac-arm")}


def framework_inputs(framework, arch):
    return official_framework_inputs(framework, arch, PINS["official_macos_sdk"],
                                     CHROMIUM_VERSION, PINS["chromium"])


def engine_source_digest():
    from build_engine import REPO, preparation_inputs, recipe_digest

    mounts, patches = preparation_inputs()
    # The SDK ships the engine and matcher. Bark's browser-test overlay is
    # another target in the same invocation, with no runtime dependencies.
    inputs = {name: path for name, path in mounts.items()
              if not name.is_relative_to(Path("bark/test"))}
    rust = REPO / "Nook/ThirdParty/AdblockRustFFI"
    sources = [HERE / "checkout.gclient", HERE / "official_pgo.star",
               rust / "Cargo.toml", rust / "Cargo.lock", rust / "nook_adblock.exports"]
    sources.extend(path for path in sorted((rust / "src").rglob("*")) if path.is_file())
    inputs.update((path.relative_to(REPO), path) for path in sources)
    return recipe_digest(inputs, patches)


def recipe_inputs(arch):
    from build_engine import engine_args

    gn_arch, target = ARCHES[arch]
    return {
        "format": 3,
        "arch": arch,
        "chromium": PINS["chromium"],
        "depot_tools": PINS["depot_tools"],
        "engine_source_sha256": engine_source_digest(),
        "SDK": PINS["official_macos_sdk"],
        "gn_args_sha256": sha256(engine_args(gn_arch, True)).hexdigest(),
        "v8_builtins": PINS["official_v8_builtins"],
        "pgo_profile": PINS["official_pgo_profiles"][target],
        "pgo_sha256": PINS["official_pgo_sha256"][target],
    }


class PgoProfileDigestMismatch(ValueError):
    pass


def pgo_profile_path(src, target):
    name = PINS["official_pgo_profiles"][target]
    data = src / "chrome/build"
    if (data / f"{target}.pgo.txt").read_text().strip() != name:
        raise ValueError("The Chromium PGO selector does not match the Bark pin")
    cache = data / "pgo_profiles"
    if cache.is_symlink() or (cache.exists() and not cache.is_dir()):
        raise ValueError(f"Expected a local PGO profile cache directory: {cache}")
    return cache / name


def regular_cache_file(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"Expected a regular PGO cache file: {path}")
    return True


def v8_builtins_path(src):
    pin = PINS["official_v8_builtins"]
    profile = src / V8_BUILTINS_PROFILE
    expected_directory = src.resolve() / V8_BUILTINS_PROFILE.parent
    if profile.parent.resolve(strict=True) != expected_directory:
        raise ValueError(f"Expected a local V8 builtins profile directory: {profile.parent}")
    revision = subprocess.check_output(["git", "-C", src / "v8", "rev-parse", "HEAD"], text=True).strip()
    if revision != pin["revision"]:
        raise ValueError(f"The V8 builtins profile requires revision {pin['revision']}, found {revision}")
    return profile


def verify_v8_builtins(src):
    profile = v8_builtins_path(src)
    if not regular_cache_file(profile) or digest(profile) != PINS["official_v8_builtins"]["sha256"]:
        raise ValueError("The V8 builtins profile does not match the pinned SHA-256")


def acquire_v8_builtins(src, download):
    # Both macOS targets use V8's x64 hints when producing their snapshot.
    profile = v8_builtins_path(src)
    pin = PINS["official_v8_builtins"]
    cached = regular_cache_file(profile)
    if cached and digest(profile) == pin["sha256"]:
        return
    url = f"https://storage.googleapis.com/chromium-v8-builtins-pgo/by-version/{pin['version']}/{profile.name}"
    print(f"Fetching the pinned V8 builtins profile from {url}", flush=True)
    with tempfile.TemporaryDirectory(dir=profile.parent) as scratch:
        staged = Path(scratch) / profile.name
        download(url, staged)
        if digest(staged) != pin["sha256"]:
            raise ValueError("The downloaded V8 builtins profile does not match the pinned SHA-256")
        if cached:
            rejected = Path(tempfile.mkdtemp(prefix=".bark-rejected-v8-", dir=profile.parent.parent))
            os.link(profile, rejected / profile.name)
            print(f"Preserved the rejected V8 builtins profile in {rejected}", flush=True)
        staged.replace(profile)


def verify_pgo_profile(src, target):
    profile = pgo_profile_path(src, target)
    if not regular_cache_file(profile):
        raise ValueError(f"The pinned Chromium PGO profile is missing: {profile}")
    if digest(profile) != PINS["official_pgo_sha256"][target]:
        raise PgoProfileDigestMismatch(f"The Chromium PGO profile SHA-256 differs from the Bark pin: {profile}")
    return profile


def acquire_pgo_profile(src, target, update):
    """Fetch through Chromium, preserving a bad cached file before one retry."""
    profile = pgo_profile_path(src, target)
    was_cached = regular_cache_file(profile)
    regular_cache_file(profile.with_name(profile.name + ".lock"))
    update()
    try:
        return verify_pgo_profile(src, target)
    except PgoProfileDigestMismatch:
        if not was_cached:
            raise

    # Chromium prunes old entries in pgo_profiles, so keep rejected bytes
    # outside that directory. The recipe already holds the checkout lock.
    rejected = Path(tempfile.mkdtemp(prefix=".bark-rejected-pgo-", dir=profile.parent.parent))
    try:
        profile.rename(rejected / profile.name)
    except OSError:
        rejected.rmdir()
        raise
    print(f"Preserved the rejected PGO cache file in {rejected}", flush=True)
    update()
    return verify_pgo_profile(src, target)


def verify_pgo_compile(out, src, profile, expected_hash, linked, env):
    flags = subprocess.check_output(["gn", "desc", str(out), "//chrome/browser:core", "cflags"],
                                    cwd=src, env=env, text=True).splitlines()
    paths = [line.strip().removeprefix("-fprofile-use=") for line in flags
             if line.strip().startswith("-fprofile-use=")]
    if len(paths) != 1 or (out / paths[0]).resolve() != profile:
        raise ValueError("The Chromium browser core does not use the pinned PGO profile")
    state = subprocess.check_output(["siso", "fs", "export", "-C", out], cwd=src, env=env)
    entries = {entry["name"]: entry for entry in json.loads(state)["entries"]}
    profile_entry = entries.get(str(profile), {})
    if profile_entry.get("digest", {}).get("hash") != expected_hash:
        raise ValueError("The official build has no matching Siso input record for the pinned PGO profile")
    link_entry = entries.get(str(linked), {})
    link_time = int(link_entry.get("id", {}).get("mod_time", 0))
    link_hash = digest(linked)
    if (not link_entry.get("cmd_hash") or not link_entry.get("edge_hash") or
            link_time != linked.stat().st_mtime_ns or link_entry.get("digest", {}).get("hash") != link_hash):
        raise ValueError("The official build has no matching Siso link record for the raw framework image")

    browser_object = out / BROWSER_OBJECT
    compiled = entries.get(str(browser_object), {})
    compiled_time = int(compiled.get("id", {}).get("mod_time", 0))
    profile_time = int(profile_entry.get("id", {}).get("mod_time", 0))
    if (not compiled.get("cmd_hash") or not compiled.get("edge_hash") or
            not 0 < profile_time <= compiled_time <= link_time or
            not browser_object.is_file() or
            compiled.get("digest", {}).get("hash") != digest(browser_object)):
        raise ValueError("The official build has no matching Siso browser compile before the framework link")
    return link_hash


def record(out, src, arch, env):
    expected = recipe_inputs(arch)
    _, target = ARCHES[arch]
    verify_v8_builtins(src)
    profile = verify_pgo_profile(src, target)
    if digest(out / "args.gn") != expected["gn_args_sha256"]:
        raise ValueError("The actual GN arguments do not match the official recipe")
    linked = out / RAW_FRAMEWORK_IMAGE
    link_hash = verify_pgo_compile(out, src, profile, expected["pgo_sha256"], linked, env)
    framework = out / "Bark.app/Contents/Frameworks" / FRAMEWORK
    packaged = framework_inputs(framework, arch)
    if link_hash != packaged["framework_sha256"]:
        raise ValueError("The packaged official framework differs from the raw linked image")
    return {**expected, **packaged}


def verify(receipt, framework, arch):
    actual = framework_inputs(framework, arch)
    if receipt.is_symlink() or not receipt.is_file():
        raise ValueError("No official Bark SDK build receipt. Build the pinned engine with --official.")
    data = json.loads(receipt.read_text())
    expected = {**recipe_inputs(arch), **actual}
    if data != expected:
        raise ValueError("The official SDK receipt does not match the pinned recipe and framework")


def verify_cached(artifact, arch):
    receipt = artifact / RECEIPT
    verify(receipt, artifact / FRAMEWORK, arch)
    expected = f"{digest(receipt)}  ./{RECEIPT}"
    if (artifact / "SHA256SUMS").read_text().splitlines().count(expected) != 1:
        raise ValueError("The official SDK receipt is missing from the pinned artifact manifest")


def verify_publication(out, arch, env):
    receipt = out / RECEIPT
    if receipt.is_symlink() or not receipt.is_file():
        raise ValueError("Expected a regular official SDK build receipt")
    if json.loads(receipt.read_text()) != record(out, out.parent.parent, arch, env):
        raise ValueError("The official SDK receipt differs from the direct build outputs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("arch", choices=ARCHES)
    args = parser.parse_args()
    try:
        verify_publication(args.build.resolve(strict=True), args.arch, os.environ)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
