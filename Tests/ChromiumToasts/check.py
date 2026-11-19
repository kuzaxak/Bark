from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tests/Shared"))
from swift_check import build_package, swift_target

target = swift_target()

with TemporaryDirectory(prefix='bark-toast-check-') as directory:
    out = Path(directory)
    scratch = out / 'packages/NookDesign'
    debug = build_package(root / 'Packages/NookDesign', scratch, target)
    objects = sorted(str(o) for o in (debug / 'NookDesign.build').glob('*.o'))
    binary = out / 'chromium-toast-check'
    c = ['swiftc', '-swift-version', '5', '-target', target, '-parse-as-library', '-I', str(debug / 'Modules'),
         str(root / 'Packages/NookUI/Sources/NookUI/Toasts/ToastView.swift'), str(root / 'Tests/ChromiumToasts/Main.swift'), *objects, '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
