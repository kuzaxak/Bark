from hashlib import sha256
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix="bark-startup-check-", dir="/private/tmp") as directory:
    scratch = Path(directory)
    binary = scratch / "chromium-startup-check"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(scratch / "ModuleCache"),
        str(root / "App/Chromium/ChromiumStartup.swift"),
        str(root / "Tests/ChromiumStartup/Main.swift"),
        "-o", str(binary),
    ], check=True)
    expected_digest = sha256(str(scratch / "verification").encode("utf-8")).hexdigest()
    subprocess.run([str(binary), str(scratch), expected_digest], check=True)
