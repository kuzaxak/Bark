from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-title-band-') as directory:
    out = Path(directory)
    scratch = out / 'packages/NookDesign'
    p = subprocess.run(['swift', 'build', '--package-path', str(root / 'Packages/NookDesign'), '--scratch-path', str(scratch), '--jobs', '2'], capture_output=True, text=True)
    if p.returncode:
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)
    debug = scratch / 'x86_64-apple-macosx/debug'
    objects = sorted(str(o) for o in (debug / 'NookDesign.build').glob('*.o'))
    binary = out / 'chromium-title-band-check'
    c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library', '-I', str(debug / 'Modules'),
         str(root / 'App/Chromium/ChromiumTitleBand.swift'), str(root / 'Tests/ChromiumTitleBand/Main.swift'), *objects, '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
