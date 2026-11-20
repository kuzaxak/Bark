# Licensed under GPL-3.0. See LICENSE.
"""Apply Bark's shipping registration when staging the Xcode build component."""

import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

from bark_release import HANDLER_KEYS


BUILD_ID = "ee.qdo.bark.build"
PERMISSION_KEYS = (
    "NSAudioCaptureUsageDescription",
    "NSBluetoothAlwaysUsageDescription",
    "NSBluetoothPeripheralUsageDescription",
    "NSCameraUsageDescription",
    "NSLocationUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSWebBrowserPublicKeyCredentialUsageDescription",
)
ENGLISH_REASON = "Once Bark has access, websites will be able to ask you for access."
UNMODIFIED_LOCALES = {"en", "en_GB", "en_XA", "ar_XB"}


def verify_build_info(info):
    required = {"CFBundleIdentifier": BUILD_ID, "CFBundleExecutable": "Bark", "CFBundlePackageType": "APPL"}
    if any(info.get(key) != value for key, value in required.items()) or info.get("LSBackgroundOnly") is not True:
        raise ValueError("Expected the background-only Bark build component")
    interactive = set(HANDLER_KEYS) | {"NSPrincipalClass", "OSAScriptingDefinition", "NSAppleScriptEnabled"}
    if found := interactive.intersection(info):
        raise ValueError(f"Bark build component declares interactive services: {', '.join(sorted(found))}")
    versions = ["CFBundleShortVersionString", "CFBundleVersion"]
    if "BarkChromiumVersion" in info:
        versions.append("BarkChromiumVersion")
    for key in versions:
        value = info.get(key)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
            raise ValueError(f"Invalid build component version in {key}")


def materialize_info(info, template, engine):
    verify_build_info(info)
    version = engine.get("CFBundleShortVersionString")
    revision = engine.get("SCMRevision")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", version):
        raise ValueError("Expected a four-part Chromium version in engine-Info.plist")
    if not isinstance(revision, str) or not revision.strip():
        raise ValueError("Missing Chromium SCMRevision in engine-Info.plist")
    # Earlier Xcode products carried their compile-time version in the plist.
    if "BarkChromiumVersion" in info and info["BarkChromiumVersion"] != version:
        raise ValueError("The build component version differs from the pinned engine")
    settings = {
        "EXECUTABLE_NAME": info["CFBundleExecutable"],
        "PRODUCT_NAME": "Bark",
        "PRODUCT_BUNDLE_IDENTIFIER": "ee.qdo.bark",
        "MARKETING_VERSION": info["CFBundleShortVersionString"],
        "CURRENT_PROJECT_VERSION": info["CFBundleVersion"],
    }

    def expand(match):
        name = match.group(1).decode()
        if name not in settings:
            raise ValueError(f"Unknown build setting in Bark's shipping Info.plist: {name}")
        return settings[name].encode()

    # Only validated version numbers and fixed product identifiers enter this XML.
    result = plistlib.loads(re.sub(rb"\$\(([^)]+)\)", expand, plistlib.dumps(template)))
    result["BarkChromiumVersion"] = version
    result["SCMRevision"] = revision
    for key, value in info.items():
        if key.startswith("DT") or key in {"BuildMachineOSBuild", "CFBundleSupportedPlatforms"}:
            result[key] = value
    return result


def localize_permission_reasons(resources, reasons):
    """Apply the app's Bark-branded Chromium translation of GRIT message 8013436988911883588."""
    if not isinstance(reasons, dict):
        raise ValueError("Expected a Bark permission translation catalog")
    if resources.is_symlink() or not resources.is_dir():
        raise ValueError(f"Expected copied Bark resources: {resources}")
    locales = {path.parent.stem: path.parent for path in resources.glob("*.lproj/InfoPlist.strings")
               if path.parent.stem not in UNMODIFIED_LOCALES}
    if missing := reasons.keys() - locales.keys():
        raise ValueError(f"Missing Bark permission localizations: {', '.join(sorted(missing))}")
    if unknown := locales.keys() - reasons.keys():
        raise ValueError(f"Missing Bark permission translations: {', '.join(sorted(unknown))}")
    updates = []
    for locale, directory in sorted(locales.items()):
        path = directory / "InfoPlist.strings"
        if directory.is_symlink() or path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected localized InfoPlist.strings for {locale}: {path}")
        reason = reasons[locale]
        if not isinstance(reason, str) or "Bark" not in reason or reason == ENGLISH_REASON:
            raise ValueError(f"Invalid Bark permission translation for {locale}")
        # ditto copies the source .strings verbatim. plutil also accepts XML,
        # binary and UTF-16 strings produced by other supported build paths.
        values = plistlib.loads(subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", path]))
        if not isinstance(values, dict):
            raise ValueError(f"Expected an InfoPlist.strings dictionary for {locale}")
        for key in PERMISSION_KEYS:
            if values.get(key) not in (ENGLISH_REASON, reason):
                raise ValueError(f"Unexpected Bark permission reason in {locale} {key}; review the translation catalog")
        if any(values[key] != reason for key in PERMISSION_KEYS):
            values.update(dict.fromkeys(PERMISSION_KEYS, reason))
            updates.append((path, plistlib.dumps(values, fmt=plistlib.FMT_BINARY)))
    for path, content in updates:
        path.write_bytes(content)


if __name__ == "__main__":
    try:
        output = Path(sys.argv[1])
        template = Path(__file__).resolve().parents[1] / "ChromiumApp/Info.plist"
        engine = Path(sys.argv[2])
        info = materialize_info(plistlib.loads(output.read_bytes()), plistlib.loads(template.read_bytes()),
                                plistlib.loads(engine.read_bytes()))
        reasons = json.loads(template.with_name("PermissionReasons.json").read_text(encoding="utf-8"))
        localize_permission_reasons(output.parent / "Resources", reasons)
        output.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
