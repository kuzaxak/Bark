"""Common preflight and profile setup for disposable signed Pawl walks."""

import json
import plistlib
import subprocess


def verification_shell_code(app):
    shell = app / "Contents/Frameworks/NookNativeShell.framework/NookNativeShell"
    code = shell.read_bytes()
    if b"VaultFixture.json" not in code:
        raise RuntimeError("The signed candidate lacks disposable vault verification support")
    report = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(app)],
        check=True, capture_output=True,
    )
    entitlements = plistlib.loads(report.stdout) if report.stdout else {}
    if {"keychain-access-groups", "com.apple.developer.web-browser.public-key-credential"} & entitlements.keys():
        raise RuntimeError("The vault fixture requires an app without platform credential entitlements")
    return code


def prepare_engine_profile(root, profile):
    # Chromium otherwise schedules its own password leak check independently
    # of the selected provider, so disable it in this disposable profile.
    engine_profile = root / "Engine" / f"Barc-{profile.lower()}"
    engine_profile.mkdir(parents=True)
    (engine_profile / "Preferences").write_text(json.dumps({
        "profile": {"password_manager_leak_detection": False},
    }) + "\n")
    return engine_profile
