from pathlib import Path
import os, shutil, subprocess

root = Path(__file__).resolve().parents[2]
out = root / 'build/quit-save-check'
out.mkdir(parents=True, exist_ok=True)
modules, objects = [], []
for package in ['NookSettings', 'NookTabsCore']:
    scratch = out / 'packages' / package
    p = subprocess.run(['swift', 'build', '--package-path', str(root / 'Packages' / package), '--scratch-path', str(scratch), '--jobs', '2'],
                       capture_output=True, text=True)
    if p.returncode:
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)
    debug = scratch / 'x86_64-apple-macosx/debug'
    modules += ['-I', str(debug / 'Modules')]
    objects += sorted(str(o) for o in (debug / f'{package}.build').glob('*.o'))
binary = out / 'chromium-quit-save-check'
c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library', '-j2', *modules,
     str(root / 'App/Chromium/ChromiumQuitSave.swift'), str(root / 'Packages/NookWeb/Sources/NookWeb/HistoryEntity.swift'),
     str(root / 'Tests/ChromiumQuitSave/Main.swift'), *objects, '-o', str(binary)]
p = subprocess.run(c, capture_output=True, text=True)
if p.returncode:
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
home = out / 'home'
shutil.rmtree(home, ignore_errors=True)
home.mkdir()
domain = 'ee.qdo.nook.chromium-quit-save-test'
env = {**os.environ, 'HOME': str(home), 'CFFIXED_USER_HOME': str(home)}
p = subprocess.run([str(binary), '/private/tmp/nook-quit-save-test', domain], capture_output=True, text=True, env=env, timeout=120)
print(p.stdout + p.stderr)
subprocess.run(['defaults', 'delete', domain], capture_output=True)
(Path.home() / 'Library/Preferences' / (domain + '.plist')).unlink(missing_ok=True)
raise SystemExit(p.returncode)
