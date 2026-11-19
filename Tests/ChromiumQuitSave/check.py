from pathlib import Path
from tempfile import TemporaryDirectory
import os, subprocess, sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tests/Shared"))
from swift_check import build_package, swift_target

target = swift_target()

with TemporaryDirectory(prefix='bark-quit-save-check-') as directory:
    out = Path(directory)
    modules, objects = [], []
    for package in ['NookSettings', 'NookTabsCore']:
        scratch = out / 'packages' / package
        debug = build_package(root / 'Packages' / package, scratch, target)
        modules += ['-I', str(debug / 'Modules')]
        objects += sorted(str(o) for o in (debug / f'{package}.build').glob('*.o'))
    binary = out / 'chromium-quit-save-check'
    c = ['swiftc', '-swift-version', '5', '-target', target, '-parse-as-library', '-j2', *modules,
         str(root / 'App/Chromium/ChromiumQuitSave.swift'), str(root / 'Packages/NookWeb/Sources/NookWeb/HistoryEntity.swift'),
         str(root / 'Tests/ChromiumQuitSave/Main.swift'), *objects, '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    if p.returncode:
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)
    home = out / 'home'
    home.mkdir()
    domain = 'ee.qdo.nook.' + out.name
    env = {**os.environ, 'HOME': str(home), 'CFFIXED_USER_HOME': str(home)}
    try:
        p = subprocess.run([str(binary), str(out / 'state'), domain], capture_output=True, text=True, env=env, timeout=120)
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)
    finally:
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
        (Path.home() / 'Library/Preferences' / (domain + '.plist')).unlink(missing_ok=True)
