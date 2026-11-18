"""Record and verify official Bark SDK build provenance against the pinned recipe."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE / "PINS.json").read_text())
CHROMIUM_VERSION = (HERE / "CHROMIUM_VERSION").read_text().strip()
RECEIPT = "official-build.json"
FRAMEWORK = "Bark Framework.framework"
ARCHES = {"x86_64": ("x64", "mac"), "arm64": ("arm64", "mac-arm")}


def digest(path):
    with path.open("rb") as stream:
        result = sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
        return result.hexdigest()


def framework_inputs(framework, arch):
    relative = Path("Versions/Current")
    info_path = framework / relative / "Resources/Info.plist"
    image = framework / relative / "Bark Framework"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    sdk = PINS["official_macos_sdk"]
    if (info.get("DTSDKName"), info.get("DTSDKBuild")) != ("macosx" + sdk["version"], sdk["build"]):
        raise ValueError(f"Official Bark SDK requires embedded macOS {sdk['version']} ({sdk['build']}); "
                         f"framework reports {info.get('DTSDKName')} ({info.get('DTSDKBuild')})")
    if info.get("CFBundleShortVersionString") != CHROMIUM_VERSION:
        raise ValueError("The framework version does not match pinned Chromium")
    revision = str(info.get("SCMRevision", "")).partition("-")[0]
    if revision != PINS["chromium"]:
        raise ValueError("The framework revision does not match pinned Chromium")
    if subprocess.check_output(["/usr/bin/lipo", "-archs", image], text=True).strip() != arch:
        raise ValueError(f"The official framework must be thin {arch}")
    commands = subprocess.check_output(["/usr/bin/otool", "-l", image], text=True)
    sdk_commands = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)"
                              r"\s+minos [\d.]+\s+sdk ([\d.]+)", commands)
    if sdk_commands != [("1", sdk["version"])]:
        raise ValueError(f"The framework Mach-O does not report the pinned macOS SDK: {sdk_commands}")
    return {"framework_sha256": digest(image), "framework_info_sha256": digest(info_path)}


def recipe_inputs(arch):
    from build_engine import engine_args

    gn_arch, target = ARCHES[arch]
    return {
        "format": 1,
        "arch": arch,
        "chromium": PINS["chromium"],
        "SDK": PINS["official_macos_sdk"],
        "gn_args_sha256": sha256(engine_args(gn_arch, True)).hexdigest(),
        "pgo_profile": PINS["official_pgo_profiles"][target],
    }


def record(out, src, arch, env):
    expected = recipe_inputs(arch)
    _, target = ARCHES[arch]
    pin = expected["pgo_profile"]
    if (src / "chrome/build" / f"{target}.pgo.txt").read_text().strip() != pin:
        raise ValueError("The Chromium PGO selector does not match the Bark pin")
    profile = src / "chrome/build/pgo_profiles" / pin
    pgo_hash = digest(profile)
    flags = subprocess.check_output(["gn", "desc", str(out), "//chrome/browser:browser", "cflags"],
                                    cwd=src, env=env, text=True).splitlines()
    if not any(flag.startswith("-fprofile-use=") and
               (out / flag.removeprefix("-fprofile-use=")).resolve() == profile for flag in flags):
        raise ValueError("The generated Chromium browser target does not use the pinned PGO profile")
    framework = out / "Bark.app/Contents/Frameworks" / FRAMEWORK
    linked = (framework / "Versions/Current/Bark Framework").stat().st_mtime_ns
    # Siso retains the digest of the profile input it actually read.
    state = subprocess.check_output(["siso", "fs", "export", "-C", out], cwd=src, env=env)
    for entry in json.loads(state)["entries"]:
        if (entry.get("name") == str(profile) and entry.get("digest", {}).get("hash") == pgo_hash
                and int(entry.get("id", {}).get("mod_time", linked + 1)) <= linked):
            break
    else:
        raise ValueError("The official build has no matching Siso input record for the pinned PGO profile")
    if digest(out / "args.gn") != expected["gn_args_sha256"]:
        raise ValueError("The actual GN arguments do not match the official recipe")
    return {**expected, **framework_inputs(framework, arch), "pgo_sha256": pgo_hash}


def verify(receipt, framework, arch):
    actual = framework_inputs(framework, arch)
    if receipt.is_symlink() or not receipt.is_file():
        raise ValueError("No official Bark SDK build receipt. Build the pinned engine with --official.")
    data = json.loads(receipt.read_text())
    expected = {**recipe_inputs(arch), **actual}
    if (not isinstance(data, dict) or data.keys() != expected.keys() | {"pgo_sha256"}
            or any(data.get(key) != value for key, value in expected.items())
            or not re.fullmatch("[0-9a-f]{64}", str(data.get("pgo_sha256")))):
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
