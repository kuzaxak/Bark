from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tests/Shared"))
from swift_check import swift_target

with TemporaryDirectory(prefix="bark-loading-bar-") as scratch:
    binary = Path(scratch) / "check"
    subprocess.run([
        "swiftc", "-target", swift_target(), "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(Path(scratch) / "ModuleCache"),
        root / "Nook/Components/WebsiteView/NativePageLoadingSweep.swift",
        root / "Tests/ChromiumLoadingBar/Main.swift", "-o", binary,
    ], check=True)
    subprocess.run([binary], check=True)
