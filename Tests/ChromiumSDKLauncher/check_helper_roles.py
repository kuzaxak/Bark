#!/usr/bin/env python3
"""Exercise helper argument admission without starting a browser session."""

import argparse
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "scripts"))
from chromium_sdk_layout import native_architecture

PROBE = """
#include "sdk_helper_role.h"

int main(int argc, char* argv[]) {
  if (!BarkHasHelperProcessRole(argc, argv)) {
    return BarkRefuseUnownedHelperLaunch();
  }
  return 0;
}
"""
ALLOWED = [
    ["--type=renderer"], ["--type=gpu-process"], ["--type=utility"],
    ["--type=relauncher", "---", "/Applications/Bark.app"],
    ["--type=code-sign-clone-cleanup"], ["--type=no-op-for-testing"],
    ["--sandbox-debugging", "-type=utility", "--", "--type="],
]
REFUSED = [
    [], ["-psn_0_12345"], ["--type"], ["--type="], ["--type=browser"],
    ["--type=renderer=app"], ["--type", "renderer"], ["type=renderer"],
    ["--", "--type=renderer"], ["  --\t", "--type=renderer"],
    ["--type=renderer", "--type="], ["--type=utility", " -type\t"],
    ["--type=renderer", "--type=utility"], ["--type=renderér"],
]


def check(command, arguments, admitted):
    result = subprocess.run([*command, *arguments], capture_output=True,
                            text=True, timeout=5)
    if admitted:
        expected = (0, "", "")
    else:
        expected = (
            69, "",
            "Bark Helper requires a Chromium subprocess role. Launch the signed Bark app.\n",
        )
    if (result.returncode, result.stdout, result.stderr) != expected:
        raise SystemExit(f"Unexpected helper admission for {arguments!r}: {result!r}")


def check_source():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        source = path / "probe.c"
        source.write_text(PROBE)
        for language in ("c", "c++"):
            binary = path / f"probe-{language}"
            subprocess.run(
                ["xcrun", "clang", "-x", language, "-Wall", "-Wextra", "-Werror", "-Wunsafe-buffer-usage",
                 "-I", ROOT / "Runtime/Chromium/bark/app", source, "-o", binary],
                check=True,
            )
            for arguments in ALLOWED:
                check([binary], arguments, admitted=True)
            for arguments in REFUSED:
                check([binary], arguments, admitted=False)
    print("Both helper entry point languages admit subprocess roles and reject direct launches")


def check_packaged(app):
    app = app.resolve(strict=True)
    if plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier") != "ee.qdo.bark":
        raise SystemExit("Select the signed Bark application.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    helpers = app / "Contents/Frameworks/Bark Framework.framework/Versions/Current/Helpers"
    if not (helpers / "Bark Helper.app").is_dir():
        raise SystemExit("The signed app has no Bark Helper.")
    bundles = sorted(helpers.glob("*.app"))
    architecture = native_architecture()
    # Aperitif helpers link the framework at load time. Exercise the real
    # installed layout, while preventing a regressed helper from contacting
    # WindowServer, starting children, or writing a profile.
    policy = "(version 1)(allow default)(deny mach-lookup)(deny file-write*)(deny network*)(deny process-fork)"
    for bundle in bundles:
        executable = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
        if executable != bundle.stem:
            raise SystemExit(f"Unexpected helper executable in {bundle.name}: {executable}")
        binary = bundle / "Contents/MacOS" / executable
        subprocess.run(["/usr/bin/lipo", binary, "-verify_arch", architecture], check=True)
        for arguments in REFUSED:
            check(["/usr/bin/sandbox-exec", "-p", policy, binary], arguments, admitted=False)
    print(f"All {len(bundles)} packaged {architecture} helpers refused {len(REFUSED)} direct launches each.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="exercise the helpers from a signed Bark.app on its native Mac")
    app = parser.parse_args().app
    if app:
        check_packaged(app)
    else:
        check_source()
