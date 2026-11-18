#!/usr/bin/env python3
"""Exercise helper argument admission without loading the Chromium framework."""

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
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


def check(binary, arguments, admitted):
    result = subprocess.run([binary, *arguments], capture_output=True,
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


def main():
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
                check(binary, arguments, admitted=True)
            for arguments in REFUSED:
                check(binary, arguments, admitted=False)
    print("Both helper entry point languages admit subprocess roles and reject direct launches")


if __name__ == "__main__":
    main()
