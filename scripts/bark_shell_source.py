# Licensed under GPL-3.0. See LICENSE.
"""Identify Bark's local shell sources independently of Git and the engine payload."""

import hashlib
import json
from pathlib import Path
import plistlib
import re
import stat


SHELL_SOURCE_KEY = "BarkShellSourceSHA256"
_PROJECT = "Bark.xcodeproj/project.pbxproj"
# Launcher/resources and the shared Release scheme. Shell groups come from Xcode.
_INPUTS = (
    "ChromiumApp", _PROJECT,
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
_OPENSTEP_TOKEN = re.compile(
    r'\s+|//[^\n]*|/\*.*?\*/|"(?:[^"\\]|\\.)*"|[{}()=;,]|'
    r'(?:[^\s{}()=;,"/]|/(?![/*]))+', re.DOTALL,
)


def _read_xcode_project(path):
    """Parse the OpenStep dictionary/array syntax used by project.pbxproj."""
    text = path.read_text()
    tokens = []
    offset = 0
    for match in _OPENSTEP_TOKEN.finditer(text):
        if match.start() != offset:
            raise ValueError(f"Invalid Xcode project syntax at character {offset}")
        offset = match.end()
        token = match.group()
        if not token.isspace() and not token.startswith(("//", "/*")):
            tokens.append(token)
    if offset != len(text):
        raise ValueError(f"Invalid Xcode project syntax at character {offset}")
    tokens.extend((None, None))
    index = 0

    def take(expected=None):
        nonlocal index
        token = tokens[index]
        index += 1
        if token is None or (expected is not None and token != expected):
            raise ValueError(f"Expected {expected or 'Xcode project value'}, got {token!r}")
        return token

    def value(token):
        if token == "{":
            result = {}
            while tokens[index] != "}":
                key = value(take())
                take("=")
                result[key] = value(take())
                take(";")
            take("}")
            return result
        if token == "(":
            result = []
            while tokens[index] != ")":
                result.append(value(take()))
                if tokens[index] != ")":
                    take(",")
            take(")")
            return result
        if token in ("}", ")", ";", ",", "="):
            raise ValueError(f"Unexpected Xcode project token {token}")
        return json.loads(token) if token.startswith('"') else token

    result = value(take("{"))
    if tokens[index] is not None:
        raise ValueError("Unexpected content after Xcode project")
    return result


def _project_inputs(root):
    project = _read_xcode_project(root / _PROJECT)
    objects = project["objects"]
    manifest = objects[project["rootObject"]]
    targets = [target for target in manifest["targets"] if objects[target].get("name") == "BarkNativeShell"]
    if len(targets) != 1:
        raise ValueError("Expected exactly one BarkNativeShell target in the Xcode project")
    target, = targets

    groups = {"PBXGroup", "PBXVariantGroup", "XCVersionGroup"}
    paths = {}

    def local_path(value):
        relative = Path(value)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Xcode source must be within the checkout: {value}")
        return relative

    def resolve(group, parent):
        item = objects[group]
        if item["sourceTree"] == "SOURCE_ROOT":
            parent = Path()
        elif item["sourceTree"] != "<group>":
            parent = None
        if parent is not None:
            name = item.get("path", "")
            paths[group] = parent / local_path(name)
        for child in item.get("children", ()):
            resolve(child, paths.get(group))

    resolve(manifest["mainGroup"], Path())
    inputs = {}
    synchronized = set(objects[target].get("fileSystemSynchronizedGroups", ()))
    for identifier, item in objects.items():
        if item["isa"] != "PBXFileSystemSynchronizedRootGroup":
            continue
        members = set()
        for exception in item.get("exceptions", ()):
            rule = objects[exception]
            if rule["isa"] != "PBXFileSystemSynchronizedBuildFileExceptionSet":
                raise ValueError(f"Unknown Xcode source membership rule: {rule['isa']}")
            if rule["target"] == target:
                members.update(local_path(name) for name in rule.get("membershipExceptions", ()))
        if identifier in synchronized:
            path = paths[identifier]
            # Settings is currently an empty synchronized group absent from source archives.
            if path != Path("Settings") or (root / path).exists() or (root / path).is_symlink():
                inputs[path] = {path / member for member in members}
        elif members:
            inputs.update((paths[identifier] / member, set()) for member in members)

    def add_explicit(identifier):
        item = objects[identifier]
        if item["isa"] in groups:
            for child in item.get("children", ()):
                add_explicit(child)
        elif identifier in paths:
            inputs[paths[identifier]] = set()
        elif item["sourceTree"] not in ("SDKROOT", "BUILT_PRODUCTS_DIR"):
            raise ValueError(f"Unsupported Xcode source path: {item.get('path', identifier)}")

    for identifier in objects[target]["buildPhases"]:
        phase = objects[identifier]
        if phase["isa"] in ("PBXSourcesBuildPhase", "PBXResourcesBuildPhase"):
            for entry in phase.get("files", ()):
                add_explicit(objects[entry]["fileRef"])
    return inputs


def _inputs(root, links):
    def record_link(relative):
        path = root / relative
        target = path.readlink()
        try:
            resolved = path.resolve(strict=True)
        except RuntimeError as error:
            raise ValueError(f"Cycle in shell source links: {relative}") from error
        if target.is_absolute() or not resolved.is_relative_to(root):
            raise ValueError(f"Shell source link must resolve within the checkout: {relative}")
        links[relative] = target.as_posix()

    def collect(relative, excluded, parents=frozenset()):
        if relative.name in _IGNORED_NAMES or relative in excluded:
            return
        if relative.is_relative_to(_SDK_INTERFACE) and (
            relative.name == "Engine" or relative.name.startswith("engine-artifact")
        ):
            return
        # NookBlocker links the committed binary target. Xcode does not build its Rust sources.
        if relative.is_relative_to(_RUST) and relative != _RUST and not relative.is_relative_to(_ADBLOCK_BINARY):
            return
        path = root / relative
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            record_link(relative)
            info = path.stat()
        if stat.S_ISDIR(info.st_mode):
            identity = (info.st_dev, info.st_ino)
            if identity in parents:
                raise ValueError(f"Directory cycle in shell source inputs: {relative}")
            lineage = parents | {identity}
            for child in path.iterdir():
                yield from collect(relative / child.name, excluded, lineage)
        elif stat.S_ISREG(info.st_mode):
            yield relative
        else:
            raise ValueError(f"Unsupported shell source input: {relative}")

    project = Path(_PROJECT)
    for relative in (*reversed(project.parents), project):
        if (root / relative).is_symlink():
            record_link(relative)
    paths = _project_inputs(root)
    paths.update((Path(name), set()) for name in _INPUTS)
    paths[_SDK_INTERFACE] = set()
    paths[_ADBLOCK_BINARY] = set()
    for package in _PACKAGES:
        paths.update((Path("Packages") / package / name, set()) for name in ("Package.swift", "Sources"))
    for relative, excluded in paths.items():
        # A local package or Xcode group can itself be a source-tree alias.
        for parent in reversed(relative.parents):
            if parent not in links and (root / parent).is_symlink():
                record_link(parent)
        yield from collect(relative, excluded)


def shell_source_digest(root):
    """Hash local inputs by relative path and content using the v2 format."""
    root = Path(root).resolve(strict=True)
    links = {}
    digest = hashlib.sha256(b"Bark shell source v2\0")
    for path in sorted(set(_inputs(root, links))):
        content = hashlib.sha256()
        with (root / path).open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                content.update(block)
        digest.update(path.as_posix().encode("utf-8") + b"\0" + content.digest())
    if links:
        digest.update(b"\0Bark shell source links\0")
        for path, target in sorted(links.items()):
            digest.update(path.as_posix().encode("utf-8") + b"\0" + target.encode("utf-8") + b"\0")
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
