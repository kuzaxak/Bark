# Licensed under GPL-3.0. See LICENSE.
"""Authorize the outer Bark app's opt-in production CloudKit entitlements."""

from datetime import datetime, timezone
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory

BUNDLE_ID = "ee.qdo.bark"
CONTAINER = "iCloud.ee.qdo.bark"
PROFILE_NAME = "embedded.provisionprofile"
APP_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"
CONTAINERS = "com.apple.developer.icloud-container-identifiers"
SERVICES = "com.apple.developer.icloud-services"
ENVIRONMENT = "com.apple.developer.icloud-container-environment"
PUSH = "com.apple.developer.aps-environment"
CLOUD_KEYS = {APP_ID, TEAM_ID, CONTAINERS, SERVICES, ENVIRONMENT, PUSH}


def load_profile(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("The iCloud provisioning profile must be a regular file.")
    with TemporaryDirectory(prefix="bark-provisioning-") as directory:
        roots = Path(directory) / "roots.pem"
        signer = Path(directory) / "signer.pem"
        roots.write_bytes(subprocess.check_output([
            "/usr/bin/security", "find-certificate", "-a", "-c", "Apple Root CA", "-p",
            "/System/Library/Keychains/SystemRootCertificates.keychain",
        ]))
        result = subprocess.run([
            "/usr/bin/openssl", "cms", "-verify", "-inform", "DER", "-in", path,
            "-CAfile", roots, "-CApath", directory, "-purpose", "any", "-signer", signer,
        ], capture_output=True, check=True)
        certificate = subprocess.check_output([
            "/usr/bin/openssl", "x509", "-in", signer, "-noout", "-text",
        ], text=True)
        if signer.read_text().count("-----BEGIN CERTIFICATE-----") != 1 or not re.search(
            r"^\s*1\.2\.840\.113635\.100\.4\.11:", certificate, re.MULTILINE
        ):
            raise ValueError("Expected Apple's macOS provisioning-profile signing certificate.")
    return plistlib.loads(result.stdout)


def authorized_entitlements(profile, bundle_id, *, now=None):
    if bundle_id != BUNDLE_ID:
        raise ValueError("The iCloud profile is only supported for the Bark bundle ID.")
    if profile.get("ProvisionsAllDevices") is not True or "OSX" not in profile.get("Platform", []):
        raise ValueError("The iCloud build requires a macOS Developer ID distribution profile.")
    now = now or datetime.now(timezone.utc)
    expiration = profile.get("ExpirationDate")
    creation = profile.get("CreationDate")
    if (not isinstance(expiration, datetime) or not isinstance(creation, datetime)
            or not creation.replace(tzinfo=timezone.utc) <= now < expiration.replace(tzinfo=timezone.utc)):
        raise ValueError("The iCloud provisioning profile is outside its validity period.")
    teams = profile.get("TeamIdentifier", [])
    if len(teams) != 1 or not re.fullmatch(r"[A-Z0-9]{10}", teams[0]):
        raise ValueError("Expected a single team in the iCloud provisioning profile.")
    team = teams[0]
    grants = profile.get("Entitlements", {})
    expected = {
        APP_ID: f"{team}.{bundle_id}", TEAM_ID: team, CONTAINERS: [CONTAINER],
        SERVICES: ["CloudKit"], ENVIRONMENT: "Production", PUSH: "production",
    }
    if grants.get(APP_ID) != expected[APP_ID] or grants.get(TEAM_ID) != team:
        raise ValueError("The iCloud profile must explicitly authorize this Bark App ID and team.")
    if grants.get("com.apple.security.get-task-allow") or grants.get("get-task-allow"):
        raise ValueError("The iCloud build requires a production provisioning profile.")
    for key in (CONTAINERS, SERVICES, ENVIRONMENT, PUSH):
        value = expected[key]
        wanted = value if isinstance(value, list) else [value]
        grant = grants.get(key)
        allowed = grant if isinstance(grant, list) else [grant]
        if key == SERVICES and "*" in allowed:
            continue
        if any(item not in allowed for item in wanted):
            raise ValueError(f"The iCloud provisioning profile does not grant {key}.")
    certificates = profile.get("DeveloperCertificates", [])
    if not certificates or not all(isinstance(cert, bytes) and cert for cert in certificates):
        raise ValueError("The iCloud provisioning profile lacks signing certificates.")
    return expected


def assert_profile_free(app):
    for name in (PROFILE_NAME, "embedded.mobileprovision"):
        profile = app / "Contents" / name
        if profile.is_symlink() or profile.exists():
            raise ValueError("Supply the iCloud provisioning profile explicitly for this build.")


def prepare_profile(stage, supplied):
    app = stage / "Bark.app"
    assert_profile_free(app)
    if supplied is None:
        return None
    if supplied.is_symlink() or not supplied.is_file():
        raise ValueError("The iCloud provisioning profile must be a regular file.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    entitlements = stage / "Bark Packaging/app-entitlements.plist"
    base = plistlib.loads(entitlements.read_bytes())
    if CLOUD_KEYS & base.keys():
        raise ValueError("The preexisting app entitlements conflict with iCloud signing.")
    path = app / "Contents" / PROFILE_NAME
    with TemporaryDirectory(prefix="bark-profile-input-", dir=stage) as directory:
        candidate = Path(directory) / PROFILE_NAME
        shutil.copyfile(supplied, candidate)
        cloud = authorized_entitlements(load_profile(candidate), info.get("CFBundleIdentifier"))
        entitlements.write_bytes(plistlib.dumps({**base, **cloud}))
        candidate.replace(path)
    return path


def signed_cloud_entitlements(app, bundle_id):
    profile_path = app / "Contents" / PROFILE_NAME
    mobile = app / "Contents/embedded.mobileprovision"
    if mobile.is_symlink() or mobile.exists():
        raise ValueError("A macOS Bark build must use embedded.provisionprofile.")
    if not (profile_path.is_symlink() or profile_path.exists()):
        return {}
    profile = load_profile(profile_path)
    expected = authorized_entitlements(profile, bundle_id)
    team = expected[TEAM_ID]
    requirement = (f'=anchor apple generic and identifier "{BUNDLE_ID}" '
                   f'and certificate leaf[subject.OU] = "{team}" '
                   "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
    with TemporaryDirectory(prefix="bark-signing-certificate-") as directory:
        subprocess.run([
            "/usr/bin/codesign", "--verify", "--strict", "-R",
            requirement, app,
        ], check=True)
        subprocess.run([
            "/usr/bin/codesign", "--display", "--extract-certificates", app,
        ], cwd=directory, check=True, capture_output=True)
        leaf = (Path(directory) / "codesign0").read_bytes()
        if leaf not in profile["DeveloperCertificates"]:
            raise ValueError("The app's Developer ID certificate is absent from its iCloud profile.")
    return expected
