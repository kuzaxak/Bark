# Licensed under GPL-3.0. See LICENSE.
"""Identify Bark's local shell sources independently of Git and the engine payload."""

import hashlib
from pathlib import Path
import plistlib
import re
import stat


SHELL_SOURCE_KEY = "BarkShellSourceSHA256"
# Synchronized Xcode groups, launcher/resources, and the shared Release scheme.
_INPUTS = (
    "App", "ChromiumApp", "Nook", "Onboarding", "Settings", "UI",
    "Bark.xcodeproj/project.pbxproj",
    "Bark.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
    "Bark.xcodeproj/project.xcworkspace/xcshareddata",
    "Bark.xcodeproj/xcshareddata/xcschemes/Bark.xcscheme",
    "Packages/BarkEngine/Package.swift",
)
_PACKAGES = ("NookBlocker", "NookDesign", "NookSettings", "NookTabsCore", "NookTweaks", "NookUI", "NookWeb")
_SDK_INTERFACE = Path("Packages/BarkEngine/BarkEngine.xcframework")
_IGNORED_NAMES = {".DS_Store", ".build", ".git", ".swiftpm", "xcuserdata"}
_RUST = Path("Nook/ThirdParty/AdblockRustFFI")
_ADBLOCK_BINARY = _RUST / "NookAdblock.xcframework"
_PROJECT_EXCLUSIONS = {
    Path("Nook/Info.plist"),
    Path("Nook/ThirdParty/BigUIPaging/README.md"),
}


def _inputs(root):
    def collect(relative):
        if relative.name in _IGNORED_NAMES or relative in _PROJECT_EXCLUSIONS:
            return
        if relative.is_relative_to(_SDK_INTERFACE) and (
            relative.name == "Engine" or relative.name.startswith("engine-artifact")
        ):
            return
        # NookBlocker links the committed binary target. Xcode does not build its Rust sources.
        if relative.is_relative_to(_RUST) and relative != _RUST and not relative.is_relative_to(_ADBLOCK_BINARY):
            return
        path = root / relative
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            for child in path.iterdir():
                yield from collect(relative / child.name)
        elif stat.S_ISREG(mode):
            yield relative
        else:
            raise ValueError(f"Unsupported shell source input: {relative}")

    paths = tuple(Path(name) for name in _INPUTS)
    for relative in (*paths, _SDK_INTERFACE):
        # This synchronized Xcode group currently has no source directory.
        if relative == Path("Settings") and not (root / relative).exists():
            continue
        yield from collect(relative)
    for package in _PACKAGES:
        path = Path("Packages") / package
        for name in ("Package.swift", "Sources"):
            yield from collect(path / name)


def shell_source_digest(root):
    """Hash local inputs by relative path and content using the v1 format."""
    root = Path(root)
    digest = hashlib.sha256(b"Bark shell source v1\0")
    for path in sorted(_inputs(root)):
        content = hashlib.sha256()
        with (root / path).open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                content.update(block)
        digest.update(path.as_posix().encode("utf-8") + b"\0" + content.digest())
    return digest.hexdigest()


def _valid_digest(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def write_shell_source(app, value):
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if not _valid_digest(value) or SHELL_SOURCE_KEY in info:
        raise ValueError("Invalid or preexisting Bark shell source SHA-256.")
    info[SHELL_SOURCE_KEY] = value
    info_path.write_bytes(plistlib.dumps(info))


def verify_shell_source(app, *, expected=None, required=False):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    value = info.get(SHELL_SOURCE_KEY)
    if value is None and (required or expected is not None):
        raise ValueError("The signed app has no Bark shell source SHA-256.")
    if value is not None and not _valid_digest(value):
        raise ValueError("Invalid Bark shell source SHA-256 in the signed app.")
    if expected is not None and value != expected:
        raise ValueError("The signed app has a different Bark shell source SHA-256.")
    return value
