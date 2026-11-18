from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess

root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix="bark-onboarding-check-") as directory:
    out = Path(directory)
    binary = out / "chromium-onboarding-check"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(out / "ModuleCache"),
        str(root / "App/Chromium/ChromiumStartup.swift"), str(root / "Tests/ChromiumOnboarding/Main.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), str(out / "data")], check=True)
