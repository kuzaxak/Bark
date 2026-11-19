#!/usr/bin/env python3
"""Verify the built raw engine launcher without Finder or Launch Services."""

import argparse
import platform
import plistlib
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from chromium_sdk_layout import ARCHITECTURES, native_architecture


def read_plist(path):
    with path.open("rb") as file:
        return plistlib.load(file)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def check(build, architecture):
    raw_app = build / "Bark.app" / "Contents"
    raw = read_plist(raw_app / "Info.plist")
    require(raw.get("CFBundleIdentifier") == "ee.qdo.bark.sdk",
            "Raw engine uses the wrong bundle identifier")
    require(raw.get("LSBackgroundOnly") is True, "Raw engine is eligible for foreground use")
    require(not raw.keys() & {
        "CFBundleDocumentTypes", "CFBundleURLTypes", "NSUserActivityTypes",
        "NSPrincipalClass", "ASWebAuthenticationSessionWebBrowserSupportCapabilities",
        "UTExportedTypeDeclarations", "UTImportedTypeDeclarations",
    }, "Raw engine advertises interactive services")
    integrated = read_plist(
        build / "gen" / "chrome" / "chrome_integrated_app_info_plist.plist"
    )
    require(integrated.get("CFBundleIdentifier") == "ee.qdo.bark" and
            integrated.get("NSPrincipalClass") == "BrowserCrApplication" and
            integrated.get("LSBackgroundOnly") is not True and
            bool(integrated.get("CFBundleURLTypes")) and
            bool(integrated.get("CFBundleDocumentTypes")),
            "Integrated app metadata lost its interactive contract")
    require(raw.get("CFBundleExecutable") == "Bark", "Raw engine has an unexpected executable")
    executable = raw_app / "MacOS" / "Bark"

    actual_arch = subprocess.check_output(["/usr/bin/lipo", "-archs", executable], text=True).strip()
    require(actual_arch == architecture,
            f"Raw executable must be exactly {architecture}; found {actual_arch!r}")

    # Stop before execution if given an old build or a launcher linked to UI libraries.
    libraries = subprocess.check_output(
        ["/usr/bin/otool", "-L", executable], text=True
    ).splitlines()[1:]
    require([line.split()[0] for line in libraries] == ["/usr/lib/libSystem.B.dylib"],
            "Raw executable must link only libSystem")
    imports = subprocess.check_output(
        ["/usr/bin/nm", "-uj", executable], text=True
    ).splitlines()
    require(not set(imports) - {"___stderrp", "_fputs", "dyld_stub_binder"},
            "Raw executable imports functions outside the refusal path")
    hardware = native_architecture()
    tooling = platform.machine()
    if architecture != hardware:
        mode = f"tooling {tooling}, hardware {hardware}"
        print(f"Raw {architecture} launcher statically verified ({mode}); "
              "direct refusal cases require a native run.")
        return

    for arguments in [[], ["-psn_0_12345"], ["--type=renderer"], ["--type=gpu-process"],
                      ["--headless", "https://example.invalid"]]:
        result = subprocess.run([executable, *arguments], capture_output=True,
                                text=True, timeout=5)
        require(result.returncode == 69 and not result.stdout and
                result.stderr == "Bark Engine is an SDK build artifact. Launch the signed Bark app.\n",
                f"Raw engine did not refuse direct launch with {arguments!r}: {result!r}")
    print(f"Raw {architecture} launcher statically verified and all 5 native direct launch cases refused.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path, help="Chromium GN output directory")
    parser.add_argument("--arch", choices=ARCHITECTURES,
                        help="required thin Mach-O architecture (defaults to native hardware)")
    args = parser.parse_args()
    check(args.build.resolve(), args.arch or native_architecture())
