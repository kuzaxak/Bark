from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-app-menu-check-') as directory:
    out = Path(directory)
    binary = out / 'chromium-app-menu-check'
    c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library',
         str(root / 'App/Chromium/ChromiumAppMenu.swift'), str(root / 'Tests/ChromiumAppMenu/Main.swift'), '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
