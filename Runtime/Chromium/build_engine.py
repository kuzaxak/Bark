#!/usr/bin/env python3
"""Prepare, verify or build the pinned Bark Chromium engine."""
import argparse
import fcntl
import json
from hashlib import sha256
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from replay_gate import HERE, MOUNTS, PATCHES, PINS, check_pin, temporary_index

REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "scripts"))
from chromium_sdk_layout import GN_CPU, native_architecture

ORIGINS = {
    "chromium": "https://chromium.googlesource.com/chromium/src.git",
    "depot_tools": "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
}
TARGETS = ("chrome", "chrome/installer/mac", "bark_browser_tests")


def run(command, cwd=REPO, env=None, dry_run=False):
    command = list(map(str, command))
    print(f"{cwd}: {shlex.join(command)}", flush=True)
    if not dry_run:
        subprocess.run(command, cwd=cwd, env=env, check=True)


def git(path, *args, required=True, strip=True):
    result = subprocess.run(
        ["git", "-C", str(path), *args], capture_output=True, text=True,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if result.returncode and required:
        raise ValueError(f"{path}: {result.stderr.strip()}")
    if result.returncode:
        return None
    return result.stdout.strip() if strip else result.stdout


def repository(path, name, create, dry_run):
    pin = PINS[name]
    if path.is_dir() and git(path, "rev-parse", "--show-toplevel", required=False) == str(path):
        head = git(path, "rev-parse", "--verify", "HEAD", required=False)
        if head:
            if head != pin:
                raise ValueError(f"{path}: {name} HEAD is {head}, expected {pin}")
            if name == "depot_tools" and git(path, "status", "--porcelain"):
                raise ValueError(f"{path}: depot_tools has working-tree changes")
            return True
        origin = git(path, "remote", "get-url", "origin", required=False)
        if set(p.name for p in path.iterdir()) != {".git"} or origin not in (None, ORIGINS[name]):
            raise ValueError(f"{path}: unfinished repository is not empty or has another origin")
    else:
        origin = None
        if path.exists() and (not path.is_dir() or any(path.iterdir())):
            raise ValueError(f"{path}: expected an empty directory or the pinned {name} Git checkout")
        if create:
            run(["git", "init", path], dry_run=dry_run)
    if not create:
        raise ValueError(f"{path}: missing pinned {name} checkout. Run prepare first")
    if origin is None:
        run(["git", "-C", path, "remote", "add", "origin", ORIGINS[name]], dry_run=dry_run)
    run(["git", "-C", path, "-c", "protocol.version=2", "fetch", "--depth=1",
         "--no-tags", "origin", pin], dry_run=dry_run)
    run(["git", "-C", path, "checkout", "--detach", pin], dry_run=dry_run)
    return not dry_run


def budget():
    run([sys.executable, HERE / "budget.py", "--check"])


def patches(src, *options, inputs=None, dry_run=False):
    if inputs is None:
        inputs = sorted(PATCHES.rglob("*.patch"))
    if not inputs:
        return
    mode = "check" if "--check" in options else "apply"
    print(f"{src}: {mode} {len(inputs)} tracked Chromium patches", flush=True)
    if not dry_run:
        result = subprocess.run(["git", "apply", *options, *inputs], cwd=src)
        if result.returncode:
            raise ValueError(f"{src}: could not {mode} Chromium patches (see Git diagnostics above)")


def replay(src):
    run([sys.executable, HERE / "replay_gate.py", src])


def pristine(src):
    return not git(src, "status", "--porcelain", "--untracked-files=normal") and not any(
        (src / mount).exists() or (src / mount).is_symlink() for mount in MOUNTS
    )


def preparation_inputs():
    mounts = {}
    for name, directory in MOUNTS.items():
        for path in sorted(directory.rglob("*")):
            if path.is_symlink() and not path.is_file():
                raise ValueError(f"{path}: missing mounted file")
            if path.is_file():
                mounts[Path(name) / path.relative_to(directory)] = path
    recipe_patches = {
        patch.relative_to(PATCHES).as_posix().removesuffix(".patch"): patch
        for patch in sorted(PATCHES.rglob("*.patch"))
    }
    return mounts, recipe_patches


def recipe_digest(mounts, recipe_patches):
    digest = sha256()
    for name, source in (*mounts.items(), *recipe_patches.items()):
        digest.update(os.fsencode(name) + b"\0")
        digest.update(bytes([os.access(source, os.X_OK)]))
        digest.update(sha256(source.read_bytes()).digest())
    return digest.hexdigest()


def recover_preparation(src, mounts, recipe_patches):
    staged = git(src, "diff", "--cached", "--name-only", "HEAD")
    changed = git(src, "diff", "--name-only", "--no-renames", "-z", "HEAD", strip=False).split("\0")
    changed = [name for name in changed if name]
    untracked = git(src, "ls-files", "--others", "--exclude-standard", "--directory", "-z", strip=False).split("\0")
    allowed_roots = set(MOUNTS)
    if staged or any(name not in recipe_patches for name in changed) or any(
        name and name.split("/", 1)[0] not in allowed_roots for name in untracked
    ):
        raise ValueError(f"{src}: local changes outside the interrupted recipe")

    if changed:
        diff = ("diff", "--no-color", "--no-textconv", "--no-ext-diff", "--no-renames",
                "--src-prefix=a/", "--dst-prefix=b/", "--binary", "--full-index")
        with temporary_index(src) as index_git:
            index_git("apply", "--cached", *[recipe_patches[name] for name in changed])
            expected = index_git(*diff, "--cached", "HEAD", "--", *changed)
        if git(src, *diff, "HEAD", "--", *changed, strip=False) != expected:
            raise ValueError(f"{src}: local edits within Chromium patch files: {', '.join(changed)}")

    allowed_dirs = {parent for name in mounts for parent in name.parents}
    for name in MOUNTS:
        root = src / name
        if root.is_symlink() or (root.exists() and not root.is_dir()):
            raise ValueError(f"{root}: expected a recipe mount directory")
        for path in root.rglob("*"):
            relative = path.relative_to(src)
            source = mounts.get(relative)
            if not path.is_symlink():
                if path.is_dir() and relative in allowed_dirs:
                    continue
                if (source and path.is_file() and path.read_bytes() == source.read_bytes()
                        and os.access(path, os.X_OK) == os.access(source, os.X_OK)):
                    continue
            raise ValueError(f"{path}: differs from the interrupted recipe mount")
    return [patch for name, patch in recipe_patches.items() if name not in changed]


def apply_recipe(src, marker, dry_run=False):
    mounts, recipe_patches = preparation_inputs()
    digest = recipe_digest(mounts, recipe_patches)
    if marker.is_symlink():
        raise ValueError(f"{marker}: expected a local preparation marker")
    if marker.exists():
        if marker.read_text() != digest:
            raise ValueError(f"{marker}: interrupted preparation uses a different recipe")
        pending = recover_preparation(src, mounts, recipe_patches)
        patches(src, "--check", inputs=pending)
    else:
        pending = list(recipe_patches.values())
        patches(src, "--check", inputs=pending)
        if not dry_run:
            with tempfile.TemporaryDirectory(dir=marker.parent) as scratch:
                staged = Path(scratch) / "marker"
                with staged.open("w") as state:
                    state.write(digest)
                    state.flush()
                    os.fsync(state.fileno())
                os.link(staged, marker)
    if dry_run:
        print(f"{src}: would complete the recipe mounts and {len(pending)} pending patches")
        return

    with tempfile.TemporaryDirectory(dir=src.parent) as scratch:
        staged = Path(scratch) / "mount"
        for relative, source in mounts.items():
            dest = src / relative
            if dest.exists():
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, staged)
            os.link(staged, dest)
            staged.unlink()
    patches(src, inputs=pending)
    replay(src)
    marker.unlink()


def engine_env(depot_tools, jobs):
    return {
        **os.environ,
        "DEPOT_TOOLS_UPDATE": "0",
        "PATH": os.pathsep.join((str(depot_tools), os.environ["PATH"])),
        "SSL_CERT_FILE": os.environ.get("SSL_CERT_FILE", "/etc/ssl/cert.pem"),
        "CARGO_BUILD_JOBS": str(jobs),
    }


def verify_gclient(checkout, required=True):
    config = checkout / ".gclient"
    if config.is_symlink() or (config.exists() and config.read_bytes() != (HERE / "checkout.gclient").read_bytes()):
        raise ValueError(f"{config}: differs from the checked-in gclient configuration")
    if required and not config.is_file():
        raise ValueError(f"{config}: missing from prepared checkout")
    return config


def prepare(checkout, depot_tools, env, args):
    src = checkout / "src"
    gclient = verify_gclient(checkout, required=False)
    marker = checkout / ".bark-engine-preparing"
    if not args.resume and any(p.exists() or p.is_symlink() for p in (src, gclient, depot_tools)):
        raise ValueError("prepare expects a new checkout and depot_tools. Use --resume for existing paths")
    budget()
    if repository(src, "chromium", create=True, dry_run=args.dry_run):
        check_pin(src)
        if marker.exists() or marker.is_symlink():
            if not args.resume:
                raise ValueError("use prepare --resume to finish the interrupted recipe")
            verify_gclient(checkout)
            repository(depot_tools, "depot_tools", create=False, dry_run=args.dry_run)
            apply_recipe(src, marker, dry_run=args.dry_run)
            return
        if not pristine(src):
            print("Checking existing Bark changes before resuming", flush=True)
            replay(src)
            repository(depot_tools, "depot_tools", create=False, dry_run=args.dry_run)
            verify_gclient(checkout)
            return
        patches(src, "--check")
    repository(depot_tools, "depot_tools", create=True, dry_run=args.dry_run)
    if not args.dry_run:
        if not gclient.exists():
            install_generated(HERE / "checkout.gclient", gclient)
    run([depot_tools / "ensure_bootstrap"], checkout, env, args.dry_run)
    run([depot_tools / "gclient", "sync", "--no-history", "--nohooks",
         "--revision", f"src@{PINS['chromium']}", "--jobs", args.jobs], checkout, env, args.dry_run)
    run([depot_tools / "gclient", "runhooks", "--jobs", args.jobs], checkout, env, args.dry_run)
    if args.dry_run:
        patches(src, "--check", dry_run=True)
        print("Then copy Bark's trees, apply the patches and verify the replay.")
        return
    check_pin(src)
    if not pristine(src):
        raise ValueError(f"{src}: dependency setup left working-tree changes")
    apply_recipe(src, marker)


def install_generated(source, destination):
    if destination.is_symlink():
        raise ValueError(f"{destination}: expected a regular file")
    if destination.exists() and source.read_bytes() == destination.read_bytes():
        return
    # Leave an existing usable input in place if the copy is interrupted.
    with tempfile.TemporaryDirectory(dir=destination.parent) as scratch:
        staged = Path(scratch) / destination.name
        shutil.copy2(source, staged)
        staged.replace(destination)


def official_sdk():
    """Require the selected Xcode's default macOS SDK for both GN and Cargo."""
    path = Path(subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                        text=True).strip())
    with (path / "System/Library/CoreServices/SystemVersion.plist").open("rb") as info:
        installed = plistlib.load(info)
    required = PINS["official_macos_sdk"]
    version, build_id = installed.get("ProductVersion"), installed.get("ProductBuildVersion")
    if (version, build_id) != (required["version"], required["build"]):
        raise ValueError(f"Official Bark builds require the macOS {required['version']} SDK "
                         f"({required['build']}). Selected Xcode provides {version} ({build_id}) at {path}")
    return path


DEVELOPER_CC_WRAPPER = "bark_override_cc"
OFFICIAL_CC_WRAPPER = "bark_official_pgo_cc_v1"


def compiler_wrapper_arg(wrapper):
    return f'cc_wrapper = "./{wrapper}"\n'.encode()


def engine_args(arch, official):
    contents = (HERE / f"args-{arch}.gn").read_bytes()
    if not official:
        return contents
    developer_mode = b"is_official_build = false\n"
    if contents.splitlines(keepends=True).count(developer_mode) != 1:
        raise ValueError(f"args-{arch}.gn: missing developer build setting")
    developer_wrapper = compiler_wrapper_arg(DEVELOPER_CC_WRAPPER)
    if contents.splitlines(keepends=True).count(developer_wrapper) != 1:
        raise ValueError(f"args-{arch}.gn: missing developer compiler wrapper")
    # Keep the witnessed compile distinct from previous, unwitnessed Siso actions.
    contents = contents.replace(developer_wrapper, compiler_wrapper_arg(OFFICIAL_CC_WRAPPER))
    version = PINS["official_macos_sdk"]["version"]
    return contents.replace(developer_mode, (
        'is_official_build = true\nchrome_pgo_phase = 2\nuse_system_xcode = true\n'
        f'mac_sdk_min = "{version}"\n').encode())


def build(checkout, depot_tools, env, args):
    verify_gclient(checkout)
    src = checkout / "src"
    repository(src, "chromium", create=False, dry_run=args.dry_run)
    repository(depot_tools, "depot_tools", create=False, dry_run=args.dry_run)
    if args.official and not args.dry_run:
        from official_provenance import engine_source_digest

        official_source = engine_source_digest()
        env = {**env, "SDKROOT": str(official_sdk())}
    replay(src)
    configured_args = engine_args(args.arch, args.official)
    suffix = "-official" if args.official else ""
    out = src / "out" / f"Barc-{args.arch}{suffix}"
    output_args = out / "args.gn"
    if out.parent.is_symlink() or out.is_symlink() or output_args.is_symlink():
        raise ValueError(f"{out}: symlinked build output or args.gn")
    existing_args = None
    if output_args.is_file():
        existing_args = output_args.read_bytes()
        prior_official_args = configured_args.replace(compiler_wrapper_arg(OFFICIAL_CC_WRAPPER),
                                                      compiler_wrapper_arg(DEVELOPER_CC_WRAPPER))
        if existing_args != configured_args and not (args.official and existing_args == prior_official_args):
            raise ValueError(f"{output_args}: differs from the requested recipe. "
                             f"Move {out} aside and rerun to create a fresh GN output directory.")
    elif out.exists() and (not out.is_dir() or any(out.iterdir())):
        raise ValueError(f"{out}: nonempty output without recipe args.gn")

    rust = REPO / "Nook/ThirdParty/AdblockRustFFI"
    rust_target, macho_arch = {"x64": ("x86_64-apple-darwin", "x86_64"),
                             "arm64": ("aarch64-apple-darwin", "arm64")}[args.arch]
    rust_out = src / "out" / f"BarkCargo{suffix}"
    matcher = rust_out / rust_target / "release/libnook_adblock.dylib"
    wrapper = out / (OFFICIAL_CC_WRAPPER if args.official else DEVELOPER_CC_WRAPPER)
    if wrapper.is_symlink() or any(path.is_symlink() for path in
                                   (rust_out, rust_out / rust_target, matcher.parent, matcher)):
        raise ValueError(f"{out}: expected local wrapper and Rust build paths")
    if not args.dry_run:
        out.mkdir(parents=True, exist_ok=True)
        if existing_args != configured_args:
            with tempfile.TemporaryDirectory(dir=out) as scratch:
                staged = Path(scratch) / "args.gn"
                staged.write_bytes(configured_args)
                if (output_args.is_symlink() or
                        (output_args.read_bytes() if output_args.exists() else None) != existing_args):
                    raise ValueError(f"{output_args}: changed during build setup")
                staged.replace(output_args)
    if args.official:
        pgo_target = "mac" if args.arch == "x64" else "mac-arm"
        command = [sys.executable, src / "tools/update_pgo_profiles.py", f"--target={pgo_target}",
                   "update", "--gs-url-base=chromium-optimization-profiles/pgo_profiles"]
        if args.dry_run:
            run(command, src, env, True)
        else:
            from official_provenance import acquire_pgo_profile

            acquire_pgo_profile(src, pgo_target, lambda: run(command, src, env))
    run(["rustc", "--version"], src, env, args.dry_run)
    run(["cargo", "rustc", "--locked", "--release", "--jobs", args.jobs, "--target", rust_target,
         "--target-dir", rust_out, "--manifest-path", rust / "Cargo.toml", "--lib", "--crate-type", "cdylib", "--",
         "-C", "link-arg=-Wl,-install_name,@loader_path/Libraries/libnook_adblock.dylib",
         "-C", f"link-arg=-Wl,-exported_symbols_list,{rust / 'nook_adblock.exports'}"],
        src, {**env, "MACOSX_DEPLOYMENT_TARGET": "13.0"}, args.dry_run)
    if args.dry_run:
        run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror",
             "-o", wrapper, src / "bark/tools/override_cc.c"], src, env, True)
    else:
        actual_arch = subprocess.check_output(["/usr/bin/lipo", "-archs", matcher], text=True).strip()
        if actual_arch != macho_arch:
            raise ValueError(f"{matcher}: expected {macho_arch}, found {actual_arch}")
        with tempfile.TemporaryDirectory(dir=out) as scratch:
            compiled = Path(scratch) / wrapper.name
            run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-o", compiled, src / "bark/tools/override_cc.c"], src, env)
            install_generated(compiled, wrapper)
    run([depot_tools / "gn", "gen", out.relative_to(src), "--fail-on-unused-args"], src, env, args.dry_run)
    ninja = [depot_tools / "autoninja", "-C", out.relative_to(src), "-j", args.jobs]
    ninja_env = {**env, "NINJA_SUMMARIZE_BUILD": "1"}
    if args.official:
        # Delegate to Chromium's standard Siso config and add Bark's
        # official-only compiler handler in a private config directory.
        if args.dry_run:
            run([*ninja, "-config_repo_dir", (out / ".official-siso/siso").relative_to(src),
                 "-load", "@config//official_pgo.star", *TARGETS], src, ninja_env, True)
        else:
            with tempfile.TemporaryDirectory(prefix=".official-siso-", dir=out) as scratch:
                config = Path(scratch) / "siso"
                shutil.copytree(src / "build/config/siso", config)
                shutil.copy2(HERE / "official_pgo.star", config)
                run([*ninja, "-config_repo_dir", config.relative_to(src),
                     "-load", "@config//official_pgo.star", *TARGETS],
                    src, ninja_env)
    else:
        run([*ninja, *TARGETS], src, ninja_env, args.dry_run)
    if args.official and not args.dry_run:
        from official_provenance import RECEIPT, record

        receipt = record(out, src, macho_arch, env)
        if receipt["engine_source_sha256"] != official_source:
            raise ValueError("The Bark engine source recipe changed during the official build. Retry with stable inputs.")
        with tempfile.TemporaryDirectory(dir=out) as scratch:
            staged = Path(scratch) / RECEIPT
            staged.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
            install_generated(staged, out / RECEIPT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "check", "build"))
    parser.add_argument("--checkout", type=Path, required=True, help="gclient root containing src/")
    parser.add_argument("--depot-tools", type=Path, help="defaults to depot_tools beside the gclient root")
    parser.add_argument("--official", action="store_true", help="build with the pinned macOS SDK and Chromium PGO profile")
    parser.add_argument("--arch", choices=("x64", "arm64"), help="build architecture (defaults to native hardware)")
    parser.add_argument("--jobs", type=int, choices=range(1, 9), default=8, metavar="1..8")
    parser.add_argument("--resume", action="store_true", help="allow an existing pinned checkout during prepare")
    parser.add_argument("--dry-run", action="store_true", help="check existing inputs and print commands without writing")
    args = parser.parse_args()
    if (args.arch is not None or args.official) and args.action != "build":
        parser.error("--arch and --official select the configuration for build")
    if args.action == "build" and args.arch is None:
        args.arch = GN_CPU[native_architecture()]
    if args.resume and args.action != "prepare":
        parser.error("--resume is for prepare. Repeating build resumes the same output")
    checkout = args.checkout.expanduser().resolve()
    depot_tools = (args.depot_tools or checkout.parent / "depot_tools").expanduser().resolve()
    if checkout == depot_tools or checkout in depot_tools.parents or depot_tools in checkout.parents:
        parser.error("checkout and depot_tools must be separate directories")
    env = engine_env(depot_tools, args.jobs)

    if args.action == "check":
        verify_gclient(checkout)
        repository(checkout / "src", "chromium", create=False, dry_run=True)
        repository(depot_tools, "depot_tools", create=False, dry_run=True)
        replay(checkout / "src")
        return
    action = {"prepare": prepare, "build": build}[args.action]
    if args.dry_run:
        action(checkout, depot_tools, env, args)
        return
    if sys.platform != "darwin":
        raise ValueError("preparing and building the macOS engine requires macOS")
    if args.action == "prepare":
        checkout.mkdir(parents=True, exist_ok=True)
    lock_path = checkout / ".bark-engine.lock"
    if lock_path.is_symlink():
        raise ValueError(f"{lock_path}: expected a local lock file")
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError(f"{checkout}: another recipe process holds the engine lock") from error
        action(checkout, depot_tools, env, args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"build_engine: {error}")
