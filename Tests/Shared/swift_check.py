"""Native Swift compiler target and package output for contributor checks."""

from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from chromium_sdk_layout import native_architecture


def swift_target():
    return f"{native_architecture()}-apple-macosx15.5"


def build_package(package, scratch, target, *, jobs=2, log=None):
    command = [
        "swift", "build", "--package-path", str(package), "--scratch-path", str(scratch),
        "--jobs", str(jobs), "--triple", target,
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if log is not None:
        log.write_text(output)
    if result.returncode:
        print(output)
        raise SystemExit(result.returncode)
    return Path(subprocess.check_output([*command, "--show-bin-path"], text=True).strip())
