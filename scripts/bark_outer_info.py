# Licensed under GPL-3.0. See LICENSE.
"""Apply Bark's shipping registration when staging the Xcode build component."""

from pathlib import Path
import plistlib
import re
import sys

from bark_release import HANDLER_KEYS


BUILD_ID = "ee.qdo.bark.build"


def verify_build_info(info):
    required = {"CFBundleIdentifier": BUILD_ID, "CFBundleExecutable": "Bark", "CFBundlePackageType": "APPL"}
    if any(info.get(key) != value for key, value in required.items()) or info.get("LSBackgroundOnly") is not True:
        raise ValueError("Expected the background-only Bark build component")
    interactive = set(HANDLER_KEYS) | {"NSPrincipalClass", "OSAScriptingDefinition", "NSAppleScriptEnabled"}
    if found := interactive.intersection(info):
        raise ValueError(f"Bark build component declares interactive services: {', '.join(sorted(found))}")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "BarkChromiumVersion"):
        value = info.get(key)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
            raise ValueError(f"Invalid build component version in {key}")


def materialize_info(info, template):
    verify_build_info(info)
    settings = {
        "EXECUTABLE_NAME": info["CFBundleExecutable"],
        "PRODUCT_NAME": "Bark",
        "PRODUCT_BUNDLE_IDENTIFIER": "ee.qdo.bark",
        "MARKETING_VERSION": info["CFBundleShortVersionString"],
        "CURRENT_PROJECT_VERSION": info["CFBundleVersion"],
        "CHROMIUM_ENGINE_VERSION": info["BarkChromiumVersion"],
    }

    def expand(match):
        name = match.group(1).decode()
        if name not in settings:
            raise ValueError(f"Unknown build setting in Bark's shipping Info.plist: {name}")
        return settings[name].encode()

    # Only validated version numbers and fixed product identifiers enter this XML.
    result = plistlib.loads(re.sub(rb"\$\(([^)]+)\)", expand, plistlib.dumps(template)))
    for key, value in info.items():
        if key.startswith("DT") or key in {"BuildMachineOSBuild", "CFBundleSupportedPlatforms"}:
            result[key] = value
    return result


if __name__ == "__main__":
    try:
        output = Path(sys.argv[1])
        template = Path(__file__).resolve().parents[1] / "ChromiumApp/Info.plist"
        info = materialize_info(plistlib.loads(output.read_bytes()), plistlib.loads(template.read_bytes()))
        output.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
