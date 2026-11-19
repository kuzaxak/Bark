import argparse
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tests/Shared"))
from swift_check import native_architecture, swift_target

parser = argparse.ArgumentParser(description="Check the loading bar and optional SDK progress observer.")
parser.add_argument("--bridge-header", type=Path, default=root /
                    "Packages/BarkEngine/BarkEngine.xcframework/macos-arm64_x86_64/Headers/BarcChromium/barc_bridge_api.h")
args = parser.parse_args()

with TemporaryDirectory(prefix="bark-loading-bar-") as scratch:
    binary = Path(scratch) / "check"
    subprocess.run([
        "swiftc", "-target", swift_target(), "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(Path(scratch) / "ModuleCache"),
        root / "Nook/Components/WebsiteView/NativePageLoadingSweep.swift",
        root / "Tests/ChromiumLoadingBar/Main.swift", "-o", binary,
    ], check=True)
    subprocess.run([binary], check=True)

    # Check either public header generation without replacing checkout SDK inputs.
    include = Path(scratch) / "include"
    (include / "BarcChromium").mkdir(parents=True)
    (include / "BarcChromium/barc_bridge_api.h").write_bytes(args.bridge_header.read_bytes())
    subprocess.run([
        "xcrun", "clang", "-arch", native_architecture(), "-std=c11", "-Werror",
        "-I", include, "-I", root / "ChromiumApp/SDKCompatibility",
        root / "Tests/ChromiumLoadingBar/compatibility.c", "-o", binary,
    ], check=True)
    subprocess.run([binary], check=True)
    print("The SDK progress observer is called only when its table tail exists")
