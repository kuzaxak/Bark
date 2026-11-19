from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tests/Shared"))
from swift_check import swift_target

target = swift_target()

with TemporaryDirectory(prefix='bark-space-files-check-') as directory:
    out = Path(directory)
    binary = out / 'chromium-space-files-check'
    c = ['swiftc', '-swift-version', '5', '-target', target, '-parse-as-library',
         str(root / 'App/Chromium/ChromiumSpaceFiles.swift'),
         str(root / 'App/Chromium/ChromiumShareLinkReplay.swift'), str(root / 'Tests/ChromiumSpaceFiles/Main.swift'), '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
